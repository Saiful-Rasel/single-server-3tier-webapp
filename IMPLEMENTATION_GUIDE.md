# BMI Health Tracker — Manual Deployment Guide (v5.0)

> Complete step-by-step guide to deploy the BMI Health Tracker on AWS EC2 Ubuntu using a layer-based approach.
> Updated: April 19, 2026
> Notes: Restructured to layer-based approach, replaced NVM with system-wide Node.js via NodeSource.

---

## Table of Contents

1. [Application Overview](#1-application-overview)
2. [Prerequisites](#2-prerequisites)
3. [Part A — AWS Console Setup](#part-a--aws-console-setup)
4. [Part B — Server Bootstrap](#part-b--server-bootstrap)
5. [Step 1 — Database Layer](#step-1--database-layer)
6. [Step 2 — Backend Layer](#step-2--backend-layer)
7. [Step 3 — Frontend Layer](#step-3--frontend-layer)
8. [Step 4 — SSL Layer (Optional)](#step-4--ssl-layer-optional)
9. [Step 5 — Final Health Checks](#step-5--final-health-checks)
10. [Step 6 — Day-2 Commands](#step-6--day-2-commands)
11. [Step 7 — Troubleshooting](#step-7--troubleshooting)

---

## 1. Application Overview

**BMI Health Tracker** — a 3-tier full-stack web application.

| Layer    | Technology                     | Runs on        |
|----------|--------------------------------|----------------|
| Frontend | React 18 + Vite 5 + Chart.js 4 | Nginx (static) |
| Backend  | Node.js 20 LTS + Express 4     | PM2 port 3000  |
| Database | PostgreSQL 14                  | localhost:5432 |

Traffic flow: `Browser → Nginx :80/:443 → /api/* proxy → Node :3000 → PostgreSQL`

---

## 2. Prerequisites

| Item | Detail |
|------|--------|
| AWS account | EC2 launch permissions |
| EC2 key pair | `.pem` file on your local machine |
| Ubuntu 22.04 LTS instance | `t2.micro` or larger |
| Security group rules | Ports 22, 80, 443 open inbound |
| Domain (optional) | Required only for SSL — A record pointing to EC2 IP |   

---

## Part A — AWS Console Setup

### A.1 Launch EC2 Instance
1. AMI: **Ubuntu Server 22.04 LTS**
2. Instance type: `t2.micro`
3. Storage: 20 GB gp3

### A.2 Configure Security Group
| Type  | Protocol | Port | Source    |
|-------|----------|------|-----------|
| SSH   | TCP      | 22   | Your IP   |
| HTTP  | TCP      | 80   | 0.0.0.0/0 |
| HTTPS | TCP      | 443  | 0.0.0.0/0 |

---

## Part B — Server Bootstrap

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip build-essential
cd ~
git clone https://github.com/sarowar-alam/single-server-3tier-webapp.git        
cd single-server-3tier-webapp
```

---

## Step 1 — Database Layer

### 1.1 Install PostgreSQL
```bash
sudo apt install -y postgresql postgresql-contrib
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

### 1.2 Create Database and User
```bash
sudo -u postgres psql -c "CREATE USER bmi_user WITH PASSWORD 'your_password';"  
sudo -u postgres psql -c "CREATE DATABASE bmidb;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE bmidb TO bmi_user;"  
sudo -u postgres psql -d bmidb -c "GRANT ALL ON SCHEMA public TO bmi_user;"     
sudo -u postgres psql -d bmidb -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO bmi_user;"
```

### 1.3 Configure Authentication
```bash
PG_HBA=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW hba_file')
sudo cp "$PG_HBA" "${PG_HBA}.backup"
sudo sed -i "/^# IPv4 local connections:/a host    bmidb    bmi_user    127.0.0.1/32    md5" "$PG_HBA"
sudo systemctl reload postgresql
```

### 1.4 Test Connection
```bash
PGPASSWORD=your_password psql -U bmi_user -d bmidb -h localhost -c "SELECT 1;"
```

---

## Step 2 — Backend Layer

### 2.1 Install Node.js (System-wide) and PM2
```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2
node -v && npm -v && pm2 -v
```

### 2.2 Create Directory and Environment
```bash
sudo mkdir -p /opt/bmi-app/backend
sudo chown -R $USER:$USER /opt/bmi-app

cat > /opt/bmi-app/backend/.env << EOF
DATABASE_URL=postgresql://bmi_user:your_password@localhost:5432/bmidb
DB_USER=bmi_user
DB_PASSWORD=your_password
DB_NAME=bmidb
DB_HOST=localhost
DB_PORT=5432
PORT=3000
NODE_ENV=production
CORS_ORIGIN=*
EOF
chmod 600 /opt/bmi-app/backend/.env
```

### 2.3 Deploy and Run Migrations
```bash
rsync -a --exclude 'node_modules' --exclude '.env' --exclude 'logs' ~/single-server-3tier-webapp/backend/ /opt/bmi-app/backend/
cd /opt/bmi-app/backend
npm install --production

PGPASSWORD=your_password psql -U bmi_user -d bmidb -h localhost -f migrations/001_create_measurements.sql
PGPASSWORD=your_password psql -U bmi_user -d bmidb -h localhost -f migrations/002_add_measurement_date.sql
```

### 2.4 Start Backend with PM2
```bash
pm2 start src/server.js --name bmi-backend --env production
pm2 save
sudo env PATH=$PATH:$(which node) $(which pm2) startup systemd -u $USER --hp $HOME
pm2 save
```

---

## Step 3 — Frontend Layer

### 3.1 Install Nginx
```bash
sudo apt install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx
```

### 3.2 Build and Deploy React App
```bash
cd ~/single-server-3tier-webapp/frontend
npm install
npm run build
sudo mkdir -p /var/www/bmi-health-tracker
sudo rm -rf /var/www/bmi-health-tracker/*
sudo cp -r dist/* /var/www/bmi-health-tracker/
sudo chown -R www-data:www-data /var/www/bmi-health-tracker
sudo chmod -R 755 /var/www/bmi-health-tracker
```

### 3.3 Configure Nginx
Get EC2 IP:
```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
EC2_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo $EC2_IP
```

Write Nginx virtual host config (replace `YOUR_SERVER_NAME` with your EC2 IP or domain):
```bash
sudo tee /etc/nginx/sites-available/bmi-health-tracker > /dev/null << 'EOF'
server {
    listen 80;
    server_name YOUR_SERVER_NAME;

    root /var/www/bmi-health-tracker;
    index index.html;

    # React SPA — serve index.html for all non-file routes
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Proxy API requests to Node.js backend
    location /api/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
}
EOF
```

Enable site and reload:
```bash
sudo ln -sf /etc/nginx/sites-available/bmi-health-tracker /etc/nginx/sites-enabled/bmi-health-tracker
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
```

---

## Step 4 — SSL Layer (Optional)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com --non-interactive --agree-tos --email your@email.com --redirect
sudo certbot renew --dry-run
```

---

## Step 5 — Final Health Checks
- Backend: `curl -f http://localhost:3000/api/measurements`
- Frontend (Nginx): `curl -s -o /dev/null -w "%{http_code}" http://localhost/`
- PM2: `pm2 status`

---

## Step 6 — Day-2 Commands
- Logs: `pm2 logs bmi-backend`
- Restart: `pm2 restart bmi-backend` / `sudo systemctl restart nginx`
- DB: `sudo -u postgres psql`

---

## Step 7 — Troubleshooting
- 502 Bad Gateway: Backend down (Check PM2)
- 404/500 on Frontend: React build or Nginx try_files issue.

---

**Last Updated**: April 19, 2026
**Version**: 5.0
**Notes**: Restructured to layer-based approach, replaced NVM with system-wide Node.js (NodeSource).

---
*MD Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
---
