
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Production Deployment Script
#
# Execution : AWS SSM Run Command (root)
# Source    : Versioned artifacts in private S3
# Backend   : Node.js + systemd
# Frontend  : Nginx
# Rollback  : Restore previous release on failure
#
# Required environment:
#   DEPLOY_BUCKET
#   COMMIT_SHA
#   AWS_REGION
#
# Expected S3 structure:
#   frontend/<COMMIT_SHA>/index.html
#   frontend/<COMMIT_SHA>/assets/...
#   backend/<COMMIT_SHA>/backend.tar.gz
# ============================================================

# ------------------------------------------------------------
# 1. Deployment configuration
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
# 2. Logging and cleanup
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    rm -rf "$WORK_DIR"
}

# ------------------------------------------------------------
# 3. Atomic symlink switch
# ------------------------------------------------------------

switch_symlink() {
    local target="$1"
    local link="$2"
    local temporary_link="${link}.new"

    rm -f "$temporary_link"

    ln -s "$target" "$temporary_link"

    # Atomic replacement on the same filesystem.
    mv -Tf "$temporary_link" "$link"
}

# ------------------------------------------------------------
# 4. Rollback handler
# ------------------------------------------------------------

rollback() {
    local exit_code=$?

    if [[ "$DEPLOYMENT_SUCCESS" == true ]]; then
        return
    fi

    log "Deployment failed. Starting rollback..."

    if [[ "$FRONTEND_SWITCHED" == true ]]; then
        if [[ -n "$PREVIOUS_FRONTEND" ]]; then
            switch_symlink "$PREVIOUS_FRONTEND" "$FRONTEND_ROOT/current"
        else
            rm -f "$FRONTEND_ROOT/current"
        fi
    fi

    if [[ "$BACKEND_SWITCHED" == true ]]; then
        if [[ -n "$PREVIOUS_BACKEND" ]]; then
            switch_symlink "$PREVIOUS_BACKEND" "$APP_ROOT/current"
        else
            rm -f "$APP_ROOT/current"
        fi

        systemctl restart "$BACKEND_SERVICE" || true
    fi

    nginx -t && systemctl reload nginx || true

    log "Rollback process finished."

    exit "$exit_code"
}

trap cleanup EXIT
trap rollback ERR

# ------------------------------------------------------------
# 5. Validate prerequisites
# ------------------------------------------------------------

log "Starting deployment: $COMMIT_SHA"

[[ "$COMMIT_SHA" =~ ^[a-f0-9]{40}$ ]] || {
    log "Invalid commit SHA."
    exit 1
}

for command in aws node tar curl systemctl nginx; do
    command -v "$command" >/dev/null 2>&1 || {
        log "Required command not found: $command"
        exit 1
    }
done

id ubuntu >/dev/null 2>&1 || {
    log "Ubuntu application user does not exist."
    exit 1
}

test -f "$SHARED_DIR/.env" || {
    log "Production environment file missing: $SHARED_DIR/.env"
    exit 1
}

# ------------------------------------------------------------
# 6. Prepare release directories
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
# 7. Remember previous releases
# ------------------------------------------------------------

if [[ -L "$APP_ROOT/current" ]]; then
    PREVIOUS_BACKEND="$(readlink -f "$APP_ROOT/current")"
fi

if [[ -L "$FRONTEND_ROOT/current" ]]; then
    PREVIOUS_FRONTEND="$(readlink -f "$FRONTEND_ROOT/current")"
fi

log "Previous backend: ${PREVIOUS_BACKEND:-none}"
log "Previous frontend: ${PREVIOUS_FRONTEND:-none}"

# ------------------------------------------------------------
# 8. Download backend artifact
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

test -f "$SOURCE_BACKEND/package.json"
test -f "$SOURCE_BACKEND/src/server.js"
test -d "$SOURCE_BACKEND/node_modules"

