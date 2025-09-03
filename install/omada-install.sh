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

# Enhanced network connectivity check
msg_info "Verifying network connectivity"
for i in {1..10}; do
  if ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W5 1.1.1.1 >/dev/null 2>&1; then
    msg_ok "Network connectivity confirmed"
    break
  fi
  if [ $i -eq 10 ]; then
    msg_error "No network connectivity after 10 attempts"
    exit 1
  fi
  msg_info "Waiting for network connectivity (attempt $i/10)..."
  sleep 5
done

msg_info "Installing Dependencies"
$STD apt-get install -y curl
$STD apt-get install -y sudo
$STD apt-get install -y mc
$STD apt-get install -y gnupg2
$STD apt-get install -y jsvc
$STD apt-get install -y ca-certificates
msg_ok "Installed Dependencies"

msg_info "Installing Java"
$STD apt-get install -y openjdk-17-jre-headless
msg_ok "Installed OpenJDK 17 Java"

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

# Add MongoDB 4.4 repository with retry logic
mongodb_key_added=false
for i in {1..5}; do
  if curl -fsSL --connect-timeout 15 --retry 3 "https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc" | gpg --dearmor >/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg; then
    mongodb_key_added=true
    break
  fi
  msg_info "Retrying MongoDB key download (attempt $i/5)..."
  sleep 10
done

if [ "$mongodb_key_added" = false ]; then
  msg_error "Failed to download MongoDB GPG key after 5 attempts"
  exit 1
fi

# Use Ubuntu 20.04 (focal) repository for better Debian 12 compatibility
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg] http://repo.mongodb.org/apt/ubuntu focal/mongodb-org/${MONGODB_VERSION} multiverse" >/etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list

$STD apt-get update

# Install specific MongoDB 4.4 version with retry logic
mongodb_installed=false
for i in {1..3}; do
  if $STD apt-get install -y \
    mongodb-org=4.4.29 \
    mongodb-org-server=4.4.29 \
    mongodb-org-shell=4.4.29 \
    mongodb-org-mongos=4.4.29 \
    mongodb-org-tools=4.4.29; then
    mongodb_installed=true
    break
  fi
  msg_info "Retrying MongoDB installation (attempt $i/3)..."
  sleep 5
done

if [ "$mongodb_installed" = false ]; then
  msg_error "Failed to install MongoDB after 3 attempts"
  exit 1
fi

# Hold packages to prevent unwanted upgrades
$STD apt-mark hold mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools

$STD systemctl enable mongod
msg_ok "Installed MongoDB ${MONGODB_VERSION}"

msg_info "Installing libssl1.1 (required for Omada)"
libssl_installed=false
for i in {1..3}; do
  if wget --timeout=30 --tries=3 -c http://ftp.us.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb; then
    if $STD dpkg -i libssl1.1_1.1.1w-0+deb11u1_amd64.deb; then
      libssl_installed=true
      rm -f libssl1.1_1.1.1w-0+deb11u1_amd64.deb
      break
    fi
  fi
  msg_info "Retrying libssl1.1 download/install (attempt $i/3)..."
  sleep 5
done

if [ "$libssl_installed" = false ]; then
  msg_error "Failed to install libssl1.1 after 3 attempts"
  exit 1
fi
msg_ok "Installed libssl1.1"

msg_info "Installing Omada Controller"
# Try multiple patterns to find the latest Omada package with enhanced error handling
OMADA_URL=""
omada_url_found=false

for attempt in {1..3}; do
  # First try the standard pattern
  OMADA_URL=$(curl -fsSL --connect-timeout 15 --retry 2 "https://support.omadanetworks.com/en/download/software/omada-controller/" |
    grep -o 'https://static\.tp-link\.com/upload/software/[^"]*linux_x64[^"]*\.deb' |
    head -n1)

  # If that fails, try the newer omada pattern
  if [ -z "$OMADA_URL" ]; then
    OMADA_URL=$(curl -fsSL --connect-timeout 15 --retry 2 "https://support.omadanetworks.com/en/download/software/omada-controller/" |
      grep -o 'https://static\.tp-link\.com/upload/software/[^"]*omada[^"]*linux_x64[^"]*\.deb' |
      head -n1)
  fi

  # If still no URL, try a broader pattern
  if [ -z "$OMADA_URL" ]; then
    OMADA_URL=$(curl -fsSL --connect-timeout 15 --retry 2 "https://support.omadanetworks.com/en/download/software/omada-controller/" |
      grep -o 'https://static\.tp-link\.com/[^"]*\.deb' |
      grep -i linux |
      grep -i x64 |
      head -n1)
  fi

  if [ -n "$OMADA_URL" ]; then
    omada_url_found=true
    break
  fi
  
  msg_info "Retrying Omada URL detection (attempt $attempt/3)..."
  sleep 10
done

if [ "$omada_url_found" = false ]; then
  msg_error "Could not retrieve Omada package URL after 3 attempts"
  exit 1
fi

OMADA_PKG=$(basename "$OMADA_URL")
if [ -z "$OMADA_PKG" ]; then
  msg_error "Invalid Omada package name"
  exit 1
fi

# Download Omada package with retry logic
omada_downloaded=false
for i in {1..3}; do
  if wget --timeout=60 --tries=3 -q "$OMADA_URL"; then
    omada_downloaded=true
    break
  fi
  msg_info "Retrying Omada download (attempt $i/3)..."
  sleep 10
done

if [ "$omada_downloaded" = false ]; then
  msg_error "Failed to download Omada package after 3 attempts"
  exit 1
fi

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
