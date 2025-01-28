#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display messages
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo_error "Please run as root."
    exit 1
fi

# 1) Prompt for user input
read -p "Enter the desired hostname: " NEW_HOSTNAME
read -p "Enter the new username: " NEW_USER
read -s -p "Enter the password for $NEW_USER: " USER_PASS
echo
read -p "Enter the Xray Nginx domain (e.g., example.com): " XRAY_DOMAIN
read -p "Enter the Xray Nginx path (e.g., /xray): " XRAY_PATH
read -p "Enter your Let's Encrypt contact email: " LE_EMAIL
read -p "Enter your Tailscale Auth Key (leave blank to authenticate manually): " TAILSCALE_AUTHKEY

# 2) Set Hostname
echo_info "Setting hostname to '$NEW_HOSTNAME'..."
hostnamectl set-hostname "$NEW_HOSTNAME"
echo_success "Hostname set to '$NEW_HOSTNAME'."

# Update /etc/hosts to reflect the new hostname
echo_info "Updating /etc/hosts with the new hostname..."
sed -i "s/127.0.1.1\s.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
echo_success "/etc/hosts updated."

# 3) Set Timezone to Asia/Singapore
echo_info "Setting timezone to 'Asia/Singapore'..."
timedatectl set-timezone Asia/Singapore
echo_success "Timezone set to 'Asia/Singapore'."

# 4) Add the new user and add to sudoers
if id "$NEW_USER" &>/dev/null; then
    echo_info "User $NEW_USER already exists. Skipping user creation."
else
    echo_info "Creating user $NEW_USER..."
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$USER_PASS" | chpasswd
    usermod -aG sudo "$NEW_USER"
    echo_success "User $NEW_USER created and added to sudoers."
fi

# 5) Disable root login in SSH config
echo_info "Disabling root login via SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin no" "$SSHD_CONFIG"; then
    echo_info "Root login is already disabled."
else
    sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"
    echo_success "Root login disabled in SSH configuration."
fi

# 6) Update and upgrade the system
echo_info "Updating package lists..."
apt-get update -y
echo_info "Upgrading installed packages..."
apt-get upgrade -y
echo_success "System update and upgrade completed."

# 7) Add backports if Debian 11 (Bullseye)
if [ -f /etc/debian_version ]; then
    DEBIAN_VERSION=$(lsb_release -sr)
    if [[ "$DEBIAN_VERSION" == "11"* ]]; then
        echo_info "Debian 11 detected. Adding backports to sources.list..."
        BACKPORTS_ENTRY1="deb http://deb.debian.org/debian bullseye-backports main contrib non-free"
        BACKPORTS_ENTRY2="deb-src http://deb.debian.org/debian bullseye-backports main contrib non-free"
        if grep -Fxq "$BACKPORTS_ENTRY1" /etc/apt/sources.list && grep -Fxq "$BACKPORTS_ENTRY2" /etc/apt/sources.list; then
            echo_info "Backports already added."
        else
            echo -e "\n$BACKPORTS_ENTRY1\n$BACKPORTS_ENTRY2" >> /etc/apt/sources.list
            echo_success "Backports added to sources.list."
            apt-get update -y
        fi
    else
        echo_info "Debian version is not 11. Skipping backports addition."
    fi
else
    echo_error "This script is intended for Debian-based systems."
    exit 1
fi

# 8) Install required packages
echo_info "Installing required packages: btop, curl, nano, nginx, certbot..."
apt-get install -y btop lsb_release curl nano nginx certbot python3-certbot-nginx
echo_success "Required packages installed."

# 9) Install Tailscaled
echo_info "Installing Tailscaled..."
curl -fsSL https://tailscale.com/install.sh | sh
echo_success "Tailscaled installed."

# 10) Enable and configure Tailscale as an exit node with SSH
echo_info "Enabling and configuring Tailscale as an exit node with SSH access..."
systemctl enable --now tailscaled

# Bring up Tailscale with exit node and SSH enabled
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo_info "Configuring Tailscale with provided Auth Key..."
    tailscale up --advertise-exit-node --accept-routes --ssh --authkey "$TAILSCALE_AUTHKEY" || {
        echo_error "Failed to authenticate with provided Tailscale Auth Key."
        echo_info "Attempting manual authentication..."
        tailscale up --advertise-exit-node --accept-routes --ssh
    }