# Validate critical production dependencies.
test -d "$SOURCE_BACKEND/node_modules/express"
test -d "$SOURCE_BACKEND/node_modules/pg"
test -d "$SOURCE_BACKEND/node_modules/dotenv"

# ------------------------------------------------------------
# 9. Install backend release
# ------------------------------------------------------------

log "Installing backend release..."

mkdir -p "$BACKEND_RELEASE"

cp -a "$SOURCE_BACKEND/." "$BACKEND_RELEASE/"

chown -R ubuntu:ubuntu "$BACKEND_RELEASE"

# ------------------------------------------------------------
# 10. Download frontend artifact
# ------------------------------------------------------------

log "Downloading frontend artifact..."

mkdir -p "$WORK_DIR/frontend"

aws s3 sync \
    "$FRONTEND_ARTIFACT" \
    "$WORK_DIR/frontend/" \
    --region "$AWS_REGION" \
    --only-show-errors

test -f "$WORK_DIR/frontend/index.html" || {
    log "Frontend index.html not found."
    exit 1
}

# ------------------------------------------------------------
# 11. Install frontend release
# ------------------------------------------------------------

log "Installing frontend release..."

mkdir -p "$FRONTEND_RELEASE"

cp -a "$WORK_DIR/frontend/." "$FRONTEND_RELEASE/"

chown -R www-data:www-data "$FRONTEND_RELEASE"

# ------------------------------------------------------------
# 12. Configure systemd service
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
# 13. Switch backend release
# ------------------------------------------------------------

log "Activating backend release..."

switch_symlink "$BACKEND_RELEASE" "$APP_ROOT/current"

BACKEND_SWITCHED=true

systemctl restart "$BACKEND_SERVICE"

# ------------------------------------------------------------
# 14. Switch frontend release
# ------------------------------------------------------------

log "Activating frontend release..."

switch_symlink "$FRONTEND_RELEASE" "$FRONTEND_ROOT/current"

FRONTEND_SWITCHED=true

# ------------------------------------------------------------
# 15. Validate and reload Nginx
# ------------------------------------------------------------

log "Validating Nginx..."

nginx -t

systemctl reload nginx

# ------------------------------------------------------------
# 16. Backend health check
# ------------------------------------------------------------

log "Checking backend health..."

HEALTH_CHECK_PASSED=false

for attempt in $(seq 1 15); do
    if curl -fsS \
        http://127.0.0.1:3000/health \
        >/dev/null; then

        HEALTH_CHECK_PASSED=true
        break
    fi

    log "Waiting for backend... attempt $attempt/15"
    sleep 2
done

if [[ "$HEALTH_CHECK_PASSED" != true ]]; then
    log "Backend health check failed."

    systemctl status "$BACKEND_SERVICE" --no-pager || true
    journalctl -u "$BACKEND_SERVICE" -n 50 --no-pager || true

    # Trigger rollback instead of reporting a successful deployment.
    exit 1
fi

log "Backend health check passed."

# ------------------------------------------------------------
# 17. Verify frontend
# ------------------------------------------------------------

log "Checking frontend..."

if ! curl -fsS http://127.0.0.1/ >/dev/null; then
    log "Frontend health check failed."
    exit 1
fi

# ------------------------------------------------------------
# 18. Cleanup old releases
# ------------------------------------------------------------

log "Cleaning old releases..."

find "$APP_ROOT/releases" -mindepth 1 -maxdepth 1 -type d \\
    -printf '%T@ %p\\n' |
    sort -rn |
    tail -n +6 |
    cut -d' ' -f2- |
    while IFS= read -r release; do
        [[ -n "$release" ]] && rm -rf -- "$release"
    done

find "$FRONTEND_ROOT/releases" -mindepth 1 -maxdepth 1 -type d \\
    -printf '%T@ %p\\n' |
    sort -rn |
    tail -n +6 |
    cut -d' ' -f2- |
    while IFS= read -r release; do
        [[ -n "$release" ]] && rm -rf -- "$release"
    done

log "Deployment completed successfully."
