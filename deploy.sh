```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Production deployment script
# Runs as: ubuntu
# Trigger: AWS SSM Run Command
# Artifact: Frontend dist downloaded from private S3
# ============================================================

# Required environment variable passed by SSM.
: "${ARTIFACT_S3_URI:?ARTIFACT_S3_URI is required}"

APP_DIR="/home/ubuntu/projects/single-server-3tier-webapp"
BACKEND_DIR="$APP_DIR/backend"

FRONTEND_DIR="/var/www/bmi-frontend"
TMP_DIST_DIR="$(mktemp -d)"

# Always clean temporary files.
trap 'rm -rf "$TMP_DIST_DIR"' EXIT

echo "=========================================="
echo "Starting application deployment"
echo "Artifact: $ARTIFACT_S3_URI"
echo "=========================================="

# ------------------------------------------------------------
# 1. Validate application directories
# ------------------------------------------------------------

echo "--- 1. Validating application directories ---"

test -d "$APP_DIR" || {
    echo "Application directory missing: $APP_DIR"
    exit 1
}

test -d "$BACKEND_DIR" || {
    echo "Backend directory missing: $BACKEND_DIR"
    exit 1
}

# ------------------------------------------------------------
# 2. Update backend source code
# ------------------------------------------------------------

echo "--- 2. Pulling latest backend source ---"

cd "$APP_DIR"

git pull --ff-only origin main

# ------------------------------------------------------------
# 3. Validate production environment
# ------------------------------------------------------------

echo "--- 3. Checking backend environment ---"

test -f "$BACKEND_DIR/.env" || {
    echo "Backend .env file missing!"
    exit 1
}

# ------------------------------------------------------------
# 4. Install backend production dependencies
# ------------------------------------------------------------

echo "--- 4. Installing backend dependencies ---"

cd "$BACKEND_DIR"

npm ci --omit=dev

# ------------------------------------------------------------
# 5. Restart backend using PM2
# ------------------------------------------------------------

echo "--- 5. Restarting backend ---"

command -v pm2 >/dev/null 2>&1 || {
    echo "PM2 is not available for ubuntu user!"
    exit 1
}

if pm2 describe bmi-backend >/dev/null 2>&1; then
    pm2 restart bmi-backend --update-env
else
    # Assumes the backend entry point is src/server.js.
    pm2 start src/server.js --name bmi-backend
fi

pm2 save

# ------------------------------------------------------------
# 6. Download frontend artifact from private S3
# ------------------------------------------------------------

echo "--- 6. Downloading frontend artifact from S3 ---"

aws s3 sync \
    "$ARTIFACT_S3_URI" \
    "$TMP_DIST_DIR/" \
    --only-show-errors

test -f "$TMP_DIST_DIR/index.html" || {
    echo "Frontend artifact index.html missing!"
    exit 1
}

# ------------------------------------------------------------
# 7. Prepare frontend deployment
# ------------------------------------------------------------

echo "--- 7. Preparing frontend files ---"

sudo mkdir -p "$FRONTEND_DIR"

# Copy into a temporary directory on the same filesystem.
STAGING_DIR="/var/www/.bmi-frontend-staging-$$"
BACKUP_DIR="/var/www/.bmi-frontend-backup-$$"

sudo rm -rf "$STAGING_DIR" "$BACKUP_DIR"
sudo mkdir -p "$STAGING_DIR"

sudo cp -a "$TMP_DIST_DIR/." "$STAGING_DIR/"
sudo chown -R www-data:www-data "$STAGING_DIR"

# ------------------------------------------------------------
# 8. Replace frontend with rollback on failure
# ------------------------------------------------------------

echo "--- 8. Deploying frontend ---"

if [ -d "$FRONTEND_DIR" ]; then
    sudo mv "$FRONTEND_DIR" "$BACKUP_DIR"
fi

sudo mv "$STAGING_DIR" "$FRONTEND_DIR"

# ------------------------------------------------------------
# 9. Validate and reload Nginx
# ------------------------------------------------------------

echo "--- 9. Validating Nginx configuration ---"

if ! sudo nginx -t; then
    echo "Nginx configuration validation failed!"

    sudo rm -rf "$FRONTEND_DIR"

    if [ -d "$BACKUP_DIR" ]; then
        sudo mv "$BACKUP_DIR" "$FRONTEND_DIR"
    fi

    exit 1
fi

if ! sudo systemctl reload nginx; then
    echo "Nginx reload failed! Restoring previous frontend."

    sudo rm -rf "$FRONTEND_DIR"

    if [ -d "$BACKUP_DIR" ]; then
        sudo mv "$BACKUP_DIR" "$FRONTEND_DIR"
        sudo systemctl reload nginx || true
    fi

    exit 1
fi

# ------------------------------------------------------------
# 10. Cleanup previous frontend
# ------------------------------------------------------------

sudo rm -rf "$BACKUP_DIR"

echo "=========================================="
echo "Deployment completed successfully!"
echo "=========================================="
```