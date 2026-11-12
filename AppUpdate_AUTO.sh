#!/bin/bash

################################################################################
# Automated Application Update Script
# Purpose: Update both frontend and backend from GitHub repository
# Repository: https://github.com/sarowar-alam/single-server-3tier-webapp
# Usage: ./AppUpdate_AUTO.sh [--no-backup] [--backend-only] [--frontend-only]
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GIT_DIR="/home/ubuntu/single-server-3tier-webapp"
APP_DEPLOY_DIR="/opt/bmi-app"
BACKEND_DIR="${APP_DEPLOY_DIR}/backend"
FRONTEND_DIR="${GIT_DIR}/frontend"
NGINX_WEB_ROOT="/var/www/bmi-health-tracker"
PM2_PROCESS_NAME="bmi-backend"
GIT_REPO="https://github.com/sarowar-alam/single-server-3tier-webapp"
BACKUP_DIR="/home/ubuntu/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Flags
CREATE_BACKUP=true
UPDATE_BACKEND=true
UPDATE_FRONTEND=true

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --no-backup) CREATE_BACKUP=false ;;
        --backend-only) UPDATE_FRONTEND=false ;;
        --frontend-only) UPDATE_BACKEND=false ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-backup        Skip creating backup before update"
            echo "  --backend-only     Update only backend"
            echo "  --frontend-only    Update only frontend"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_warning "Running as root is not recommended. Run as the ubuntu user instead."
    else
        print_info "Running as ubuntu user — sudo will be used for privileged operations."
    fi
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local all_good=true
    
    # Load NVM if it exists (Node.js was likely installed via NVM)
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
        print_info "Loading NVM environment..."
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        print_success "NVM loaded"
    fi
    
    # Check if git repo directory exists
    if [ ! -d "$GIT_DIR" ]; then
        print_error "Git repo directory not found: $GIT_DIR"
        all_good=false
    else
        print_success "Git repo directory found"
    fi
    
    # Check if deploy directory exists
    if [ ! -d "$APP_DEPLOY_DIR" ]; then
        print_warning "Deploy directory not found, creating: $APP_DEPLOY_DIR"
        sudo mkdir -p "$APP_DEPLOY_DIR"
        sudo chown -R "$USER:$USER" "$APP_DEPLOY_DIR"
    else
        print_success "Deploy directory found"
    fi
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        print_error "Git is not installed"
        all_good=false
    else
        print_success "Git is installed"
    fi
    
    # Check if npm is installed
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed"
        all_good=false
    else
        print_success "npm is installed"
    fi
    
    # Check if pm2 is installed
    if ! command -v pm2 &> /dev/null; then
        print_warning "PM2 is not installed, installing now..."
        npm install -g pm2
        if command -v pm2 &> /dev/null; then
            print_success "PM2 installed successfully"
        else
            print_error "Failed to install PM2"
            all_good=false
        fi
    else
        print_success "PM2 is installed"
    fi
    
    # Check if nginx directory exists
    if [ ! -d "$NGINX_WEB_ROOT" ]; then
        print_warning "Nginx web root not found, will create: $NGINX_WEB_ROOT"
        mkdir -p "$NGINX_WEB_ROOT"
    else
        print_success "Nginx web root found"
    fi
    
    if [ "$all_good" = false ]; then
        print_error "Prerequisites check failed. Please install missing components."
        exit 1
    fi
    
    print_success "All prerequisites met"
}

# Create backup
create_backup() {
    if [ "$CREATE_BACKUP" = false ]; then
        print_info "Skipping backup (--no-backup flag set)"
        return 0
    fi
    
    print_header "Creating Backup"
    
    mkdir -p "$BACKUP_DIR"
    BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"
    mkdir -p "$BACKUP_PATH"
    
    print_info "Backup location: $BACKUP_PATH"
    
    # Backup backend
    if [ "$UPDATE_BACKEND" = true ] && [ -d "$BACKEND_DIR" ]; then
        print_info "Backing up backend..."
        cp -r "$BACKEND_DIR" "${BACKUP_PATH}/backend"
        print_success "Backend backed up"
    fi
    
    # Backup frontend
    if [ "$UPDATE_FRONTEND" = true ] && [ -d "$FRONTEND_DIR" ]; then
        print_info "Backing up frontend..."
        cp -r "$FRONTEND_DIR" "${BACKUP_PATH}/frontend"
        print_success "Frontend backed up"
    fi
    
    # Backup deployed frontend
    if [ "$UPDATE_FRONTEND" = true ] && [ -d "$NGINX_WEB_ROOT" ]; then
        print_info "Backing up deployed frontend..."
        cp -r "$NGINX_WEB_ROOT" "${BACKUP_PATH}/nginx_web_root"
        print_success "Deployed frontend backed up"
    fi
    
    print_success "Backup completed: $BACKUP_PATH"
    
    # Keep only last 5 backups
    print_info "Cleaning old backups (keeping last 5)..."
    cd "$BACKUP_DIR"
    ls -t | tail -n +6 | xargs -r rm -rf
    print_success "Old backups cleaned"
}

