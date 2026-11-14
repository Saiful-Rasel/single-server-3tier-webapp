
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Production Deployment Script
#
# Execution : AWS SSM Run Command (root)
# Source    : Versioned artifacts in private S3
# Backend   : Node.js + systemd
# Frontend  : Nginx
# Rollback  : Restore previous releases on failure
#
# Required environment:
#   DEPLOY_BUCKET
#   COMMIT_SHA
#   AWS_REGION
#
# S3 structure:
#   frontend/<COMMIT_SHA>/index.html
#   frontend/<COMMIT_SHA>/assets/...
#   backend/<COMMIT_SHA>/backend.tar.gz
# ============================================================

# ------------------------------------------------------------
# 1. Configuration
# ------------------------------------------------------------

: "${DEPLOY_BUCKET:?DEPLOY_BUCKET is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${AWS_REGION:?AWS_REGION is required}"

APP_ROOT="/opt/bmi-app"
BACKEND_RELEASES="$APP_ROOT/releases"
SHARED_DIR="$APP_ROOT/shared"

FRONTEND_ROOT="/var/www/bmi-frontend"
FRONTEND_RELEASES="$FRONTEND_ROOT/releases"

BACKEND_RELEASE="$BACKEND_RELEASES/$COMMIT_SHA"
FRONTEND_RELEASE="$FRONTEND_RELEASES/$COMMIT_SHA"

BACKEND_ARCHIVE="s3://$DEPLOY_BUCKET/backend/$COMMIT_SHA/backend.tar.gz"
FRONTEND_ARTIFACT="s3://$DEPLOY_BUCKET/frontend/$COMMIT_SHA/"

BACKEND_SERVICE="bmi-backend"

WORK_DIR="$(mktemp -d /tmp/bmi-deploy.XXXXXX)"

PREVIOUS_BACKEND=""
PREVIOUS_FRONTEND=""

BACKEND_SWITCHED=false
FRONTEND_SWITCHED=false
DEPLOYMENT_SUCCESS=false

# ------------------------------------------------------------
# 2. Logging
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ------------------------------------------------------------
# 3. Atomic symlink replacement
# ------------------------------------------------------------

switch_symlink() {
    local target="$1"
    local link="$2"
    local temporary_link="${link}.new"

    [[ -d "$target" ]] || {
        log "ERROR: Release directory does not exist: $target"
        return 1
    }

    rm -f "$temporary_link"

    ln -s "$target" "$temporary_link"

    # Atomic replacement on the same filesystem.
    mv -Tf "$temporary_link" "$link"
}

# ------------------------------------------------------------
# 4. Rollback
# ------------------------------------------------------------

rollback() {
    log "Deployment failed. Starting rollback..."

    # Restore previous frontend release.
    if [[ "$FRONTEND_SWITCHED" == true ]]; then
        if [[ -n "$PREVIOUS_FRONTEND" && -d "$PREVIOUS_FRONTEND" ]]; then
            switch_symlink \
                "$PREVIOUS_FRONTEND" \
                "$FRONTEND_ROOT/current" ||
                log "ERROR: Frontend rollback failed."
        else
            rm -f "$FRONTEND_ROOT/current" ||
                log "ERROR: Could not remove frontend symlink."
        fi
    fi

    # Restore previous backend release.
    if [[ "$BACKEND_SWITCHED" == true ]]; then
        if [[ -n "$PREVIOUS_BACKEND" && -d "$PREVIOUS_BACKEND" ]]; then
            switch_symlink \
                "$PREVIOUS_BACKEND" \
                "$APP_ROOT/current" ||
                log "ERROR: Backend rollback symlink failed."
        else
            rm -f "$APP_ROOT/current" ||
                log "ERROR: Could not remove backend symlink."
        fi

        # Restart backend against restored release.
        systemctl restart "$BACKEND_SERVICE" ||
            log "ERROR: Backend restart after rollback failed."
    fi

    # Restore Nginx availability.
    if nginx -t; then
        systemctl reload nginx ||
            log "ERROR: Nginx reload after rollback failed."
    else
        log "ERROR: Nginx configuration validation failed during rollback."
    fi

    log "Rollback process finished."
}

# ------------------------------------------------------------
# 5. EXIT handler
# ------------------------------------------------------------

on_exit() {
    local exit_code=$?

    # Prevent recursive EXIT handling.
    trap - EXIT ERR

    if [[ "$exit_code" -ne 0 && "$DEPLOYMENT_SUCCESS" != true ]]; then
        rollback || log "WARNING: Rollback encountered an unexpected error."
    fi

    # Always remove temporary deployment files.
    rm -rf -- "$WORK_DIR"

    if [[ "$exit_code" -ne 0 ]]; then
        log "Deployment failed with exit code: $exit_code"
    fi

    exit "$exit_code"
}

