# VPS Setup Scripts

This repository contains two Bash scripts for setting up a Virtual Private Server (VPS) with essential configurations and services:

- **vps-basic.sh**: A script to configure a Debian-based VPS with essential settings, security, and network configurations.
- **vps-vless.sh**: A script that builds upon `vps-basic.sh` by setting up an Xray VLESS server with Nginx and Cloudflare Warp.

## Prerequisites

- A Debian-based VPS (Debian 11 or later recommended).
- Root access.
- A registered domain (for `vps-vless.sh`).
- A valid Tailscale authentication key (optional).

## Features

### `vps-basic.sh`

- Sets a custom hostname.
- Creates a new user and adds it to the sudo group.
- Configures system timezone to `Asia/Singapore`.
- Enables IP forwarding (for Tailscale).
- Updates and upgrades system packages.
- Installs essential packages (`sudo`, `btop`, `curl`, `nano`, `nginx`, `certbot`).
- Disables root SSH login.
- Installs and configures Tailscale.
- Sets up Uncomplicated Firewall (UFW) with default rules.
- Installs Fail2Ban for SSH protection.
- Optionally sets up a health check service.

### `vps-vless.sh`

Includes everything from `vps-basic.sh` and adds:

- Installs Cloudflare Warp for encrypted traffic.
- Installs and configures Xray VLESS with WebSocket transport.
- Sets up Nginx as a reverse proxy for Xray VLESS.
- Configures Let's Encrypt SSL certificates with automatic renewal.
- Enables HTTP/2 in Nginx.
- Provides 5 unique UUIDs for VLESS clients.

## Installation and Usage

### Running `vps-basic.sh`

```bash
wget https://raw.githubusercontent.com/jinnotgin/vps-setup/refs/heads/main/vps-vless.sh
chmod +x vps-basic.sh
sudo ./vps-basic.sh
```

### Running `vps-vless.sh`

```bash
wget https://raw.githubusercontent.com/jinnotgin/vps-setup/refs/heads/main/vps-vless.sh
chmod +x vps-vless.sh
sudo ./vps-vless.sh
```

## User Inputs

The scripts prompt for:

- Hostname
- New user credentials
- Tailscale authentication key (optional)
- Xray domain and path (for `vps-vless.sh`)
- Let's Encrypt email (for `vps-vless.sh`)
- Health check service (optional)

## Post-Installation

- Verify services:
  ```bash
  systemctl status nginx tailscaled fail2ban ufw
  ```
- Check Tailscale status:
  ```bash
  tailscale status
  ```
- Restart services if needed:
  ```bash
  sudo systemctl restart nginx xray
  ```

## License

MIT License

## Disclaimer

Use these scripts at your own risk. Ensure you understand the configurations before running them on production servers.

