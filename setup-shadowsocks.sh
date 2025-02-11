#!/bin/bash
# setup_shadowsocks_multi.sh
#
# This script installs and configures Shadowsocks-libev on a Debian-like system.
# It gathers configuration details from the user up front, supports setting up
# multiple server instances (each with its own port and a generated password),
# and automatically adds UFW firewall rules if UFW is installed.
#
# The default encryption method is set to chacha20-ietf-poly1305.
#
# A debugging trap is included to print errors when a command fails.
#
# If a systemd template for multiple instances (shadowsocks-libev@.service) is not found,
# the script will create a basic one.
#
# Usage:
#   sudo ./setup_shadowsocks_multi.sh
#
# Author: [Your Name]
# Date: [Today's Date]

# Exit immediately if a command exits with a non-zero status.
# Also treat unset variables as an error and propagate errors in pipelines.
set -euo pipefail

# Debugging trap: when an error occurs, print the line number, the command, and the exit code.
trap 'echo "Error on line ${LINENO}: command \"${BASH_COMMAND}\" exited with code $?"' ERR

echo "###############################"
echo "Shadowsocks-libev Multi-Instance Setup"
echo "###############################"
echo ""

# ==========================
# Gather User Input Up Front
# ==========================

# Global configuration: the IP address to bind on.
read -rp "Enter server IP to bind (default: 0.0.0.0): " server_ip
server_ip=${server_ip:-0.0.0.0}

# How many Shadowsocks instances to set up?
read -rp "How many Shadowsocks instances do you want to set up? (default: 1): " instance_count
instance_count=${instance_count:-1}

# Detect if UFW is installed.
if command -v ufw >/dev/null 2>&1; then
    ufw_installed=true
    echo "UFW detected: firewall rules will be added automatically."
else
    ufw_installed=false
    echo "UFW not detected."
fi

echo ""
echo "Now, please provide details for each instance."
echo "---------------------------------------------"

# Prepare arrays to store instance-specific configuration.
declare -a instance_names
declare -a instance_ports
declare -a instance_passwords
declare -a instance_methods
declare -a instance_timeouts
declare -a instance_fastopens

# Default starting port.
default_port=8388

# Function to generate a random alphanumeric password of 16 characters.
generate_password() {
    # Using "|| true" to ignore the SIGPIPE error when head exits early.
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true
}

# Loop to gather details for each instance.
for (( i = 1; i <= instance_count; i++ )); do
    echo ""
    echo "### Configuring instance $i of $instance_count ###"
    
    # Instance name.
    read -rp "Enter instance name (default: ss${i}): " instance_name
    instance_name=${instance_name:-ss${i}}
    instance_names+=("$instance_name")
    
    # Server port.
    read -rp "Enter server port for instance '$instance_name' (default: ${default_port}): " port_input
    if [[ -z $port_input ]]; then
        port=$default_port
    else
        port=$port_input
    fi
    instance_ports+=("$port")
    
    # Update the default port for the next instance.
    default_port=$((port + 1))
    
    # Generate a secure random password (alphanumeric).
    password=$(generate_password)
    echo "Generated password for instance '$instance_name': $password"
    instance_passwords+=("$password")
    
    # Encryption method (default: chacha20-ietf-poly1305).
    read -rp "Enter encryption method (default: chacha20-ietf-poly1305): " method
    method=${method:-chacha20-ietf-poly1305}
    instance_methods+=("$method")
    
    # Timeout (in seconds; default: 60).
    read -rp "Enter timeout in seconds (default: 60): " timeout
    timeout=${timeout:-60}
    instance_timeouts+=("$timeout")
    
    # TCP Fast Open option.
    read -rp "Enable TCP Fast Open for instance '$instance_name'? [y/N]: " fast_open_input
    if [[ $fast_open_input =~ ^[Yy] ]]; then
        fast_open=true
    else
        fast_open=false
    fi
    instance_fastopens+=("$fast_open")
done

# ===============================
# Begin Installation & Configuration
# ===============================

echo ""
echo "Updating package lists..."
apt update

echo "Installing shadowsocks-libev..."
apt install -y shadowsocks-libev

# Check for the systemd template unit file for multi-instance usage.
echo "Checking for shadowsocks-libev systemd template..."
if [ ! -f /lib/systemd/system/shadowsocks-libev@.service ] && [ ! -f /etc/systemd/system/shadowsocks-libev@.service ]; then
    echo "Systemd template not found. Creating /etc/systemd/system/shadowsocks-libev@.service..."
    cat << 'EOF' > /etc/systemd/system/shadowsocks-libev@.service
[Unit]
Description=Shadowsocks-libev custom instance %I
After=network.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/%i.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

# Loop over each instance and configure it.
echo ""
echo "Configuring Shadowsocks-libev instances..."
declare -a instance_summaries

for (( i = 0; i < instance_count; i++ )); do
    inst_name="${instance_names[i]}"
    port="${instance_ports[i]}"
    password="${instance_passwords[i]}"
    method="${instance_methods[i]}"
    timeout="${instance_timeouts[i]}"
    fast_open="${instance_fastopens[i]}"

    # Define the configuration file path.
    config_file="/etc/shadowsocks-libev/${inst_name}.json"

    echo ""
    echo "Writing configuration for instance '$inst_name' to ${config_file}..."
    cat > "$config_file" <<EOF
{
    "server": "$server_ip",
    "server_port": $port,
    "password": "$password",
    "timeout": $timeout,
    "method": "$method",
    "fast_open": $fast_open,
    "mode": "tcp_and_udp"
}
EOF

    echo "Configuration for instance '$inst_name' written."

    # Enable and start the instance using the systemd template.
    echo "Enabling and starting Shadowsocks-libev instance '$inst_name'..."
    systemctl enable shadowsocks-libev@"$inst_name"
    systemctl restart shadowsocks-libev@"$inst_name"

    # If UFW is installed, open the port for both TCP and UDP.
    if $ufw_installed; then
        echo "Adding UFW rules for port $port..."
        ufw allow "$port"/tcp
        ufw allow "$port"/udp
    fi

    # Append instance summary.
    instance_summaries+=("Instance '$inst_name': IP=$server_ip, Port=$port, Password=$password, Encryption=$method, Timeout=$timeout, TCP Fast Open=$fast_open")
done

echo ""
echo "###############################"
echo "Setup Complete"
echo "The following Shadowsocks-libev instances have been configured and started:"
echo "-----------------------------------------------------"
for summary in "${instance_summaries[@]}"; do
    echo "$summary"
done
echo "-----------------------------------------------------"
if $ufw_installed; then
    echo "UFW rules have been added for the respective ports."
fi
echo "Enjoy your secure proxy!"