else
    echo_info "No Tailscale Auth Key provided. Proceeding with manual authentication..."
    tailscale up --advertise-exit-node --accept-routes --ssh
fi
echo_success "Tailscale configured as an exit node with SSH access enabled."

# 11) Install Cloudflare Warp CLI
echo_info "Installing Cloudflare Warp CLI..."
# Add Cloudflare GPG key
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# Add Cloudflare Warp repository
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list

# Update and install Cloudflare Warp
apt-get update -y
apt-get install -y cloudflare-warp
echo_success "Cloudflare Warp CLI installed."

# 12) Register and configure Cloudflare Warp
echo_info "Registering Cloudflare Warp and setting it to proxy mode..."
warp-cli register
warp-cli set-mode proxy
warp-cli set-proxy-port 40001
warp-cli connect
warp-cli enable-always-on
echo_success "Cloudflare Warp configured and enabled."

# 13) Install Xray
echo_info "Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo_success "Xray installed."

# 14) Set up Xray configuration
echo_info "Setting up Xray configuration..."
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# Generate 5 UUIDs
echo_info "Generating 5 UUIDs for Xray clients..."
UUIDS=()
for i in {1..5}; do
    UUIDS+=("$(xray uuid)")
done

# Create Xray config with placeholders replaced
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
          {
            "id": "${UUIDS[0]}"
          },
          {
            "id": "${UUIDS[1]}"
          },
          {
            "id": "${UUIDS[2]}"
          },
          {
            "id": "${UUIDS[3]}"
          },
          {
            "id": "${UUIDS[4]}"
          }
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

echo_success "Xray configuration set."

# 15) Restart Nginx
echo_info "Restarting Nginx..."
systemctl restart nginx
echo_success "Nginx restarted."

# 16) Set up Nginx site
echo_info "Configuring Nginx site..."
NGINX_SITE="/etc/nginx/sites-available/$XRAY_DOMAIN"

cat > "$NGINX_SITE" <<EOF
server {
    server_name $XRAY_DOMAIN;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # vless xray
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

# 17) Enable the Nginx site and restart
echo_info "Enabling Nginx site and restarting Nginx..."
ln -s "$NGINX_SITE" /etc/nginx/sites-enabled/ || true
nginx -t && systemctl restart nginx
echo_success "Nginx site configured and restarted."

# 18) Obtain SSL certificate with Certbot
echo_info "Obtaining SSL certificate with Certbot..."
certbot --nginx -d "$XRAY_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
echo_success "SSL certificate obtained and configured."

# 19) Gather and display key details
echo_info "Gathering system and configuration details..."

PUBLIC_IPV4=$(curl -4 -s https://ifconfig.me)
PUBLIC_IPV6=$(curl -6 -s https://ifconfig.me || echo "IPv6 not available")

echo -e "\n===== Setup Summary ====="
echo "Hostname: $NEW_HOSTNAME"
echo "Public IPv4 Address: $PUBLIC_IPV4"
echo "Public IPv6 Address: $PUBLIC_IPV6"
echo "New Username: $NEW_USER"
echo "User Password: $USER_PASS"
echo "Xray VLESS Domain: $XRAY_DOMAIN"
echo "Xray VLESS Path: $XRAY_PATH"
echo "Let's Encrypt Contact Email: $LE_EMAIL"
echo "Tailscale Auth Key Provided: $( [ -n "$TAILSCALE_AUTHKEY" ] && echo "Yes" || echo "No")"
echo "Xray VLESS UUIDs:"
for i in {1..5}; do
    echo "  UUID $i: ${UUIDS[$((i-1))]}"
done
echo "========================"

# 20) Confirmation to restart SSHD
read -p "Do you want to restart SSH service now? (y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo_info "Restarting SSH service..."
    systemctl restart sshd
    echo_success "SSH service restarted."
else
    echo_info "SSH service restart skipped. Please restart it manually if needed."
fi

echo_success "Setup completed successfully!"

exit 0
