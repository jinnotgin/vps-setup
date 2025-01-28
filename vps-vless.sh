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
    echo_error "Please run this script as root."
    exit 1
fi

# Function to get Debian version
get_debian_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        cat /etc/debian_version
    else
        echo_error "Cannot determine Debian version."
        exit 1
    fi
}

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

# 4) Enable IP Forwarding
echo_info "Configuring IP forwarding..."

SYSCTL_CONF_DIR="/etc/sysctl.d"
SYSCTL_FILE="99-tailscale.conf"

if [ -d "$SYSCTL_CONF_DIR" ]; then
    echo_info "Using /etc/sysctl.d/$SYSCTL_FILE for IP forwarding settings."
    {
        echo 'net.ipv4.ip_forward = 1'
        echo 'net.ipv6.conf.all.forwarding = 1'
    } | tee -a "$SYSCTL_CONF_DIR/$SYSCTL_FILE"
    SYSCTL_PATH="$SYSCTL_CONF_DIR/$SYSCTL_FILE"
else
    echo_info "Using /etc/sysctl.conf for IP forwarding settings."
    {
        echo 'net.ipv4.ip_forward = 1'
        echo 'net.ipv6.conf.all.forwarding = 1'
    } | tee -a /etc/sysctl.conf
    SYSCTL_PATH="/etc/sysctl.conf"
fi

echo_info "Applying IP forwarding settings from $SYSCTL_PATH..."
sysctl -p "$SYSCTL_PATH"
echo_success "IP forwarding configured."

# 5) Update and upgrade the system first
echo_info "Updating package lists..."
apt-get update -y
echo_info "Upgrading installed packages..."
apt-get upgrade -y
echo_success "System update and upgrade completed."

# 6) Add backports if Debian 11 (Bullseye)
DEBIAN_VERSION=$(get_debian_version)
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

# 7) Install required packages early
echo_info "Installing required packages: sudo, btop, curl, nano, nginx, certbot..."
apt-get install -y sudo btop curl nano nginx certbot python3-certbot-nginx
echo_success "Required packages installed."

# 8) Add the new user and add to sudoers
if id "$NEW_USER" &>/dev/null; then
    echo_info "User '$NEW_USER' already exists. Skipping user creation."
else
    echo_info "Creating user '$NEW_USER'..."
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$USER_PASS" | chpasswd
    usermod -aG sudo "$NEW_USER"
    echo_success "User '$NEW_USER' created and added to sudoers."
fi

# 9) Disable root login in SSH config
echo_info "Disabling root login via SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin no" "$SSHD_CONFIG"; then
    echo_info "Root login is already disabled."
else
    sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"
    echo_success "Root login disabled in SSH configuration."
fi

# 10) Ensure gnupg is installed to prevent 'gpg: command not found' error
echo_info "Ensuring 'gnupg' is installed to prevent 'gpg: command not found' errors..."
if ! command -v gpg &> /dev/null; then
    echo_info "'gpg' not found. Installing 'gnupg2'..."
    apt-get install -y gnupg2
    echo_success "'gnupg2' installed."
else
    echo_info "'gpg' is already installed."
fi

# 11) Install Tailscaled
echo_info "Installing Tailscaled..."
curl -fsSL https://tailscale.com/install.sh | sh
echo_success "Tailscaled installed."

# 12) Enable and configure Tailscale as an exit node with SSH
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

# 13) Install Cloudflare Warp CLI
echo_info "Installing Cloudflare Warp CLI..."
# Add Cloudflare GPG key
echo_info "Adding Cloudflare Warp GPG key..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo_success "Cloudflare Warp GPG key added."

# Add Cloudflare Warp repository
DEBIAN_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
echo_info "Adding Cloudflare Warp repository for Debian codename '$DEBIAN_CODENAME'..."
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $DEBIAN_CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list
echo_success "Cloudflare Warp repository added."

# Update and install Cloudflare Warp
echo_info "Updating package lists and installing Cloudflare Warp CLI..."
apt-get update -y
apt-get install -y cloudflare-warp
echo_success "Cloudflare Warp CLI installed."

# 14) Register and configure Cloudflare Warp
echo_info "Registering Cloudflare Warp and setting it to proxy mode..."
warp-cli registration new
warp-cli mode proxy
warp-cli proxy port 40001
warp-cli connect
echo_success "Cloudflare Warp configured and enabled."

# 15) Install Xray
echo_info "Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
echo_success "Xray installed."

# 16) Set up Xray configuration
echo_info "Setting up Xray configuration..."
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# Generate 5 UUIDs
echo_info "Generating 5 UUIDs for Xray clients..."
UUIDS=()
for i in {1..5}; do
    UUIDS+=("$(xray uuid)")
done

# Create Xray config with placeholders replaced
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

# 17) Restart Nginx
echo_info "Restarting Nginx..."
systemctl restart nginx
echo_success "Nginx restarted."

# 18) Set up Nginx site
echo_info "Configuring Nginx site for domain '$XRAY_DOMAIN'..."
NGINX_SITE="/etc/nginx/sites-available/$XRAY_DOMAIN"

