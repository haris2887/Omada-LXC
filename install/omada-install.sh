#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: tteck
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.tp-link.com/us/support/download/omada-software-controller/
# Modified to support non-AVX systems by using MongoDB 4.4

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y curl
$STD apt-get install -y sudo
$STD apt-get install -y mc
$STD apt-get install -y gnupg2
$STD apt-get install -y jsvc
msg_ok "Installed Dependencies"

msg_info "Installing Azul Zulu Java"
wget -qO /tmp/zulu-repo-keyring.gpg http://repos.azulsystems.com/zulu-repo.key
$STD apt-key add /tmp/zulu-repo-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/zulu-repo.gpg] https://repos.azulsystems.com/zulu/deb/ stable main" >/etc/apt/sources.list.d/zulu.list
gpg --dearmor -o /usr/share/keyrings/zulu-repo.gpg < /tmp/zulu-repo-keyring.gpg
$STD apt-get update
$STD apt-get install -y zulu21-jre-headless
msg_ok "Installed Azul Zulu Java"

msg_info "Installing MongoDB 4.4 (Non-AVX Compatible)"
# Force MongoDB 4.4 for all systems to ensure compatibility
MONGODB_VERSION="4.4"

if ! lscpu | grep -q 'avx'; then
  msg_info "No AVX detected: Installing MongoDB 4.4 (compatible with non-AVX systems)"
else
  msg_info "AVX detected but using MongoDB 4.4 for better compatibility"
fi

# Remove any existing MongoDB packages
$STD apt-get remove --purge -y mongodb-org mongodb-org-* mongodb 2>/dev/null || true
$STD rm /etc/apt/sources.list.d/mongodb-org-*.list 2>/dev/null || true

# Add MongoDB 4.4 repository
curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc" | gpg --dearmor >/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg

# Use Ubuntu 20.04 (focal) repository for better Debian 12 compatibility
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg] http://repo.mongodb.org/apt/ubuntu focal/mongodb-org/${MONGODB_VERSION} multiverse" >/etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list

$STD apt-get update

# Install specific MongoDB 4.4 version
$STD apt-get install -y \
  mongodb-org=4.4.29 \
  mongodb-org-server=4.4.29 \
  mongodb-org-shell=4.4.29 \
  mongodb-org-mongos=4.4.29 \
  mongodb-org-tools=4.4.29

# Hold packages to prevent unwanted upgrades
$STD apt-mark hold mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools

$STD systemctl enable mongod
msg_ok "Installed MongoDB ${MONGODB_VERSION}"

msg_info "Installing libssl1.1 (required for Omada)"
wget -c http://ftp.us.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb
$STD dpkg -i libssl1.1_1.1.1w-0+deb11u1_amd64.deb
rm -f libssl1.1_1.1.1w-0+deb11u1_amd64.deb
msg_ok "Installed libssl1.1"

msg_info "Installing Omada Controller"
# Try multiple patterns to find the latest Omada package
OMADA_URL=""

# First try the standard pattern
OMADA_URL=$(curl -fsSL "https://support.omadanetworks.com/en/download/software/omada-controller/" |
  grep -o 'https://static\.tp-link\.com/upload/software/[^"]*linux_x64[^"]*\.deb' |
  head -n1)

# If that fails, try the newer omada pattern
if [ -z "$OMADA_URL" ]; then
  OMADA_URL=$(curl -fsSL "https://support.omadanetworks.com/en/download/software/omada-controller/" |
    grep -o 'https://static\.tp-link\.com/upload/software/[^"]*omada[^"]*linux_x64[^"]*\.deb' |
    head -n1)
fi

# If still no URL, try a broader pattern
if [ -z "$OMADA_URL" ]; then
  OMADA_URL=$(curl -fsSL "https://support.omadanetworks.com/en/download/software/omada-controller/" |
    grep -o 'https://static\.tp-link\.com/[^"]*\.deb' |
    grep -i linux |
    grep -i x64 |
    head -n1)
fi

OMADA_PKG=$(basename "$OMADA_URL")
if [ -z "$OMADA_PKG" ]; then
  msg_error "Could not retrieve Omada package – server may be down."
  exit 1
fi

wget -q "$OMADA_URL"
export DEBIAN_FRONTEND=noninteractive
$STD dpkg -i "$OMADA_PKG"
rm -f "$OMADA_PKG"
msg_ok "Installed Omada Controller"

msg_info "Starting Services"
$STD systemctl start mongod
sleep 5
$STD systemctl enable tpeap
$STD systemctl start tpeap
msg_ok "Started Services"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get autoremove -y
$STD apt-get autoclean
msg_ok "Cleaned"