# EXIT runs on both successful and failed script termination.
# Unlike ERR, EXIT also handles explicit exit 1.
trap on_exit EXIT

# ------------------------------------------------------------
# 6. Validate prerequisites
# ------------------------------------------------------------

log "Starting deployment: $COMMIT_SHA"

[[ "$COMMIT_SHA" =~ ^[a-f0-9]{40}$ ]] || {
    log "Invalid commit SHA."
    exit 1
}

for command in aws node tar curl systemctl nginx \
               find sort cut readlink; do
    command -v "$command" >/dev/null 2>&1 || {
        log "Required command not found: $command"
        exit 1
    }
done

id ubuntu >/dev/null 2>&1 || {
    log "Ubuntu application user does not exist."
    exit 1
}

[[ -f "$SHARED_DIR/.env" ]] || {
    log "Production environment file missing: $SHARED_DIR/.env"
    exit 1
}

# ------------------------------------------------------------
# 7. Prepare directories
# ------------------------------------------------------------

log "Preparing release directories..."

mkdir -p \
    "$BACKEND_RELEASES" \
    "$SHARED_DIR" \
    "$FRONTEND_RELEASES"

# Keep production environment separate from application releases.
chown root:ubuntu "$SHARED_DIR"
chmod 750 "$SHARED_DIR"
chmod 640 "$SHARED_DIR/.env"

# ------------------------------------------------------------
# 8. Remember previous releases
# ------------------------------------------------------------

if [[ -L "$APP_ROOT/current" ]]; then
    PREVIOUS_BACKEND="$(readlink -f "$APP_ROOT/current" || true)"
fi

if [[ -L "$FRONTEND_ROOT/current" ]]; then
    PREVIOUS_FRONTEND="$(readlink -f "$FRONTEND_ROOT/current" || true)"
fi

log "Previous backend: ${PREVIOUS_BACKEND:-none}"
log "Previous frontend: ${PREVIOUS_FRONTEND:-none}"

# ------------------------------------------------------------
# 9. Download backend artifact
# ------------------------------------------------------------

log "Downloading backend artifact..."

aws s3 cp \
    "$BACKEND_ARCHIVE" \
    "$WORK_DIR/backend.tar.gz" \
    --region "$AWS_REGION" \
    --only-show-errors

mkdir -p "$WORK_DIR/backend"

tar -xzf "$WORK_DIR/backend.tar.gz" \
    -C "$WORK_DIR/backend"

# Expected archive layout:
# backend/package.json
# backend/package-lock.json
# backend/node_modules/
# backend/src/

SOURCE_BACKEND="$WORK_DIR/backend/backend"

[[ -f "$SOURCE_BACKEND/package.json" ]] || {
    log "Backend package.json missing."
    exit 1
}

[[ -f "$SOURCE_BACKEND/src/server.js" ]] || {
    log "Backend server.js missing."
    exit 1
}

[[ -d "$SOURCE_BACKEND/node_modules" ]] || {
    log "Backend node_modules missing."
    exit 1
}

# Validate critical production dependencies.
for dependency in express pg dotenv; do
    [[ -d "$SOURCE_BACKEND/node_modules/$dependency" ]] || {
        log "Missing backend dependency: $dependency"
        exit 1
    }
done

# ------------------------------------------------------------
# 10. Install backend release
# ------------------------------------------------------------

log "Installing backend release..."

# Do not overwrite an existing active release.
if [[ -e "$BACKEND_RELEASE" ]]; then
    CURRENT_BACKEND="$(readlink -f "$APP_ROOT/current" || true)"

    if [[ "$CURRENT_BACKEND" == "$BACKEND_RELEASE" ]]; then
        log "ERROR: Target backend release is already active."
        exit 1
    fi

    rm -rf -- "$BACKEND_RELEASE"
fi

mkdir -p "$BACKEND_RELEASE"

cp -a "$SOURCE_BACKEND/." "$BACKEND_RELEASE/"

chown -R ubuntu:ubuntu "$BACKEND_RELEASE"

# ------------------------------------------------------------
# 11. Download frontend artifact
# ------------------------------------------------------------

log "Downloading frontend artifact..."

mkdir -p "$WORK_DIR/frontend"

aws s3 sync \
    "$FRONTEND_ARTIFACT" \
    "$WORK_DIR/frontend/" \
    --region "$AWS_REGION" \
    --only-show-errors

[[ -s "$WORK_DIR/frontend/index.html" ]] || {
    log "Frontend index.html missing or empty."
    exit 1
}

# ------------------------------------------------------------
# 12. Install frontend release
# ------------------------------------------------------------

log "Installing frontend release..."

