#!/bin/sh
set -e

echo "Starting Nginx with Active Pool: ${ACTIVE_POOL}"

# Create log directory
mkdir -p /var/log/nginx

# REMOVE the symlinks that point to stdout/stderr
echo "🔧 Removing symlinks and creating real log files..."
rm -f /var/log/nginx/access.log
rm -f /var/log/nginx/error.log

# Create actual log files
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log

# Set proper permissions for nginx to write
chown -R nginx:nginx /var/log/nginx
chmod -R 766 /var/log/nginx

# Show final directory structure
echo "📝 Final log directory contents:"
ls -la /var/log/nginx/

# Substitute environment variables in nginx config
envsubst '${ACTIVE_POOL}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf

echo "🔍 Nginx access_log configuration:"
grep access_log /etc/nginx/nginx.conf

nginx -t
echo "✅ Nginx configuration validated"

# Start nginx in foreground
exec nginx -g 'daemon off;'