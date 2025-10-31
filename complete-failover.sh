#!/bin/bash
echo "🎯 COMPLETE FAILOVER CYCLE"

# Ensure both apps are running
docker-compose start app_blue app_green
sleep 5

# Switch to blue first
echo "1. Switching to blue..."
docker-compose exec nginx sed -i 's/server app_green:3000/server app_blue:3000/' /etc/nginx/nginx.conf
docker-compose exec nginx sed -i 's/server app_blue:3000 backup/server app_green:3000 backup/' /etc/nginx/nginx.conf
docker-compose exec nginx nginx -s reload

# Generate traffic to blue
for i in {1..15}; do
    curl -s http://localhost:8080/version > /dev/null
    sleep 0.2
done

# Now trigger failover to green
echo "2. Triggering failover to green..."
docker-compose stop app_blue
sleep 3

# Generate traffic - this should trigger the failover alert
for i in {1..20}; do
    curl -s http://localhost:8080/version
    sleep 0.2
done

echo "3. Checking watcher..."
docker-compose logs alert_watcher --tail=15

# Restart blue
docker-compose start app_blue
echo "✅ Failover cycle complete - Check Slack!"
c