cat > "$NGINX_SITE" <<EOF
server {
    server_name $XRAY_DOMAIN;
    listen 80;
    listen [::]:80;
    
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

echo_success "Nginx site configuration file created."

# 19) Enable the Nginx site and restart
echo_info "Enabling Nginx site and restarting Nginx..."
ln -s "$NGINX_SITE" /etc/nginx/sites-enabled/ || echo_info "Nginx site is already enabled."
nginx -t && systemctl restart nginx
echo_success "Nginx site enabled and restarted."

# 20) Obtain SSL certificate with Certbot
echo_info "Obtaining SSL certificate with Certbot for domain '$XRAY_DOMAIN'..."
certbot --nginx -d "$XRAY_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
echo_success "SSL certificate obtained and configured."

# === Begin Modifications After Certbot ===
echo_info "Modifying Nginx configuration for HTTP/2 support..."

NGINX_SITE="/etc/nginx/sites-available/$XRAY_DOMAIN"

# Replace 'listen 443 ssl; # managed by Certbot' with 'listen 443 ssl http2; # managed by Certbot'
sed -i 's/listen 443 ssl; # managed by Certbot/listen 443 ssl http2; # managed by Certbot/' "$NGINX_SITE"

# Check if 'listen [::]:443 ssl http2;' exists
if grep -q "listen \[::\]:443 ssl http2;" "$NGINX_SITE"; then
    echo_info "'listen [::]:443 ssl http2;' already exists in Nginx configuration."
else
    # Check if 'listen [::]:443 ssl;' exists
    if grep -q "listen \[::\]:443 ssl;" "$NGINX_SITE"; then
        echo_info "'listen [::]:443 ssl;' found. Adding 'http2' to it."
        # Replace 'listen [::]:443 ssl;' with 'listen [::]:443 ssl http2;'
        sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' "$NGINX_SITE"
        echo_success "'listen [::]:443 ssl http2;' added to existing 'listen [::]:443 ssl;' directive."
    else
        echo_info "'listen [::]:443 ssl http2;' and 'listen [::]:443 ssl;' not found. Adding 'listen [::]:443 ssl http2;' after 'listen 443 ssl http2; # managed by Certbot'."
        # Insert 'listen [::]:443 ssl http2;' after 'listen 443 ssl http2; # managed by Certbot'
        sed -i '/listen 443 ssl http2; # managed by Certbot/a \    listen [::]:443 ssl http2;' "$NGINX_SITE"
        echo_success "'listen [::]:443 ssl http2;' added to Nginx configuration."
    fi
fi

# Test Nginx configuration and reload
echo_info "Testing Nginx configuration..."
nginx -t

echo_info "Reloading Nginx to apply changes..."
systemctl reload nginx
echo_success "Nginx configuration updated for HTTP/2 support."
# === End Modifications After Certbot ===

# 21) Gather and display key details
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

# === Begin: Add Healthcheck Functionality ===
echo_info "Would you like to add a healthcheck? This will set up a healthcheck script and service in the user's home directory."

read -p "Do you want to add a healthcheck? (y/n): " ADD_HEALTHCHECK

if [[ "$ADD_HEALTHCHECK" =~ ^[Yy]$ ]]; then
    read -p "Enter the Healthcheck ID: " HEALTHCHECK_ID

    # Define user home directory
    USER_HOME=$(eval echo "~$NEW_USER")

    # Create healthcheck directory
    HEALTHCHECK_DIR="$USER_HOME/healthcheck"
    echo_info "Creating healthcheck directory at '$HEALTHCHECK_DIR'..."
    mkdir -p "$HEALTHCHECK_DIR"
    chown "$NEW_USER":"$NEW_USER" "$HEALTHCHECK_DIR"
    echo_success "Healthcheck directory created and owned by '$NEW_USER'."

    # Create healthcheck.sh
    HEALTHCHECK_SCRIPT="$HEALTHCHECK_DIR/healthcheck.sh"
    echo_info "Creating healthcheck script at '$HEALTHCHECK_SCRIPT'..."
    cat > "$HEALTHCHECK_SCRIPT" <<EOF
#!/bin/bash

healthcheck_url="https://hc-ping.com/$HEALTHCHECK_ID"
ping_interval=1200  # Ping interval in seconds (20 minutes)

while true; do
    response=\$(curl -s -o /dev/null -w "%{http_code}" "\$healthcheck_url")
    
    if [ "\$response" -eq 200 ]; then
        echo "Healthcheck succeeded for \$healthcheck_url"
    else
        echo "Healthcheck failed for \$healthcheck_url. Status code: \$response"
    fi
    
    sleep "\$ping_interval"
done
EOF
    chown "$NEW_USER":"$NEW_USER" "$HEALTHCHECK_SCRIPT"
    chmod +x "$HEALTHCHECK_SCRIPT"
    echo_success "Healthcheck script created, owned by '$NEW_USER', and made executable."

    # Create systemd service
    SERVICE_FILE="/etc/systemd/system/healthcheck_pinger.service"
    echo_info "Creating systemd service file at '$SERVICE_FILE'..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Healthcheck Pinger
After=network.target

[Service]
ExecStart=$HEALTHCHECK_SCRIPT
User=$NEW_USER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    echo_success "Systemd service file created."

    # Reload systemd daemon to recognize new service
    echo_info "Reloading systemd daemon..."
    systemctl daemon-reload

    # Enable and start the healthcheck service
    echo_info "Enabling and starting the healthcheck_pinger.service..."
    systemctl enable healthcheck_pinger.service
    systemctl start healthcheck_pinger.service
    echo_success "Healthcheck service enabled and started."
else
    echo_info "Healthcheck setup skipped."
fi
# === End: Add Healthcheck Functionality ===

# 22) Confirmation to restart SSHD
read -p "Do you want to restart the SSH service now? (y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo_info "Restarting SSH service..."
    systemctl restart sshd
    echo_success "SSH service restarted."
else
    echo_info "SSH service restart skipped. Please restart it manually if needed."
fi

echo_success "Setup completed successfully!"

exit 0