if [[ -e "$FRONTEND_RELEASE" ]]; then
    CURRENT_FRONTEND="$(readlink -f "$FRONTEND_ROOT/current" || true)"

    if [[ "$CURRENT_FRONTEND" == "$FRONTEND_RELEASE" ]]; then
        log "ERROR: Target frontend release is already active."
        exit 1
    fi

    rm -rf -- "$FRONTEND_RELEASE"
fi

mkdir -p "$FRONTEND_RELEASE"

cp -a "$WORK_DIR/frontend/." "$FRONTEND_RELEASE/"

chown -R www-data:www-data "$FRONTEND_RELEASE"

# ------------------------------------------------------------
# 13. Configure systemd service
# ------------------------------------------------------------

log "Configuring systemd service..."

NODE_BIN="$(command -v node)"

cat > "/etc/systemd/system/${BACKEND_SERVICE}.service" <<EOF
[Unit]
Description=BMI Health Tracker Backend
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu

WorkingDirectory=${APP_ROOT}/current

EnvironmentFile=${SHARED_DIR}/.env
Environment=NODE_ENV=production
Environment=PORT=3000

ExecStart=${NODE_BIN} src/server.js

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$BACKEND_SERVICE"

# ------------------------------------------------------------
# 14. Activate backend release
# ------------------------------------------------------------

log "Activating backend release..."

switch_symlink "$BACKEND_RELEASE" "$APP_ROOT/current"

BACKEND_SWITCHED=true

systemctl restart "$BACKEND_SERVICE"

# ------------------------------------------------------------
# 15. Activate frontend release
# ------------------------------------------------------------

log "Activating frontend release..."

switch_symlink "$FRONTEND_RELEASE" "$FRONTEND_ROOT/current"

FRONTEND_SWITCHED=true

# ------------------------------------------------------------
# 16. Validate and reload Nginx
# ------------------------------------------------------------

log "Validating Nginx..."

nginx -t

systemctl reload nginx

# ------------------------------------------------------------
# 17. Backend health check
# ------------------------------------------------------------

log "Checking backend health..."

HEALTH_CHECK_PASSED=false

for ((attempt = 1; attempt <= 15; attempt++)); do

    if curl -fsS \
        --connect-timeout 2 \
        --max-time 5 \
        http://127.0.0.1:3000/health \
        >/dev/null 2>&1; then

        HEALTH_CHECK_PASSED=true
        break
    fi

    log "Waiting for backend... attempt $attempt/15"

    sleep 2
done

if [[ "$HEALTH_CHECK_PASSED" != true ]]; then
    log "Backend health check failed."

    systemctl status "$BACKEND_SERVICE" --no-pager || true

    journalctl \
        -u "$BACKEND_SERVICE" \
        -n 50 \
        --no-pager || true

    exit 1
fi

log "Backend health check passed."

# ------------------------------------------------------------
# 18. Frontend health check
# ------------------------------------------------------------

log "Checking frontend..."

[[ -s "$FRONTEND_ROOT/current/index.html" ]] || {
    log "Frontend release index.html is missing."
    exit 1
}

if ! curl -fsS \
    --connect-timeout 3 \
    --max-time 10 \
    http://127.0.0.1/ \
    -o "$WORK_DIR/frontend-response.html"; then

    log "Frontend HTTP health check failed."
    exit 1
fi

if ! grep -qiE '<!doctype html|<html' \
    "$WORK_DIR/frontend-response.html"; then

    log "Frontend response does not contain valid HTML."
    exit 1
fi

log "Frontend health check passed."

# ------------------------------------------------------------
# 19. Cleanup old releases
# ------------------------------------------------------------

cleanup_old_releases() {
    local release_dir="$1"
    local previous_release="$2"
    local active_release=""
    local release=""
    local index=0

    local -a releases=()

    active_release="$(readlink -f "$(dirname "$release_dir")/current" || true)"

    # Sort releases by modification time, newest first.
    mapfile -t releases < <(
        find "$release_dir" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%T@ %p\n' |
            sort -rn |
            cut -d' ' -f2-
    )

    # Keep the five newest releases.
    # Never remove the active or previous release.
    for release in "${releases[@]}"; do

        if (( index < 5 )); then
            ((index += 1))
            continue
        fi

        if [[ "$release" == "$active_release" ||
              "$release" == "$previous_release" ]]; then
            continue
        fi

        log "Removing old release: $release"

        rm -rf -- "$release" || return 1
    done
}

log "Cleaning old releases..."

if ! cleanup_old_releases "$BACKEND_RELEASES" "$PREVIOUS_BACKEND"; then
    log "WARNING: Backend release cleanup failed."
fi

if ! cleanup_old_releases "$FRONTEND_RELEASES" "$PREVIOUS_FRONTEND"; then
    log "WARNING: Frontend release cleanup failed."
fi

# ------------------------------------------------------------
# 20. Deployment successful
# ------------------------------------------------------------

DEPLOYMENT_SUCCESS=true

log "Deployment completed successfully."
