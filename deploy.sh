#!/bin/bash
set -e

echo "--- 1. Pulling or Updating Repository ---"
git pull origin main

echo "--- 2. Installing Backend Dependencies ---"
cd backend
npm install

echo "--- 3. Configuring Backend Environment (.env) ---"
echo "PORT=3000" > .env
echo "NODE_ENV=production" >> .env
echo "DATABASE_URL=$DB_URL" >> .env
echo "FRONTEND_URL=$FRONTEND_URL" >> .env

echo "--- 4. Managing Backend with PM2 ---"
pm2 describe bmi-backend > /dev/null && pm2 restart bmi-backend || pm2 start src/server.js --name "bmi-backend"
pm2 save

echo "--- 5. Building Frontend Assets ---"
cd ../frontend
npm install
npm run build

echo "--- 6. Deploying Frontend to Nginx Directory ---"
sudo mkdir -p /var/www/bmi-frontend
sudo rm -rf /var/www/bmi-frontend/*
sudo cp -r dist/* /var/www/bmi-frontend/
sudo chown -R www-data:www-data /var/www/bmi-frontend

echo "--- 7. Reloading Nginx ---"
sudo systemctl reload nginx
echo "Deployment to Private Server completed successfully!"