# Pull latest code from GitHub
pull_latest_code() {
    print_header "Pulling Latest Code from GitHub"
    
    cd "$GIT_DIR"
    
    # Check if directory is a git repository
    if [ ! -d .git ]; then
        print_error "Not a git repository. Please clone the repository first:"
        print_info "git clone $GIT_REPO $GIT_DIR"
        exit 1
    fi
    
    # Get current branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    print_info "Current branch: $CURRENT_BRANCH"
    
    # Stash any local changes
    if ! git diff-index --quiet HEAD --; then
        print_warning "Local changes detected, stashing..."
        git stash
        print_success "Local changes stashed"
    fi
    
    # Pull latest code
    print_info "Pulling latest code..."
    if git pull origin "$CURRENT_BRANCH"; then
        print_success "Code updated successfully"
        
        # Show latest commit
        LATEST_COMMIT=$(git log -1 --pretty=format:"%h - %s (%cr) <%an>")
        print_info "Latest commit: $LATEST_COMMIT"
    else
        print_error "Failed to pull latest code"
        exit 1
    fi
}

# Update backend
update_backend() {
    if [ "$UPDATE_BACKEND" = false ]; then
        print_info "Skipping backend update"
        return 0
    fi
    
    print_header "Updating Backend"
    
    # Sync updated source from git repo to deploy dir (preserve .env and node_modules)
    print_info "Syncing backend source from git repo to $APP_DEPLOY_DIR/backend/..."
    rsync -a --exclude 'node_modules' --exclude '.env' --exclude 'logs' \
        "$GIT_DIR/backend/" "$APP_DEPLOY_DIR/backend/"
    print_success "Backend source synced"
    
    cd "$BACKEND_DIR"
    
    # Install dependencies
    print_info "Installing backend dependencies..."
    if npm install --production; then
        print_success "Backend dependencies installed"
    else
        print_error "Failed to install backend dependencies"
        exit 1
    fi
    
    # Restart PM2 process
    print_info "Restarting backend service (PM2)..."
    if pm2 restart "$PM2_PROCESS_NAME"; then
        print_success "Backend service restarted"
    else
        print_warning "PM2 restart failed, attempting to start..."
        if pm2 start "$PM2_PROCESS_NAME"; then
            print_success "Backend service started"
        else
            print_error "Failed to start backend service"
            print_info "Attempting to start with ecosystem file..."
            if [ -f ecosystem.config.js ]; then
                pm2 start ecosystem.config.js
                print_success "Backend started with ecosystem config"
            else
                print_error "Could not start backend service"
                exit 1
            fi
        fi
    fi
    
    # Save PM2 process list
    pm2 save > /dev/null 2>&1
    
    # Wait for backend to initialize
    print_info "Waiting for backend to initialize..."
    sleep 3
    
    # Check backend status
    print_info "Checking backend status..."
    if pm2 status | grep -q "$PM2_PROCESS_NAME"; then
        print_success "Backend is running"
        
        # Show backend logs (last 5 lines)
        print_info "Recent backend logs:"
        pm2 logs "$PM2_PROCESS_NAME" --nostream --lines 5
    else
        print_error "Backend is not running"
        print_info "Check logs with: pm2 logs $PM2_PROCESS_NAME"
        exit 1
    fi
}

