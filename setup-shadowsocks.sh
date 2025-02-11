#!/bin/bash
# setup_shadowsocks_multi.sh
#
# This script installs and configures Shadowsocks-libev on a Debian-like system.
# It supports creating multiple server instances (each with its own password, port, etc.)
# by using the systemd instance template (shadowsocks-libev@.service).
#
# The default encryption method is set to chacha20-ietf-poly1305.
#
# Usage:
#   sudo ./setup_shadowsocks_multi.sh
#
# Author: [Your Name]
# Date: [Today's Date]

set -euo pipefail

# Check if the script is run as root.
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (or via sudo)." >&2
  exit 1
fi

# Update package lists and install Shadowsocks-libev.
echo "Updating package lists..."
apt update

echo "Installing Shadowsocks-libev..."
apt install -y shadowsocks-libev

echo ""
echo "### Shadowsocks-libev Multi-Instance Setup ###"
echo ""

# Ask for the server IP to bind on. (0.0.0.0 means all interfaces)
read -rp "Enter server IP to bind (default 0.0.0.0): " server_ip
server_ip=${server_ip:-0.0.0.0}

# Ask how many instances to set up.
read -rp "How many Shadowsocks instances do you want to set up? (default 1): " instance_count
instance_count=${instance_count:-1}

# Prepare to store instance summaries.
declare -a instance_summaries

# Use a default port for the first instance; subsequent instances will default to the next port number.
default_port=8388

# Loop through the number of instances.
for (( i = 1; i <= instance_count; i++ )); do
  echo ""
  echo "Configuring instance $i of $instance_count..."
  
  # Ask for an instance name (will be used as the name of the JSON file and systemd instance).
  read -rp "Enter instance name (default: ss${i}): " instance_name
  instance_name=${instance_name:-ss${i}}

  # Ask for the server port; default is the current default_port.
  read -rp "Enter server port for instance '$instance_name' (default: ${default_port}): " port_input
  if [[ -z $port_input ]]; then
    port=$default_port
  else
    port=$port_input
  fi
  # Update default_port for the next instance (suggest next higher port).
  default_port=$((port + 1))

  # Ask for the password (cannot be empty).
  read -rp "Enter password for instance '$instance_name': " password
  if [[ -z $password ]]; then
    echo "Error: Password cannot be empty."
    exit 1
  fi

  # Ask for the encryption method; default to chacha20-ietf-poly1305.
  read -rp "Enter encryption method (default: chacha20-ietf-poly1305): " method
  method=${method:-chacha20-ietf-poly1305}

  # Ask for the timeout (in seconds); default to 60.
  read -rp "Enter timeout in seconds (default: 60): " timeout
  timeout=${timeout:-60}

  # Ask whether to enable TCP Fast Open.
  read -rp "Enable TCP Fast Open for instance '$instance_name'? [y/N]: " fast_open_input
  if [[ $fast_open_input =~ ^[Yy] ]]; then
    fast_open=true
  else
    fast_open=false
  fi

  # Define the configuration file path.
  config_file="/etc/shadowsocks-libev/${instance_name}.json"

  echo ""
  echo "Writing configuration for instance '$instance_name' to ${config_file}..."
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

  echo "Configuration for instance '$instance_name' written."

  # Enable and start the instance using the systemd template.
  echo "Enabling and starting Shadowsocks-libev instance '$instance_name'..."
  systemctl enable shadowsocks-libev@"$instance_name"
  systemctl restart shadowsocks-libev@"$instance_name"

  # Add the instance details to the summary.
  instance_summaries+=("Instance '$instance_name': IP=$server_ip, Port=$port, Password=$password, Encryption=$method, Timeout=$timeout, TCP Fast Open=$fast_open")
done

echo ""
echo "### Setup Complete ###"
echo "The following Shadowsocks-libev instances have been configured and started:"
echo "-----------------------------------------------------"
for summary in "${instance_summaries[@]}"; do
  echo "$summary"
done
echo "-----------------------------------------------------"
echo "Enjoy your secure proxy!"
