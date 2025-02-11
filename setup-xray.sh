#!/bin/bash
set -e

# --- Helper Functions ---
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# --- Ensure the script is run as root ---
if [ "$EUID" -ne 0 ]; then
    echo_error "Please run this script as root."
    exit 1
fi

# --- 1) Prompt for Required Input ---
read -p "Enter the Xray Nginx domain (e.g., example.com): " XRAY_DOMAIN
read -p "Enter the Xray Nginx path (e.g., /xray): " XRAY_PATH
read -p "Enter your Let's Encrypt contact email: " LE_EMAIL

# --- 2) Update System and Install Dependencies ---
echo_info "Updating package lists..."
apt-get update -y

echo_info "Installing required packages: curl, nginx, certbot, and python3-certbot-nginx..."
apt-get install -y curl nginx certbot python3-certbot-nginx
echo_success "Required packages installed."

# --- 3) Install Xray ---
echo_info "Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo_success "Xray installed."

# --- 4) Set Up Xray Configuration ---
echo_info "Setting up Xray configuration..."
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# Generate 5 UUIDs for Xray clients
echo_info "Generating 5 UUIDs for Xray clients..."
UUIDS=()
for i in {1..5}; do
    UUIDS+=("$(xray uuid)")
done

echo_info "Creating Xray configuration file at '$XRAY_CONFIG'..."
cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 30001,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUIDS[0]}" },
          { "id": "${UUIDS[1]}" },
          { "id": "${UUIDS[2]}" },
          { "id": "${UUIDS[3]}" },
          { "id": "${UUIDS[4]}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$XRAY_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40001
          }
        ]
      }
    },
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
EOF
echo_success "Xray configuration file created."

# --- 5) Configure Nginx as a Reverse Proxy for Xray ---
echo_info "Creating Nginx site configuration for domain '$XRAY_DOMAIN'..."
NGINX_SITE="/etc/nginx/sites-available/$XRAY_DOMAIN"

cat > "$NGINX_SITE" <<EOF
server {
    server_name $XRAY_DOMAIN;
    listen 80;
    listen [::]:80;
    
    root /var/www/html;
    index index.html index.htm;

    # Default location
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Proxy Xray WebSocket connections
    location $XRAY_PATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:30001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
echo_success "Nginx site configuration created at '$NGINX_SITE'."

# Enable the new site (if not already enabled)
if [ ! -L "/etc/nginx/sites-enabled/$XRAY_DOMAIN" ]; then
    ln -s "$NGINX_SITE" /etc/nginx/sites-enabled/
fi

# Test and restart Nginx
echo_info "Testing Nginx configuration..."
nginx -t
echo_info "Restarting Nginx..."
systemctl restart nginx
echo_success "Nginx restarted."

# --- 6) Obtain SSL Certificate via Certbot ---
echo_info "Obtaining SSL certificate with Certbot for domain '$XRAY_DOMAIN'..."
certbot --nginx -d "$XRAY_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
echo_success "SSL certificate obtained and configured."

# --- 7) Modify Nginx for HTTP/2 Support ---
echo_info "Modifying Nginx configuration for HTTP/2 support..."

# Update the primary SSL listen directive
sed -i 's/listen 443 ssl; # managed by Certbot/listen 443 ssl http2; # managed by Certbot/' "$NGINX_SITE"

# Ensure the IPv6 listen directive includes HTTP/2
if ! grep -q "listen \[::\]:443 ssl http2;" "$NGINX_SITE"; then
    if grep -q "listen \[::\]:443 ssl;" "$NGINX_SITE"; then
        sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' "$NGINX_SITE"
    else
        sed -i '/listen 443 ssl http2; # managed by Certbot/a \    listen [::]:443 ssl http2;' "$NGINX_SITE"
    fi
fi

# Test and reload Nginx configuration
echo_info "Testing modified Nginx configuration..."
nginx -t
echo_info "Reloading Nginx..."
systemctl reload nginx
echo_success "Nginx updated for HTTP/2 support."

# --- 8) Display Setup Summary ---
echo -e "\n===== Xray Setup Summary ====="
echo "Xray VLESS Domain: $XRAY_DOMAIN"
echo "Xray VLESS Path: $XRAY_PATH"
echo "Xray VLESS UUIDs:"
for i in {1..5}; do
    echo "  UUID $i: ${UUIDS[$((i-1))]}"
done
echo "=============================="
echo_success "Xray setup completed successfully!"

exit 0