# Update frontend
update_frontend() {
    if [ "$UPDATE_FRONTEND" = false ]; then
        print_info "Skipping frontend update"
        return 0
    fi
    
    print_header "Updating Frontend"
    
    cd "$GIT_DIR/frontend"
    
    # Install dependencies
    print_info "Installing frontend dependencies..."
    if npm install; then
        print_success "Frontend dependencies installed"
    else
        print_error "Failed to install frontend dependencies"
        exit 1
    fi
    
    # Build frontend
    print_info "Building frontend..."
    if npm run build; then
        print_success "Frontend built successfully"
    else
        print_error "Frontend build failed"
        exit 1
    fi
    
    # Check if build output exists
    if [ ! -d "dist" ]; then
        print_error "Build output directory 'dist' not found"
        exit 1
    fi
    
    if [ ! -f "dist/index.html" ]; then
        print_error "index.html not found in dist directory"
        exit 1
    fi
    
    print_success "Build output verified"
    
    # Deploy to Nginx
    print_info "Deploying frontend to Nginx..."
    
    # Create nginx directory if it doesn't exist
    sudo mkdir -p "$NGINX_WEB_ROOT"
    
    # Remove old files
    print_info "Removing old frontend files..."
    sudo rm -rf "${NGINX_WEB_ROOT:?}"/*
    
    # Copy new build
    print_info "Copying new build files..."
    sudo cp -r dist/* "$NGINX_WEB_ROOT/"
    
    # Set proper permissions
    print_info "Setting permissions..."
    sudo chown -R www-data:www-data "$NGINX_WEB_ROOT"
    sudo chmod -R 755 "$NGINX_WEB_ROOT"
    
    print_success "Frontend deployed to Nginx"
    
    # Verify deployment
    if [ -f "${NGINX_WEB_ROOT}/index.html" ]; then
        print_success "Deployment verified"
    else
        print_error "Deployment verification failed"
        exit 1
    fi
}

# Health checks
perform_health_checks() {
    print_header "Performing Health Checks"
    
    local all_healthy=true
    
    # Check backend API
    if [ "$UPDATE_BACKEND" = true ]; then
        print_info "Testing backend API..."
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/measurements | grep -q "200\|304"; then
            print_success "Backend API is responding"
        else
            print_warning "Backend API check failed (may need time to start)"
            all_healthy=false
        fi
    fi
    
    # Check PM2 status
    if [ "$UPDATE_BACKEND" = true ]; then
        print_info "Checking PM2 process status..."
        if pm2 list | grep -q "$PM2_PROCESS_NAME.*online"; then
            print_success "PM2 process is online"
        else
            print_error "PM2 process is not online"
            all_healthy=false
        fi
    fi
    
    # Check frontend files
    if [ "$UPDATE_FRONTEND" = true ]; then
        print_info "Checking frontend deployment..."
        if [ -f "${NGINX_WEB_ROOT}/index.html" ]; then
            print_success "Frontend files are deployed"
        else
            print_error "Frontend files not found"
            all_healthy=false
        fi
    fi
    
    # Check Nginx
    if [ "$UPDATE_FRONTEND" = true ]; then
        print_info "Checking Nginx status..."
        if systemctl is-active --quiet nginx; then
            print_success "Nginx is running"
        else
            print_warning "Nginx is not running"
            all_healthy=false
        fi
    fi
    
    if [ "$all_healthy" = true ]; then
        print_success "All health checks passed"
    else
        print_warning "Some health checks failed - please review"
    fi
}

# Display summary
display_summary() {
    print_header "Update Summary"
    
    echo -e "${GREEN}Application updated successfully!${NC}\n"
    
    if [ "$UPDATE_BACKEND" = true ]; then
        echo -e "${BLUE}Backend:${NC}"
        echo "  - Dependencies installed"
        echo "  - Service restarted via PM2"
        echo "  - Process name: $PM2_PROCESS_NAME"
        echo ""
    fi
    
    if [ "$UPDATE_FRONTEND" = true ]; then
        echo -e "${BLUE}Frontend:${NC}"
        echo "  - Dependencies installed"
        echo "  - Built with Vite"
        echo "  - Deployed to: $NGINX_WEB_ROOT"
        echo ""
    fi
    
    if [ "$CREATE_BACKUP" = true ]; then
        echo -e "${BLUE}Backup:${NC}"
        echo "  - Location: $BACKUP_PATH"
        echo ""
    fi
    
    echo -e "${BLUE}Next Steps:${NC}"
    SERVER_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<YOUR-EC2-IP>')
    echo "  1. Visit your application: http://${SERVER_IP}/"
    echo "  2. Test all functionality"
    echo "  3. Check backend logs: pm2 logs $PM2_PROCESS_NAME"
    echo "  4. Check frontend in browser console for errors"
    echo ""
    
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  - Backend status: pm2 status"
    echo "  - Backend logs: pm2 logs $PM2_PROCESS_NAME"
    echo "  - Nginx status: systemctl status nginx"
    echo "  - Nginx logs: tail -f /var/log/nginx/error.log"
    echo ""
}

# Rollback function
display_rollback_info() {
    if [ "$CREATE_BACKUP" = true ] && [ -d "$BACKUP_PATH" ]; then
        echo -e "\n${YELLOW}If you need to rollback:${NC}"
        echo "  cp -r ${BACKUP_PATH}/backend/* ${APP_DEPLOY_DIR}/backend/"
        echo "  cp -r ${BACKUP_PATH}/nginx_web_root/* ${NGINX_WEB_ROOT}/"
        echo "  pm2 restart $PM2_PROCESS_NAME"
        echo ""
    fi
}

# Main execution
main() {
    clear
    
    print_header "BMI Health Tracker - Automated Update Script"
    echo "Repository: $GIT_REPO"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    if [ "$UPDATE_BACKEND" = true ] && [ "$UPDATE_FRONTEND" = true ]; then
        print_info "Update mode: Both Backend and Frontend"
    elif [ "$UPDATE_BACKEND" = true ]; then
        print_info "Update mode: Backend Only"
    elif [ "$UPDATE_FRONTEND" = true ]; then
        print_info "Update mode: Frontend Only"
    fi
    
    # Execute update steps
    check_root
    check_prerequisites
    create_backup
    pull_latest_code
    update_backend
    update_frontend
    perform_health_checks
    display_summary
    display_rollback_info
    
    print_success "Update completed successfully!"
    echo ""
}

# Error handler
error_handler() {
    print_error "An error occurred during the update process"
    print_info "Check the output above for details"
    
    if [ "$CREATE_BACKUP" = true ] && [ -d "$BACKUP_PATH" ]; then
        print_warning "A backup was created at: $BACKUP_PATH"
        print_info "You may need to restore from backup"
    fi
    
    exit 1
}

# Set error trap
trap error_handler ERR

# Run main function
main
