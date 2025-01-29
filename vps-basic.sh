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

# 6) Add backports if Debian 11 (Bullseye) or Debian 12 (Bookworm)
DEBIAN_VERSION=$(get_debian_version)

if [[ "$DEBIAN_VERSION" == "11"* ]]; then
    echo_info "Debian 11 detected. Adding Bullseye backports to sources.list..."
    BACKPORTS_ENTRY1="deb http://deb.debian.org/debian bullseye-backports main contrib non-free"
    BACKPORTS_ENTRY2="deb-src http://deb.debian.org/debian bullseye-backports main contrib non-free"
elif [[ "$DEBIAN_VERSION" == "12"* ]]; then
    echo_info "Debian 12 detected. Adding Bookworm backports to sources.list..."
    BACKPORTS_ENTRY1="deb http://deb.debian.org/debian bookworm-backports main contrib non-free"
    BACKPORTS_ENTRY2="deb-src http://deb.debian.org/debian bookworm-backports main contrib non-free"
else
    echo_info "Debian version is not 11 or 12. Skipping backports addition."
    BACKPORTS_ENTRY1=""
    BACKPORTS_ENTRY2=""
fi

if [[ -n "$BACKPORTS_ENTRY1" && -n "$BACKPORTS_ENTRY2" ]]; then
    if grep -Fxq "$BACKPORTS_ENTRY1" /etc/apt/sources.list && grep -Fxq "$BACKPORTS_ENTRY2" /etc/apt/sources.list; then
        echo_info "Backports already added."
    else
        echo -e "\n$BACKPORTS_ENTRY1\n$BACKPORTS_ENTRY2" >> /etc/apt/sources.list
        echo_success "Backports added to sources.list."
        apt-get update -y
    fi
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

# 12) Enable and configure Tailscale
echo_info "Enabling and configuring Tailscale..."

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

# 13) Install and configure UFW
echo_info "Installing and configuring UFW (Uncomplicated Firewall)..."
apt-get install -y ufw
echo_success "UFW installed."

# Set default UFW policies
echo_info "Setting default UFW policies..."
ufw default deny incoming
ufw default allow outgoing
echo_success "Default UFW policies set (Incoming: Deny, Outgoing: Allow)."

# Allow SSH
echo_info "Allowing SSH (port 22)..."
ufw allow ssh
echo_success "SSH allowed."

# Allow HTTP and HTTPS
echo_info "Allowing HTTP (port 80) and HTTPS (port 443)..."
ufw allow http
ufw allow https
echo_success "HTTP and HTTPS allowed."

# Allow all Tailscale traffic
echo_info "Allowing all traffic on Tailscale interface 'tailscale0'..."
ufw allow in on tailscale0
echo_success "All Tailscale traffic allowed."

# Enable UFW
echo_info "Enabling UFW..."
echo "y" | ufw enable
echo_success "UFW enabled and configured."

# === FAIL2BAN SECTION START ===
# 14) Install and configure Fail2Ban
echo_info "Installing Fail2Ban..."
apt-get install -y fail2ban
echo_success "Fail2Ban installed."

echo_info "Configuring Fail2Ban for SSH protection..."
# Create a local jail configuration to override default settings
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Ban IP for 10 minutes after 5 failed attempts
bantime = 600
findtime = 600
maxretry = 5
backend = auto

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

echo_success "Fail2Ban configuration file created at /etc/fail2ban/jail.local."

# Restart and enable Fail2Ban service
echo_info "Enabling and starting Fail2Ban service..."
systemctl enable fail2ban
systemctl restart fail2ban
echo_success "Fail2Ban service enabled and started."

# Optional: Provide status of Fail2Ban
echo_info "Checking Fail2Ban status..."
fail2ban-client status sshd
# === FAIL2BAN SECTION END ===

# 15) Gather and display key details
echo_info "Gathering system and configuration details..."

PUBLIC_IPV4=$(curl -4 -s https://ifconfig.me)
PUBLIC_IPV6=$(curl -6 -s https://ifconfig.me || echo "IPv6 not available")

echo -e "\n===== Setup Summary ====="
echo "Hostname: $NEW_HOSTNAME"
echo "Public IPv4 Address: $PUBLIC_IPV4"
echo "Public IPv6 Address: $PUBLIC_IPV6"
echo "New Username: $NEW_USER"
echo "User Password: $USER_PASS"
echo "Tailscale Auth Key Provided: $( [ -n "$TAILSCALE_AUTHKEY" ] && echo "Yes" || echo "No")"
echo "UFW: Enabled (Allowing OpenSSH, HTTP, HTTPS, and all Tailscale traffic)"
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

# 16) Confirmation to restart SSHD
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
