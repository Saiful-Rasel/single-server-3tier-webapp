# BMI Health Tracker — Application Update Guide

> **Step-by-step manual equivalent of `AppUpdate_AUTO.sh`.**
> Every command here maps to what the automation script does internally.
> For routine updates run the script directly; use this guide when you need fine-grained control or the script is unavailable.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Usage & Flags](#2-usage--flags)
3. [Full Update — Both Backend and Frontend](#3-full-update--both-backend-and-frontend)
   - [Prerequisite Check](#31-prerequisite-check)
   - [Create Backup](#32-create-backup)
   - [Pull Latest Code](#33-pull-latest-code)
   - [Update Backend](#34-update-backend)
   - [Update Frontend](#35-update-frontend)
   - [Health Checks](#36-health-checks)
   - [Rollback](#37-rollback)
4. [Backend-Only Update (`--backend-only`)](#4-backend-only-update----backend-only)
5. [Frontend-Only Update (`--frontend-only`)](#5-frontend-only-update----frontend-only)
6. [Skip Backup (`--no-backup`)](#6-skip-backup----no-backup)
7. [Additional Scenarios](#7-additional-scenarios)
   - [Database Migrations](#71-database-migrations)
   - [Environment Variable Changes](#72-environment-variable-changes)
   - [Nginx Configuration Changes](#73-nginx-configuration-changes)
8. [Quick Reference Commands](#8-quick-reference-commands)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Overview

`AppUpdate_AUTO.sh` handles all routine application updates from GitHub. This guide documents every command it runs so you can do the same manually.

| Variable | Value |
|----------|-------|
| Git repository directory | `~/single-server-3tier-webapp/` |
| Backend runtime directory | `/opt/bmi-app/backend/` |
| Frontend source directory | `~/single-server-3tier-webapp/frontend/` |
| Nginx web root | `/var/www/bmi-health-tracker/` |
| PM2 process name | `bmi-backend` |
| Backup directory | `~/backups/` |

**Default script flow (both layers):**

```
check_root → check_prerequisites → create_backup → pull_latest_code
  → update_backend → update_frontend → health_checks → summary → rollback_info
```

---

## 2. Usage & Flags

```bash
cd ~/single-server-3tier-webapp

# Update both backend and frontend (default)
./AppUpdate_AUTO.sh

# Update backend only
./AppUpdate_AUTO.sh --backend-only

# Update frontend only
./AppUpdate_AUTO.sh --frontend-only

# Skip the backup step (faster)
./AppUpdate_AUTO.sh --no-backup

# Combine flags
./AppUpdate_AUTO.sh --backend-only --no-backup
./AppUpdate_AUTO.sh --frontend-only --no-backup
```

---

## 3. Full Update — Both Backend and Frontend

SSH to the server first:

```bash
ssh -i your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

### 3.1 Prerequisite Check

The script validates the environment before making any changes. Do these checks manually:

```bash
# Load NVM (Node.js was installed via NVM)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Verify tools are present
git --version         # must succeed
npm --version         # must succeed
pm2 --version         # must succeed
node --version        # must succeed

# Verify directories exist
ls ~/single-server-3tier-webapp/      # git repo
ls /opt/bmi-app/                      # deploy root

# Create deploy dir if missing
sudo mkdir -p /opt/bmi-app
sudo chown -R $USER:$USER /opt/bmi-app

# Verify Nginx web root exists
ls /var/www/bmi-health-tracker/ || sudo mkdir -p /var/www/bmi-health-tracker

# Install PM2 if missing
command -v pm2 || npm install -g pm2
```

### 3.2 Create Backup

The script backs up to `~/backups/backup_YYYYMMDD_HHMMSS/` and keeps only the last 5.

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$HOME/backups/backup_$TIMESTAMP"
mkdir -p "$BACKUP_PATH"

echo "Backup location: $BACKUP_PATH"

# Backup backend runtime directory
cp -r /opt/bmi-app/backend "$BACKUP_PATH/backend"

# Backup frontend source from git repo
cp -r ~/single-server-3tier-webapp/frontend "$BACKUP_PATH/frontend"

# Backup currently deployed frontend (Nginx web root)
cp -r /var/www/bmi-health-tracker "$BACKUP_PATH/nginx_web_root"

echo "Backup complete"

# Keep only the last 5 backups
cd "$HOME/backups"
ls -t | tail -n +6 | xargs -r rm -rf
echo "Old backups cleaned"
```

### 3.3 Pull Latest Code

```bash
cd ~/single-server-3tier-webapp

# Confirm it is a git repository
ls .git

# Show current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $CURRENT_BRANCH"

# Stash local changes if any (the script does this automatically)
git diff-index --quiet HEAD -- || git stash

# Pull latest
git pull origin "$CURRENT_BRANCH"

# Confirm the latest commit
git log -1 --pretty=format:"%h - %s (%cr) <%an>"
```

### 3.4 Update Backend

```bash
# Sync source from git repo to runtime directory
# Excludes node_modules, .env, and logs (preserves existing .env credentials)
rsync -a \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude 'logs' \
  ~/single-server-3tier-webapp/backend/ \
  /opt/bmi-app/backend/

# Confirm .env was not overwritten
ls -la /opt/bmi-app/backend/.env

# Install / update backend dependencies
cd /opt/bmi-app/backend
npm install --production

# Restart the PM2 process
pm2 restart bmi-backend

# If restart fails (process not registered), start it
# pm2 start src/server.js --name bmi-backend --env production

# Save the PM2 process list
pm2 save

# Wait for the server to finish starting
sleep 3

# Confirm the process is online
pm2 status
# bmi-backend row must show: online

# Check recent log lines
pm2 logs bmi-backend --nostream --lines 5
```

### 3.5 Update Frontend

```bash
cd ~/single-server-3tier-webapp/frontend

# Install / update frontend dependencies
npm install

# Build the React app with Vite
npm run build
# Expected: vite prints module count and output file sizes

# Verify build output
ls -la dist/
# Must contain: index.html

[ -f dist/index.html ] && echo "Build OK" || echo "ERROR: index.html missing"

# Deploy to Nginx web root
sudo mkdir -p /var/www/bmi-health-tracker

# Remove stale files
sudo rm -rf /var/www/bmi-health-tracker/*

# Copy new build
sudo cp -r dist/* /var/www/bmi-health-tracker/

# Set correct ownership and permissions
sudo chown -R www-data:www-data /var/www/bmi-health-tracker
sudo chmod -R 755 /var/www/bmi-health-tracker

# Verify deployment
ls -la /var/www/bmi-health-tracker/
# Must show index.html — if missing it causes a redirect loop in Nginx
```

### 3.6 Health Checks

```bash
# 1. Backend API responds directly (200 or 304)
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/measurements
# Expected: 200

# 2. PM2 process is online
pm2 list | grep "bmi-backend.*online"
# Must print a line

# 3. Frontend index.html is deployed
ls /var/www/bmi-health-tracker/index.html
# Must exist

# 4. Nginx is active
systemctl is-active nginx
# Expected: active

# 5. API through Nginx proxy
curl -s -o /dev/null -w "%{http_code}" http://localhost/api/measurements
# Expected: 200

# 6. Get your EC2 IP and open in browser
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4
```

### 3.7 Rollback

If any step fails, restore from the backup created in [Step 3.2](#32-create-backup):

```bash
# Set BACKUP_PATH to the backup you want to restore
BACKUP_PATH="$HOME/backups/backup_YYYYMMDD_HHMMSS"   # adjust timestamp

# Restore backend runtime
cp -r "$BACKUP_PATH/backend/"* /opt/bmi-app/backend/
pm2 restart bmi-backend

# Restore deployed frontend
sudo cp -r "$BACKUP_PATH/nginx_web_root/"* /var/www/bmi-health-tracker/
sudo chown -R www-data:www-data /var/www/bmi-health-tracker

# Confirm
pm2 status
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/measurements
```

---

## 4. Backend-Only Update (`--backend-only`)

*Equivalent to running `./AppUpdate_AUTO.sh --backend-only`.*
Use when: backend logic, routes, calculations, or `package.json` changed.

```bash
# Load NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Pull latest code
cd ~/single-server-3tier-webapp
git pull origin "$(git rev-parse --abbrev-ref HEAD)"

# Backup backend runtime only
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$HOME/backups/backup_$TIMESTAMP"
cp -r /opt/bmi-app/backend "$HOME/backups/backup_$TIMESTAMP/backend"

# Sync and install
rsync -a --exclude 'node_modules' --exclude '.env' --exclude 'logs' \
  ~/single-server-3tier-webapp/backend/ /opt/bmi-app/backend/
cd /opt/bmi-app/backend
npm install --production

# Restart
pm2 restart bmi-backend
pm2 save
sleep 3
pm2 status

# Health check
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/measurements
```

---

## 5. Frontend-Only Update (`--frontend-only`)

*Equivalent to running `./AppUpdate_AUTO.sh --frontend-only`.*
Use when: React components, styles, or Vite config changed.

```bash
# Load NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Pull latest code
cd ~/single-server-3tier-webapp
git pull origin "$(git rev-parse --abbrev-ref HEAD)"

# Backup deployed frontend only
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$HOME/backups/backup_$TIMESTAMP"
cp -r ~/single-server-3tier-webapp/frontend "$HOME/backups/backup_$TIMESTAMP/frontend"
cp -r /var/www/bmi-health-tracker "$HOME/backups/backup_$TIMESTAMP/nginx_web_root"

# Build
cd ~/single-server-3tier-webapp/frontend
npm install
npm run build
[ -f dist/index.html ] || { echo "Build failed: index.html missing"; exit 1; }

# Deploy
sudo rm -rf /var/www/bmi-health-tracker/*
sudo cp -r dist/* /var/www/bmi-health-tracker/
sudo chown -R www-data:www-data /var/www/bmi-health-tracker
sudo chmod -R 755 /var/www/bmi-health-tracker

# Health checks — no Nginx restart needed (static files update immediately)
ls /var/www/bmi-health-tracker/index.html
systemctl is-active nginx
# Hard-refresh in browser: Ctrl+F5 (Windows) / Cmd+Shift+R (Mac)
```

---

## 6. Skip Backup (`--no-backup`)

Add `--no-backup` to any flag combination to skip the backup step. Use when:
- You are iterating quickly on a development server
- You already have a recent manual backup

```bash
# Example: full update without backup
./AppUpdate_AUTO.sh --no-backup

# Example: backend-only without backup
./AppUpdate_AUTO.sh --backend-only --no-backup
```

> Warning: without a backup you cannot roll back automatically if something goes wrong.
> Always have a database backup if you are applying schema changes.

---

## 7. Additional Scenarios

### 7.1 Database Migrations

The automation script does **not** run migrations automatically. Apply them manually:

```bash
# Get the DB password
DB_PASS=$(grep DB_PASSWORD /opt/bmi-app/backend/.env | cut -d= -f2)

# Apply a specific migration
PGPASSWORD=$DB_PASS psql -U bmi_user -d bmidb -h localhost \
  -f ~/single-server-3tier-webapp/backend/migrations/003_your_migration.sql

# Verify the change
PGPASSWORD=$DB_PASS psql -U bmi_user -d bmidb -h localhost -c "\dt"

# Always restart backend after schema changes
pm2 restart bmi-backend
```

> Always backup the database before running migrations:
> ```bash
> PGPASSWORD=$DB_PASS pg_dump -U bmi_user -h localhost bmidb > ~/db_backup_$(date +%Y%m%d_%H%M%S).sql
> ```

---

### 7.2 Environment Variable Changes

The `.env` file lives in the **runtime** directory, not the git repo.

```bash
# Edit
nano /opt/bmi-app/backend/.env

# Verify
cat /opt/bmi-app/backend/.env

# Ensure it stays private
chmod 600 /opt/bmi-app/backend/.env

# Restart PM2 so it picks up the new values
pm2 restart bmi-backend --update-env

# Check for connection errors
pm2 logs bmi-backend --lines 20
```

> Never commit `.env` to Git — it is excluded by `.gitignore` and by the rsync rule.

---

### 7.3 Nginx Configuration Changes

```bash
# Edit
sudo nano /etc/nginx/sites-available/bmi-health-tracker

# Test before applying
sudo nginx -t
# Expected:
#   nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
#   nginx: configuration file /etc/nginx/nginx.conf test is successful

# Apply without dropping connections
sudo systemctl reload nginx

# For major changes (port, SSL) do a full restart
sudo systemctl restart nginx

# Verify
sudo systemctl status nginx
sudo tail -f /var/log/nginx/bmi-error.log
```

---

## 8. Quick Reference Commands

```bash
# ——— Git ———
cd ~/single-server-3tier-webapp
git status
git log --oneline -5
git pull origin main
git stash ; git stash pop

# ——— PM2 / Backend ———
pm2 status                           # All processes
pm2 logs bmi-backend                 # Stream logs
pm2 logs bmi-backend --lines 50      # Last 50 lines
pm2 restart bmi-backend              # Restart (brief downtime)
pm2 reload bmi-backend               # Zero-downtime reload
pm2 stop bmi-backend                 # Stop
pm2 save                             # Persist process list

# ——— Frontend Build & Deploy ———
cd ~/single-server-3tier-webapp/frontend
npm install && npm run build
sudo rm -rf /var/www/bmi-health-tracker/*
sudo cp -r dist/* /var/www/bmi-health-tracker/
sudo chown -R www-data:www-data /var/www/bmi-health-tracker && sudo chmod -R 755 /var/www/bmi-health-tracker

# ——— Nginx ———
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart nginx
sudo systemctl status nginx
sudo tail -f /var/log/nginx/bmi-error.log
sudo tail -f /var/log/nginx/bmi-access.log

# ——— Database ———
DB_PASS=$(grep DB_PASSWORD /opt/bmi-app/backend/.env | cut -d= -f2)
PGPASSWORD=$DB_PASS psql -U bmi_user -d bmidb -h localhost
PGPASSWORD=$DB_PASS psql -U bmi_user -d bmidb -h localhost -c "SELECT COUNT(*) FROM measurements;"
PGPASSWORD=$DB_PASS pg_dump -U bmi_user -h localhost bmidb > ~/db_backup_$(date +%Y%m%d_%H%M%S).sql

# ——— System ———
df -h
free -h
sudo netstat -tlnp | grep -E '80|3000|5432'
sudo systemctl status pm2-ubuntu
```

---

## 9. Troubleshooting

### Backend API returns 502 Bad Gateway

PM2 process is down.

```bash
pm2 status
pm2 logs bmi-backend --lines 30
# Restart:
cd /opt/bmi-app/backend
pm2 start src/server.js --name bmi-backend --env production
pm2 save
```

---

### `SASL: client password must be a string`

`DB_PASSWORD` is empty or missing in `/opt/bmi-app/backend/.env`.

```bash
nano /opt/bmi-app/backend/.env
# Set: DB_PASSWORD=yourpassword
pm2 restart bmi-backend --update-env
```

---

### Frontend changes not appearing in browser

1. Hard-refresh: **Ctrl+F5** (Windows) / **Cmd+Shift+R** (Mac)
2. Check that the new build was deployed:

```bash
stat /var/www/bmi-health-tracker/index.html
ls -lt /var/www/bmi-health-tracker/assets/ | head -5
```

3. Rebuild and redeploy if files are old (see [Section 5](#5-frontend-only-update----frontend-only)).

---

### Nginx redirect loop (500 error)

`index.html` is missing from the Nginx web root.

```bash
ls /var/www/bmi-health-tracker/
# If empty — re-run the frontend deploy steps in Section 3.5 or Section 5
```

---

### PM2 not starting after server reboot

```bash
pm2 startup systemd -u ubuntu --hp /home/ubuntu
# Copy and run the command it prints, then:
pm2 save
sudo systemctl status pm2-ubuntu
```

---

### Git pull fails due to local changes

```bash
cd ~/single-server-3tier-webapp
git stash
git pull origin main
# Apply stashed changes back if needed:
git stash pop
```

---

### rsync accidentally overwrote .env

Restore from the backup created in Step 3.2:

```bash
cp "$HOME/backups/backup_YYYYMMDD_HHMMSS/backend/.env" /opt/bmi-app/backend/.env
chmod 600 /opt/bmi-app/backend/.env
pm2 restart bmi-backend --update-env
```

---

**Last Updated**: April 19, 2026
**Version**: 2.0
**Automation script**: `AppUpdate_AUTO.sh`

---

*MD Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
