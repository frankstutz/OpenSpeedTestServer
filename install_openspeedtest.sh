#!/bin/sh
# OpenSpeedTest Installer for NGINX on GL.iNet Routers
# Author: frankstutz
# Original Author: phantasm22
# Forked from: https://github.com/phantasm22/OpenSpeedTestServer
# License: GPL-3.0
# Version: 2025-12-23
#
# This script installs or uninstalls the OpenSpeedTest server using NGINX on OpenWRT-based routers.
# It supports:
# - Installing NGINX and OpenSpeedTest
# - Creating a custom config and startup script
# - Running diagnostics to check if NGINX is active
# - Uninstalling everything cleanly
# - Automatically checks and updates itself
# - Optimized for low-resource embedded devices
# - Aggressive log rotation (errors only)
# - procd service management support

# Usage:
#   DEBUG=1 ./install_openspeedtest.sh        # Enable debug output
#   VERBOSE=1 ./install_openspeedtest.sh      # Enable verbose output
#   PORT=9999 ./install_openspeedtest.sh      # Use custom port

# -----------------------------
# Color & Emoji
# -----------------------------
RESET="\033[0m"
CYAN="\033[36m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"

SPLASH="
   _____ _          _ _   _      _   
  / ____| |        (_) \\ | |    | |  
 | |  __| |  ______ _|  \\| | ___| |_ 
 | | |_ | | |______| | . \` |/ _ \\ __|
 | |__| | |____    | | |\\  |  __/ |_ 
  \\_____|______|   |_|_| \\_|\\___|\\__|

         OpenSpeedTest for GL-iNet
"

# -----------------------------
# Debug Mode
# -----------------------------
DEBUG=${DEBUG:-0}
VERBOSE=${VERBOSE:-0}

# -----------------------------
# Global Variables
# -----------------------------
INSTALL_DIR="/www2"
CONFIG_PATH="/etc/nginx/nginx_openspeedtest.conf"
CONFIG_BACKUP="/etc/nginx/nginx_openspeedtest.conf.backup"
STARTUP_SCRIPT="/etc/init.d/nginx_speedtest"
LOGROTATE_SCRIPT="/etc/cron.daily/nginx_openspeedtest_logrotate"
ERROR_LOG="/var/log/nginx_openspeedtest_error.log"
REQUIRED_SPACE_MB=64
PORT=${PORT:-8888}
PID_FILE="/var/run/nginx_OpenSpeedTest.pid"
LOCK_FILE="/var/run/openspeedtest_install.lock"
BLA_BOX="┤ ┴ ├ ┬" # spinner frames
opkg_updated=0
SCRIPT_URL="https://raw.githubusercontent.com/frankstutz/OpenSpeedTestServer/refs/heads/main/install_openspeedtest.sh"
TMP_NEW_SCRIPT="/tmp/install_openspeedtest_new.sh"
SCRIPT_PATH="$0"
[ "${SCRIPT_PATH#*/}" != "$SCRIPT_PATH" ] || SCRIPT_PATH="$(pwd)/$SCRIPT_PATH"

# Track installation state for cleanup
INSTALLATION_STARTED=0
DOWNLOAD_PID=""
UNZIP_PID=""

# SSL/ACME configuration
USE_SSL=0
DOMAIN=""
ACME_SCRIPT="/root/.acme.sh/acme.sh"
CERT_DIR="/etc/nginx/ssl"
SSL_PORT=8443
CHALLENGE_TYPE=""  # "http" or "dns"
DNS_PROVIDER=""    # DNS provider for DNS-01 challenge
DNS_API_KEY=""     # API key/token for DNS provider

# -----------------------------
# Detect CPU cores and RAM for tuning
# -----------------------------
detect_hardware() {
  CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

  # Conservative defaults for embedded devices
  if [ "$TOTAL_RAM_MB" -lt 128 ]; then
    NGINX_WORKERS=1
    NGINX_CONNECTIONS=256
  elif [ "$TOTAL_RAM_MB" -lt 256 ]; then
    NGINX_WORKERS=1
    NGINX_CONNECTIONS=512
  else
    # Max 2 workers even on multi-core for embedded devices
    NGINX_WORKERS=$((CPU_CORES > 2 ? 2 : CPU_CORES))
    NGINX_CONNECTIONS=1024
  fi

  log_verbose "Detected: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM"
  log_verbose "NGINX tuning: ${NGINX_WORKERS} workers, ${NGINX_CONNECTIONS} connections"
}

# -----------------------------
# Cleanup any previous updates
# -----------------------------
case "$0" in
*.new)
  ORIGINAL="${0%.new}"
  printf "🧹 Applying update...\n"
  mv -f "$0" "$ORIGINAL" && chmod +x "$ORIGINAL"
  printf "✅ Update applied. Restarting main script...\n"
  sleep 3
  exec "$ORIGINAL" "$@"
  ;;
esac

# -----------------------------
# Utility Functions
# -----------------------------
log_debug() {
  [ "$DEBUG" -eq 1 ] && printf "[DEBUG] %s\n" "$1" >&2
}

log_verbose() {
  [ "$VERBOSE" -eq 1 ] && printf "[INFO] %s\n" "$1"
}

error_exit() {
  printf "${RED}❌ ERROR: %s${RESET}\n" "$1" >&2
  cleanup_on_exit
  exit 1
}

handle_interrupt() {
  printf "\n\n${YELLOW}⚠️  Installation interrupted by user (Ctrl-C)${RESET}\n"
  log_debug "SIGINT received, cleaning up..."
  
  # Kill any background processes (downloads, unzip, etc.)
  if [ -n "$DOWNLOAD_PID" ] && kill -0 "$DOWNLOAD_PID" 2>/dev/null; then
    log_debug "Killing download process $DOWNLOAD_PID"
    kill -TERM "$DOWNLOAD_PID" 2>/dev/null
  fi
  
  if [ -n "$UNZIP_PID" ] && kill -0 "$UNZIP_PID" 2>/dev/null; then
    log_debug "Killing unzip process $UNZIP_PID"
    kill -TERM "$UNZIP_PID" 2>/dev/null
  fi
  
  # Clean up partial installation if started
  if [ "$INSTALLATION_STARTED" -eq 1 ]; then
    printf "${YELLOW}🧹 Cleaning up partial installation...${RESET}\n"
    
    # Stop NGINX if it was started during this session
    if [ -f "$PID_FILE" ]; then
      NGINX_PID=$(cat "$PID_FILE" 2>/dev/null)
      if [ -n "$NGINX_PID" ] && kill -0 "$NGINX_PID" 2>/dev/null; then
        log_debug "Stopping NGINX process $NGINX_PID"
        kill -TERM "$NGINX_PID" 2>/dev/null
        sleep 1
      fi
      rm -f "$PID_FILE"
    fi
    
    # Remove incomplete download/extract
    [ -f "$INSTALL_DIR/main.zip" ] && rm -f "$INSTALL_DIR/main.zip" && log_verbose "Removed incomplete download"
    
    # Restore backup config if it exists
    if [ -f "$CONFIG_BACKUP" ] && [ -f "$CONFIG_PATH" ]; then
      log_debug "Restoring configuration backup"
      mv "$CONFIG_BACKUP" "$CONFIG_PATH"
      printf "${YELLOW}✅ Restored previous configuration${RESET}\n"
    fi
    
    printf "${YELLOW}✅ Cleanup completed${RESET}\n"
  fi
  
  cleanup_on_exit
  printf "${YELLOW}Installation cancelled. Exiting.${RESET}\n"
  exit 130  # Standard exit code for SIGINT
}

cleanup_on_exit() {
  rm -f "$LOCK_FILE" 2>/dev/null
  rm -f "$TMP_NEW_SCRIPT" 2>/dev/null
  log_debug "Cleanup completed"
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      error_exit "Another instance is running (PID: $OLD_PID). Remove $LOCK_FILE if this is a mistake."
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ >"$LOCK_FILE"
  
  # Set up traps for clean exit and interrupt handling
  trap cleanup_on_exit EXIT
  trap handle_interrupt INT TERM
  
  log_debug "Lock acquired and traps set (PID: $$)"
}

spinner() {
  pid=$1
  i=0
  task=$2
  while kill -0 "$pid" 2>/dev/null; do
    frame=$(printf "%s" "$BLA_BOX" | cut -d' ' -f$((i % 4 + 1)))
    printf "\r⏳  %s... %-20s" "$task" "$frame"
    if command -v usleep >/dev/null 2>&1; then
      usleep 200000
    else
      sleep 1
    fi
    i=$((i + 1))
  done
  wait "$pid"
  ret=$?
  if [ $ret -eq 0 ]; then
    printf "\r✅  %s... Done!%-20s\n" "$task" " "
  else
    printf "\r❌  %s... Failed!%-20s\n" "$task" " "
    return $ret
  fi
}

press_any_key() {
  printf "Press any key to continue..."
  read -r _ </dev/tty
}

check_port_available() {
  if netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
    printf "${YELLOW}⚠️  Port $PORT is already in use.${RESET}\n"
    printf "Enter a different port (or press Enter to abort): "
    read -r new_port
    if [ -z "$new_port" ]; then
      error_exit "Installation aborted by user"
    fi
    if ! echo "$new_port" | grep -qE '^[0-9]+$' || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
      error_exit "Invalid port number: $new_port"
    fi
    PORT="$new_port"
    check_port_available # Recursive check
  fi
  log_verbose "Port $PORT is available"
}

validate_download() {
  file="$1"
  min_size="$2"
  if [ ! -f "$file" ]; then
    error_exit "Download failed: $file not found"
  fi
  file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
  if [ "$file_size" -lt "$min_size" ]; then
    error_exit "Download failed: $file is too small ($file_size bytes)"
  fi
  log_debug "Validated $file ($file_size bytes)"
}

# -----------------------------
# Disk Space Check & External Drive
# -----------------------------
check_space() {
  SPACE_CHECK_PATH="$INSTALL_DIR"
  [ ! -e "$INSTALL_DIR" ] && SPACE_CHECK_PATH="/"

  AVAILABLE_SPACE_MB=$(df -m "$SPACE_CHECK_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$AVAILABLE_SPACE_MB" ] || [ "$AVAILABLE_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]; then
    printf "❌ Not enough free space at ${CYAN}%s${RESET}. Required: ${CYAN}%dMB${RESET}, Available: ${CYAN}%sMB${RESET}  \n" "$SPACE_CHECK_PATH" "$REQUIRED_SPACE_MB" "${AVAILABLE_SPACE_MB:-0}"
    printf "\n🔍 Searching mounted external drives for sufficient space...\n"

    for mountpoint in $(awk '$2 ~ /^\/mnt\// {print $2}' /proc/mounts); do
      ext_space=$(df -m "$mountpoint" | awk 'NR==2 {print $4}')
      if [ "$ext_space" -ge "$REQUIRED_SPACE_MB" ]; then
        printf "💾 Found external drive with enough space: ${CYAN}%s${RESET} (${CYAN}%dMB${RESET} available)\n" "$mountpoint" "$ext_space"
        printf "Use it for installation by creating a symlink at ${CYAN}%s${RESET}? [y/N]: " "$INSTALL_DIR"
        read -r use_external
        if [ "$use_external" = "y" ] || [ "$use_external" = "Y" ]; then
          INSTALL_DIR="$mountpoint/openspeedtest"
          mkdir -p "$INSTALL_DIR"
          ln -sf "$INSTALL_DIR" /www2
          printf "✅ Symlink created: /www2 -> ${CYAN}%s${RESET}\n" "$INSTALL_DIR"
          break
        fi
      fi
    done

    NEW_SPACE_MB=$(df -m "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$NEW_SPACE_MB" ] || [ "$NEW_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]; then
      error_exit "Still not enough space to install. Aborting."
    else
      printf "✅ Sufficient space found at new location: ${CYAN}%dMB${RESET} available  \n" "$NEW_SPACE_MB"
    fi
  else
    printf "✅ Sufficient space for installation: ${CYAN}%dMB${RESET} available  \n" "$AVAILABLE_SPACE_MB"
  fi
}

# -----------------------------
# Self-update function
# -----------------------------
check_self_update() {
  printf "\n🔍 Checking for script updates...\n"

  LOCAL_VERSION="$(grep -m1 '^# Version:' "$SCRIPT_PATH" | awk '{print $3}' | tr -d '\r')"
  [ -z "$LOCAL_VERSION" ] && LOCAL_VERSION="0000-00-00"

  if ! wget -q -T 10 -O "$TMP_NEW_SCRIPT" "$SCRIPT_URL"; then
    printf "⚠️  Unable to check for updates (network or GitHub issue).\n"
    rm -f "$TMP_NEW_SCRIPT"
    return 1
  fi

  validate_download "$TMP_NEW_SCRIPT" 1000 || {
    printf "⚠️  Downloaded update file is invalid.\n"
    rm -f "$TMP_NEW_SCRIPT"
    return 1
  }

  REMOTE_VERSION="$(grep -m1 '^# Version:' "$TMP_NEW_SCRIPT" | awk '{print $3}' | tr -d '\r')"
  [ -z "$REMOTE_VERSION" ] && REMOTE_VERSION="0000-00-00"

  printf "📦 Current version: %s\n" "$LOCAL_VERSION"
  printf "🌐 Latest version:  %s\n" "$REMOTE_VERSION"

  if [ "$REMOTE_VERSION" \> "$LOCAL_VERSION" ]; then
    printf "\nA new version is available. Update now? [y/N]: "
    read -r ans
    case "$ans" in
    y | Y)
      printf "⬆️  Updating...\n"
      cp "$TMP_NEW_SCRIPT" "$SCRIPT_PATH.new" && chmod +x "$SCRIPT_PATH.new"
      printf "✅ Upgrade complete. Restarting script...\n"
      exec "$SCRIPT_PATH.new" "$@"
      ;;
    *)
      printf "⏭️  Skipping update. Continuing with current version.\n"
      ;;
    esac
  else
    printf "✅ You are already running the latest version.\n"
  fi

  rm -f "$TMP_NEW_SCRIPT" >/dev/null 2>&1
  printf "\n"
}

# -----------------------------
# Persist Prompt
# -----------------------------
prompt_persist() {
  if [ -n "$AVAILABLE_SPACE_MB" ] && [ "$AVAILABLE_SPACE_MB" -ge "$REQUIRED_SPACE_MB" ] && [ ! -L "$INSTALL_DIR" ]; then
    printf "\n💾 Do you want OpenSpeedTest to persist through firmware updates? [y/N]: "
    read -r persist
    if [ "$persist" = "y" ] || [ "$persist" = "Y" ]; then
      # Core paths
      grep -Fxq "$INSTALL_DIR" /etc/sysupgrade.conf 2>/dev/null || echo "$INSTALL_DIR" >>/etc/sysupgrade.conf
      grep -Fxq "$STARTUP_SCRIPT" /etc/sysupgrade.conf 2>/dev/null || echo "$STARTUP_SCRIPT" >>/etc/sysupgrade.conf
      grep -Fxq "$CONFIG_PATH" /etc/sysupgrade.conf 2>/dev/null || echo "$CONFIG_PATH" >>/etc/sysupgrade.conf
      grep -Fxq "$LOGROTATE_SCRIPT" /etc/sysupgrade.conf 2>/dev/null || echo "$LOGROTATE_SCRIPT" >>/etc/sysupgrade.conf

      # Also persist any rc.d symlinks for startup/shutdown (S* and K*)
      if [ -n "$STARTUP_SCRIPT" ]; then
        SERVICE_NAME=$(basename "$STARTUP_SCRIPT")
        for LINK in $(find /etc/rc.d/ -type l -name "[SK]*${SERVICE_NAME}" 2>/dev/null); do
          grep -Fxq "$LINK" /etc/sysupgrade.conf 2>/dev/null || echo "$LINK" >>/etc/sysupgrade.conf
        done
      fi

      printf "✅ Persistence enabled.\n"
      return
    fi
  fi
  remove_persistence
  printf "✅ Persistence disabled.\n"
}

# -----------------------------
# Remove Persistence
# -----------------------------
remove_persistence() {
  sed -i "\|$INSTALL_DIR|d" /etc/sysupgrade.conf 2>/dev/null
  sed -i "\|$STARTUP_SCRIPT|d" /etc/sysupgrade.conf 2>/dev/null
  sed -i "\|$CONFIG_PATH|d" /etc/sysupgrade.conf 2>/dev/null
  sed -i "\|$LOGROTATE_SCRIPT|d" /etc/sysupgrade.conf 2>/dev/null

  if [ -n "$STARTUP_SCRIPT" ]; then
    SERVICE_NAME=$(basename "$STARTUP_SCRIPT")
    sed -i "\|/etc/rc.d/[SK].*${SERVICE_NAME}|d" /etc/sysupgrade.conf 2>/dev/null
  fi
}

# -----------------------------
# Download Source
# -----------------------------
choose_download_source() {
  printf "\n🌐 Choose download source:\n"
  printf "1️⃣  Official repository\n"
  printf "2️⃣  GL.iNet mirror\n"
  printf "Choose [1-2]: "
  read -r src
  printf "\n"
  case $src in
  1) DOWNLOAD_URL="https://github.com/openspeedtest/Speed-Test/archive/refs/heads/main.zip" ;;
  2) DOWNLOAD_URL="https://fw.gl-inet.com/tools/script/Speed-Test-main.zip" ;;
  *) printf "❌ Invalid option. Defaulting to official repository.\n"; DOWNLOAD_URL="https://github.com/openspeedtest/Speed-Test/archive/refs/heads/main.zip" ;;
  esac
}

# -----------------------------
# SSL Configuration Prompt
# -----------------------------
prompt_ssl_config() {
  printf "\n🔒 Do you want to enable SSL/HTTPS with Let's Encrypt? [y/N]: "
  read -r enable_ssl
  
  if [ "$enable_ssl" = "y" ] || [ "$enable_ssl" = "Y" ]; then
    printf "\n📝 Enter your fully qualified domain name (FQDN):\n"
    printf "   Example: speedtest.example.com\n"
    printf "   FQDN: "
    read -r domain_input
    
    # Validate FQDN format
    if ! echo "$domain_input" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
      printf "${RED}❌ Invalid FQDN format. SSL setup skipped.${RESET}\n"
      printf "   Continuing with HTTP only...\n"
      sleep 2
      return
    fi
    
    DOMAIN="$domain_input"
    USE_SSL=1
    
    printf "\n${GREEN}✅ SSL will be configured for: ${DOMAIN}${RESET}\n"
    
    # Choose validation method
    printf "\n🔐 Choose certificate validation method:\n"
    printf "1️⃣  HTTP-01 (requires public IP and port 80 accessible)\n"
    printf "2️⃣  DNS-01 (works without public IP, requires DNS API)\n"
    printf "3️⃣  Manual DNS (for testing or manual DNS record management)\n"
    printf "Choose [1-3]: "
    read -r challenge_choice
    
    case $challenge_choice in
      1)
        CHALLENGE_TYPE="http"
        printf "\n${YELLOW}⚠️  Requirements for HTTP-01:${RESET}\n"
        printf "   - ${DOMAIN} must point to this router's public IP\n"
        printf "   - Port 80 must be accessible from the internet\n"
        ;;
      2)
        CHALLENGE_TYPE="dns"
        prompt_dns_provider
        if [ -z "$DNS_PROVIDER" ]; then
          printf "${RED}❌ DNS provider setup failed. SSL setup cancelled.${RESET}\n"
          USE_SSL=0
          DOMAIN=""
          return
        fi
        ;;
      3)
        CHALLENGE_TYPE="dns-manual"
        printf "\n${YELLOW}⚠️  Manual DNS validation:${RESET}\n"
        printf "   - You'll need to create TXT records manually\n"
        printf "   - The script will pause and show you what to create\n"
        printf "   - Works without public IP or DNS API\n"
        ;;
      *)
        printf "${RED}❌ Invalid choice. SSL setup cancelled.${RESET}\n"
        USE_SSL=0
        DOMAIN=""
        return
        ;;
    esac
    
    printf "\nContinue with SSL setup? [y/N]: "
    read -r confirm_ssl
    
    if [ "$confirm_ssl" != "y" ] && [ "$confirm_ssl" != "Y" ]; then
      printf "SSL setup cancelled. Continuing with HTTP only...\n"
      USE_SSL=0
      DOMAIN=""
      CHALLENGE_TYPE=""
      sleep 2
    fi
  fi
}

# -----------------------------
# DNS Provider Configuration
# -----------------------------
prompt_dns_provider() {
  printf "\n🌐 Select your DNS provider:\n"
  printf "1️⃣  Cloudflare (recommended)\n"
  printf "2️⃣  AWS Route53\n"
  printf "3️⃣  Google Cloud DNS\n"
  printf "4️⃣  DigitalOcean\n"
  printf "5️⃣  Namecheap\n"
  printf "6️⃣  GoDaddy\n"
  printf "7️⃣  Dynu\n"
  printf "8️⃣  Duck DNS (free)\n"
  printf "9️⃣  Other (manual setup required)\n"
  printf "Choose [1-9]: "
  read -r dns_choice
  
  case $dns_choice in
    1)
      DNS_PROVIDER="dns_cf"
      printf "\n📝 Cloudflare Configuration:\n"
      printf "   Visit: https://dash.cloudflare.com/profile/api-tokens\n"
      printf "   Create token with Zone:DNS:Edit permissions\n"
      printf "\nEnter Cloudflare API Token: "
      read -r api_token
      if [ -z "$api_token" ]; then
        printf "${RED}❌ API token required${RESET}\n"
        return 1
      fi
      export CF_Token="$api_token"
      DNS_API_KEY="$api_token"
      ;;
    2)
      DNS_PROVIDER="dns_aws"
      printf "\n📝 AWS Route53 Configuration:\n"
      printf "Enter AWS Access Key ID: "
      read -r aws_key
      printf "Enter AWS Secret Access Key: "
      read -r aws_secret
      if [ -z "$aws_key" ] || [ -z "$aws_secret" ]; then
        printf "${RED}❌ AWS credentials required${RESET}\n"
        return 1
      fi
      export AWS_ACCESS_KEY_ID="$aws_key"
      export AWS_SECRET_ACCESS_KEY="$aws_secret"
      DNS_API_KEY="${aws_key}:${aws_secret}"
      ;;
    3)
      DNS_PROVIDER="dns_gcloud"
      printf "\n📝 Google Cloud DNS Configuration:\n"
      printf "Enter path to service account JSON file: "
      read -r gcloud_json
      if [ ! -f "$gcloud_json" ]; then
        printf "${RED}❌ JSON file not found${RESET}\n"
        return 1
      fi
      export CLOUDSDK_CORE_PROJECT="$(grep project_id "$gcloud_json" | cut -d'"' -f4)"
      DNS_API_KEY="$gcloud_json"
      ;;
    4)
      DNS_PROVIDER="dns_dgon"
      printf "\n📝 DigitalOcean Configuration:\n"
      printf "   Visit: https://cloud.digitalocean.com/account/api/tokens\n"
      printf "Enter DigitalOcean API Token: "
      read -r do_token
      if [ -z "$do_token" ]; then
        printf "${RED}❌ API token required${RESET}\n"
        return 1
      fi
      export DO_API_KEY="$do_token"
      DNS_API_KEY="$do_token"
      ;;
    5)
      DNS_PROVIDER="dns_namecheap"
      printf "\n📝 Namecheap Configuration:\n"
      printf "Enter Namecheap API Username: "
      read -r nc_user
      printf "Enter Namecheap API Key: "
      read -r nc_key
      if [ -z "$nc_user" ] || [ -z "$nc_key" ]; then
        printf "${RED}❌ API credentials required${RESET}\n"
        return 1
      fi
      export NAMECHEAP_API_KEY="$nc_key"
      export NAMECHEAP_USERNAME="$nc_user"
      DNS_API_KEY="${nc_user}:${nc_key}"
      ;;
    6)
      DNS_PROVIDER="dns_gd"
      printf "\n📝 GoDaddy Configuration:\n"
      printf "Enter GoDaddy API Key: "
      read -r gd_key
      printf "Enter GoDaddy API Secret: "
      read -r gd_secret
      if [ -z "$gd_key" ] || [ -z "$gd_secret" ]; then
        printf "${RED}❌ API credentials required${RESET}\n"
        return 1
      fi
      export GD_Key="$gd_key"
      export GD_Secret="$gd_secret"
      DNS_API_KEY="${gd_key}:${gd_secret}"
      ;;
    7)
      DNS_PROVIDER="dns_dynu"
      printf "\n📝 Dynu Configuration:\n"
      printf "Enter Dynu Client ID: "
      read -r dynu_id
      printf "Enter Dynu Secret: "
      read -r dynu_secret
      if [ -z "$dynu_id" ] || [ -z "$dynu_secret" ]; then
        printf "${RED}❌ API credentials required${RESET}\n"
        return 1
      fi
      export Dynu_ClientId="$dynu_id"
      export Dynu_Secret="$dynu_secret"
      DNS_API_KEY="${dynu_id}:${dynu_secret}"
      ;;
    8)
      DNS_PROVIDER="dns_duckdns"
      printf "\n📝 Duck DNS Configuration (FREE):\n"
      printf "   Visit: https://www.duckdns.org/\n"
      printf "   Your domain should be: something.duckdns.org\n"
      printf "Enter Duck DNS Token: "
      read -r duck_token
      if [ -z "$duck_token" ]; then
        printf "${RED}❌ Token required${RESET}\n"
        return 1
      fi
      export DuckDNS_Token="$duck_token"
      DNS_API_KEY="$duck_token"
      ;;
    9)
      printf "\n${YELLOW}Manual DNS provider setup${RESET}\n"
      printf "Enter DNS provider name (from acme.sh docs): "
      read -r manual_dns
      DNS_PROVIDER="$manual_dns"
      printf "${YELLOW}⚠️  You'll need to export provider-specific env vars manually${RESET}\n"
      ;;
    *)
      printf "${RED}❌ Invalid choice${RESET}\n"
      return 1
      ;;
  esac
  
  printf "${GREEN}✅ DNS provider configured: ${DNS_PROVIDER}${RESET}\n"
  return 0
}

# -----------------------------
# Install acme.sh
# -----------------------------
install_acme_sh() {
  if [ -f "$ACME_SCRIPT" ]; then
    log_verbose "acme.sh already installed"
    return 0
  fi
  
  printf "📦 Installing acme.sh (Let's Encrypt client)...\n"
  
  # Install required dependencies
  if ! command -v socat >/dev/null 2>&1; then
    if [ "$opkg_updated" -eq 0 ]; then
      opkg update >/dev/null 2>&1
      opkg_updated=1
    fi
    opkg install socat >/dev/null 2>&1 || printf "${YELLOW}⚠️  Could not install socat, using standalone mode${RESET}\n"
  fi
  
  # Download and install acme.sh
  wget -O /tmp/acme.sh.tar.gz https://github.com/acmesh-official/acme.sh/archive/master.tar.gz 2>/dev/null || {
    error_exit "Failed to download acme.sh"
  }
  
  cd /tmp || error_exit "Cannot access /tmp"
  tar -xzf acme.sh.tar.gz || error_exit "Failed to extract acme.sh"
  cd acme.sh-master || error_exit "acme.sh directory not found"
  
  ./acme.sh --install --nocron --home /root/.acme.sh || error_exit "Failed to install acme.sh"
  
  cd /
  rm -rf /tmp/acme.sh-master /tmp/acme.sh.tar.gz
  
  printf "${GREEN}✅ acme.sh installed successfully${RESET}\n"
}

# -----------------------------
# Issue SSL Certificate
# -----------------------------
issue_certificate() {
  printf "\n🔐 Requesting SSL certificate for ${DOMAIN}...\n"
  printf "${YELLOW}This may take 1-2 minutes...${RESET}\n\n"
  
  # Create cert directory
  mkdir -p "$CERT_DIR"
  
  # Choose validation method based on CHALLENGE_TYPE
  case "$CHALLENGE_TYPE" in
    http)
      # HTTP-01 Challenge - requires port 80 and public IP
      printf "📡 Using HTTP-01 validation (standalone mode)\n"
      
      # Stop NGINX if running (port 80 needed for validation)
      if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_debug "Stopping NGINX temporarily for certificate validation"
        "$STARTUP_SCRIPT" stop >/dev/null 2>&1
        sleep 2
      fi
      
      if ! "$ACME_SCRIPT" --issue --standalone -d "$DOMAIN" --keylength 2048 --server letsencrypt; then
        printf "${RED}❌ Failed to issue certificate (HTTP-01)${RESET}\n"
        printf "${YELLOW}Common issues:${RESET}\n"
        printf "  - Domain does not point to this router's public IP\n"
        printf "  - Port 80 is not accessible from the internet\n"
        printf "  - Firewall blocking incoming connections\n"
        printf "\n${YELLOW}💡 Tip: Try DNS-01 validation if HTTP-01 fails${RESET}\n"
        printf "Continuing with HTTP only...\n"
        USE_SSL=0
        sleep 3
        return 1
      fi
      ;;
      
    dns)
      # DNS-01 Challenge - works without public IP
      printf "🌐 Using DNS-01 validation (${DNS_PROVIDER})\n"
      printf "${GREEN}✅ No public IP or open ports required!${RESET}\n\n"
      
      if ! "$ACME_SCRIPT" --issue --dns "$DNS_PROVIDER" -d "$DOMAIN" --keylength 2048 --server letsencrypt; then
        printf "${RED}❌ Failed to issue certificate (DNS-01)${RESET}\n"
        printf "${YELLOW}Common issues:${RESET}\n"
        printf "  - Invalid DNS API credentials\n"
        printf "  - Insufficient DNS API permissions\n"
        printf "  - DNS provider not supported by acme.sh\n"
        printf "\nContinuing with HTTP only...\n"
        USE_SSL=0
        sleep 3
        return 1
      fi
      ;;
      
    dns-manual)
      # Manual DNS-01 Challenge - user creates TXT records manually
      printf "📝 Using Manual DNS-01 validation\n"
      printf "${YELLOW}⚠️  You will need to create DNS TXT records manually${RESET}\n\n"
      
      if ! "$ACME_SCRIPT" --issue --dns -d "$DOMAIN" --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength 2048 --server letsencrypt; then
        printf "${RED}❌ Failed to issue certificate (Manual DNS)${RESET}\n"
        printf "${YELLOW}Common issues:${RESET}\n"
        printf "  - TXT record not created or not propagated\n"
        printf "  - TXT record value incorrect\n"
        printf "  - DNS propagation can take 5-30 minutes\n"
        printf "\nContinuing with HTTP only...\n"
        USE_SSL=0
        sleep 3
        return 1
      fi
      ;;
      
    *)
      printf "${RED}❌ Unknown challenge type: ${CHALLENGE_TYPE}${RESET}\n"
      USE_SSL=0
      return 1
      ;;
  esac
  
  # Install certificate to NGINX directory
  "$ACME_SCRIPT" --install-cert -d "$DOMAIN" \
    --key-file "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/${DOMAIN}.crt" \
    --reloadcmd "/etc/init.d/nginx_speedtest reload" || {
    printf "${RED}❌ Failed to install certificate${RESET}\n"
    USE_SSL=0
    return 1
  }
  
  printf "${GREEN}✅ SSL certificate issued and installed successfully${RESET}\n"
  
  # Set up auto-renewal
  setup_cert_renewal
  
  return 0
}

# -----------------------------
# Setup Certificate Auto-Renewal
# -----------------------------
setup_cert_renewal() {
  printf "⚙️  Setting up automatic certificate renewal...\n"
  
  # Create cron job for renewal (runs daily, renews if within 60 days of expiry)
  CRON_JOB="0 0 * * * $ACME_SCRIPT --cron --home /root/.acme.sh > /dev/null"
  
  # Check if cron job already exists
  if ! crontab -l 2>/dev/null | grep -q "$ACME_SCRIPT --cron"; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    printf "${GREEN}✅ Auto-renewal configured (daily check)${RESET}\n"
  else
    log_verbose "Cron job already exists"
  fi
  
  # Add to persistence if enabled
  if [ -f /etc/sysupgrade.conf ]; then
    grep -Fxq "/root/.acme.sh" /etc/sysupgrade.conf 2>/dev/null || echo "/root/.acme.sh" >> /etc/sysupgrade.conf
    grep -Fxq "$CERT_DIR" /etc/sysupgrade.conf 2>/dev/null || echo "$CERT_DIR" >> /etc/sysupgrade.conf
  fi
}

# -----------------------------
# Detect Internal IP
# -----------------------------
detect_internal_ip() {
  INTERNAL_IP="$(uci get network.lan.ipaddr 2>/dev/null | tr -d '\r\n')"
  [ -z "$INTERNAL_IP" ] && INTERNAL_IP="<router_ip>"
}

# -----------------------------
# Install Dependencies
# -----------------------------
install_dependencies() {
  DEPENDENCIES="curl:curl nginx:nginx-ssl timeout:coreutils-timeout unzip:unzip wget:wget"

  for item in $DEPENDENCIES; do
    CMD=${item%%:*} # command name
    PKG=${item##*:} # package name

    # Uppercase using BusyBox-compatible tr
    CMD_UP=$(printf "%s" "$CMD" | tr 'a-z' 'A-Z')
    PKG_UP=$(printf "%s" "$PKG" | tr 'a-z' 'A-Z')

    if ! command -v "$CMD" >/dev/null 2>&1; then
      printf "${CYAN}📦 %s${RESET} not found. Installing ${CYAN}%s${RESET}...\n" "$CMD_UP" "$PKG_UP"
      if [ "$opkg_updated" -eq 0 ]; then
        opkg update >/dev/null 2>&1 || error_exit "Failed to update opkg package list"
        opkg_updated=1
      fi

      if opkg install "$PKG" >/dev/null 2>&1; then
        printf "${CYAN}✅ %s${RESET} installed successfully.\n" "$PKG_UP"
        if [ "$PKG" = "nginx-ssl" ]; then
          /etc/init.d/nginx stop >/dev/null 2>&1
          /etc/init.d/nginx disable >/dev/null 2>&1
          if [ -f /etc/nginx/conf.d/default.conf ]; then
            rm -f /etc/nginx/conf.d/default.conf
          fi
        fi
      else
        error_exit "Failed to install $PKG_UP. Check your internet or opkg configuration."
      fi
    else
      printf "${CYAN}✅ %s${RESET} already installed.\n" "$CMD_UP"
    fi
  done
}

# -----------------------------
# Create Log Rotation Script
# -----------------------------
create_logrotate() {
  mkdir -p /etc/cron.daily
  cat <<'EOF' >"$LOGROTATE_SCRIPT"
#!/bin/sh
# Aggressive log rotation for OpenSpeedTest NGINX
# Keeps only errors, rotates daily, keeps max 2 days

ERROR_LOG="/var/log/nginx_openspeedtest_error.log"
MAX_SIZE_KB=100  # Rotate if larger than 100KB
MAX_AGE_DAYS=2

# Rotate if file exists and is larger than MAX_SIZE_KB
if [ -f "$ERROR_LOG" ]; then
    SIZE_KB=$(du -k "$ERROR_LOG" | cut -f1)
    if [ "$SIZE_KB" -gt "$MAX_SIZE_KB" ]; then
        mv "$ERROR_LOG" "$ERROR_LOG.1" 2>/dev/null
        # Signal NGINX to reopen log files
        if [ -f "/var/run/nginx_OpenSpeedTest.pid" ]; then
            kill -USR1 $(cat /var/run/nginx_OpenSpeedTest.pid) 2>/dev/null
        fi
    fi
fi

# Delete old rotated logs
find /var/log/ -name "nginx_openspeedtest_error.log.*" -mtime +${MAX_AGE_DAYS} -delete 2>/dev/null

exit 0
EOF
  chmod +x "$LOGROTATE_SCRIPT"
  printf "✅ Log rotation script created at ${CYAN}%s${RESET}\n" "$LOGROTATE_SCRIPT"
  log_verbose "Logs will rotate when >100KB, kept for 2 days max"
}

# -----------------------------
# Validate NGINX Configuration
# -----------------------------
validate_nginx_config() {
  log_debug "Validating NGINX configuration"
  if ! /usr/sbin/nginx -t -c "$CONFIG_PATH" 2>&1 | grep -q "successful"; then
    printf "${RED}❌ NGINX configuration validation failed${RESET}\n"
    /usr/sbin/nginx -t -c "$CONFIG_PATH" 2>&1
    if [ -f "$CONFIG_BACKUP" ]; then
      printf "Restoring backup configuration...\n"
      mv "$CONFIG_BACKUP" "$CONFIG_PATH"
    fi
    error_exit "Invalid NGINX configuration"
  fi
  log_verbose "NGINX configuration is valid"
}

# -----------------------------
# Install OpenSpeedTest
# -----------------------------
install_openspeedtest() {
  acquire_lock
  INSTALLATION_STARTED=1  # Mark installation as started for cleanup
  
  detect_hardware
  check_port_available
  prompt_ssl_config  # Ask about SSL before installation
  install_dependencies
  check_space
  choose_download_source
  
  # Install acme.sh if SSL is requested
  if [ "$USE_SSL" -eq 1 ]; then
    install_acme_sh
  fi

  # Backup existing config if present
  [ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "$CONFIG_BACKUP"

  # Stop running OpenSpeedTest if PID exists
  if [ -s "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
      printf "⚠️  Existing OpenSpeedTest detected. Stopping...\n"
      kill "$OLD_PID" && printf "✅ Stopped.\n" || printf "❌ Failed to stop.\n"
      sleep 2
      rm -f "$PID_FILE"
    fi
  fi

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || error_exit "Cannot access $INSTALL_DIR"
  [ -d Speed-Test-main ] && rm -rf Speed-Test-main

  # Download with spinner and timeout
  log_debug "Downloading from $DOWNLOAD_URL"
  timeout 300 wget -q -T 30 -O main.zip "$DOWNLOAD_URL" >/dev/null 2>&1 &
  DOWNLOAD_PID=$!
  if ! spinner "$DOWNLOAD_PID" "Downloading OpenSpeedTest"; then
    DOWNLOAD_PID=""
    error_exit "Download failed or timed out"
  fi
  DOWNLOAD_PID=""  # Clear after successful completion
  validate_download "main.zip" 100000

  # Unzip with spinner
  unzip -o main.zip >/dev/null 2>&1 &
  UNZIP_PID=$!
  if ! spinner "$UNZIP_PID" "Unzipping"; then
    UNZIP_PID=""
    error_exit "Extraction failed"
  fi
  UNZIP_PID=""  # Clear after successful completion
  rm main.zip

  # Verify extraction
  [ -d Speed-Test-main ] || error_exit "Speed-Test-main directory not found after extraction"

  # Create optimized NGINX config for embedded devices
  if [ "$USE_SSL" -eq 1 ]; then
    # Generate config with SSL support
    cat <<EOF >"$CONFIG_PATH"
# Optimized NGINX config for OpenWrt/embedded devices with SSL
# Auto-tuned for: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM
# Domain: ${DOMAIN}

worker_processes  ${NGINX_WORKERS};
worker_rlimit_nofile 4096;
user nobody nogroup;

events {
    worker_connections ${NGINX_CONNECTIONS};
    multi_accept on;
}

error_log  ${ERROR_LOG} crit;
pid        ${PID_FILE};

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;
    keepalive_requests 50;
    
    client_body_timeout 30s;
    client_header_timeout 30s;
    send_timeout 30s;
    
    client_body_buffer_size 8k;
    client_header_buffer_size 1k;
    large_client_header_buffers 2 1k;
    
    server_tokens off;

    # HTTP server - redirect to HTTPS
    server {
        listen 80;
        server_name ${DOMAIN};
        
        # Allow ACME challenges for certificate renewal
        location ^~ /.well-known/acme-challenge/ {
            default_type "text/plain";
            root /tmp;
        }
        
        # Redirect all other traffic to HTTPS
        location / {
            return 301 https://\$server_name\$request_uri;
        }
    }

    # HTTPS server
    server {
        listen ${SSL_PORT} ssl;
        server_name ${DOMAIN};
        root ${INSTALL_DIR}/Speed-Test-main;
        index index.html;

        # SSL configuration
        ssl_certificate ${CERT_DIR}/${DOMAIN}.crt;
        ssl_certificate_key ${CERT_DIR}/${DOMAIN}.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        client_max_body_size 1024M;
        access_log off;
        log_not_found off;
        error_page 405 =200 \$uri;

        location / {
            add_header 'Access-Control-Allow-Origin' "*" always;
            add_header 'Access-Control-Allow-Headers' 'Accept,Authorization,Cache-Control,Content-Type,DNT,If-Modified-Since,Keep-Alive,Origin,User-Agent,X-Mx-ReqToken,X-Requested-With' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Cache-Control' 'no-store, no-cache, max-age=0, no-transform';
            add_header 'Strict-Transport-Security' 'max-age=31536000' always;
            
            if (\$request_method = OPTIONS) {
                add_header 'Access-Control-Allow-Credentials' "true";
                return 204;
            }
        }

        location ~* ^.+\\.(?:css|cur|js|jpe?g|gif|htc|ico|png|html|xml|otf|ttf|eot|woff|woff2|svg)\$ {
            access_log off;
            expires 7d;
            add_header Cache-Control public;
            tcp_nodelay off;
        }
    }
}
EOF
  else
    # Generate config without SSL (HTTP only)
    cat <<EOF >"$CONFIG_PATH"
# Optimized NGINX config for OpenWrt/embedded devices
# Auto-tuned for: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM

worker_processes  ${NGINX_WORKERS};
worker_rlimit_nofile 4096;
user nobody nogroup;

events {
    worker_connections ${NGINX_CONNECTIONS};
    multi_accept on;
}

error_log  ${ERROR_LOG} crit;
pid        ${PID_FILE};

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;
    keepalive_requests 50;
    
    client_body_timeout 30s;
    client_header_timeout 30s;
    send_timeout 30s;
    
    client_body_buffer_size 8k;
    client_header_buffer_size 1k;
    large_client_header_buffers 2 1k;
    
    server_tokens off;

    server {
        server_name _;
        listen ${PORT};
        root ${INSTALL_DIR}/Speed-Test-main;
        index index.html;

        client_max_body_size 1024M;
        access_log off;
        log_not_found off;
        error_page 405 =200 \$uri;

        location / {
            add_header 'Access-Control-Allow-Origin' "*" always;
            add_header 'Access-Control-Allow-Headers' 'Accept,Authorization,Cache-Control,Content-Type,DNT,If-Modified-Since,Keep-Alive,Origin,User-Agent,X-Mx-ReqToken,X-Requested-With' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Cache-Control' 'no-store, no-cache, max-age=0, no-transform';
            
            if (\$request_method = OPTIONS) {
                add_header 'Access-Control-Allow-Credentials' "true";
                return 204;
            }
        }

        location ~* ^.+\\.(?:css|cur|js|jpe?g|gif|htc|ico|png|html|xml|otf|ttf|eot|woff|woff2|svg)\$ {
            access_log off;
            expires 7d;
            add_header Cache-Control public;
            tcp_nodelay off;
        }
    }
}
EOF
  fi

  # Validate configuration
  validate_nginx_config

  # Detect if system uses procd or traditional init
  if command -v procd >/dev/null 2>&1 && [ -d /etc/init.d ]; then
    log_verbose "Using procd service management"
    # Create procd-compatible startup script
    cat <<'EOF' >"$STARTUP_SCRIPT"
#!/bin/sh /etc/rc.common
# procd-compatible init script for OpenSpeedTest

START=81
STOP=15
USE_PROCD=1

NGINX_BIN="/usr/sbin/nginx"
NGINX_CONF="/etc/nginx/nginx_openspeedtest.conf"
PID_FILE="/var/run/nginx_OpenSpeedTest.pid"
PORT=8888

start_service() {
    # Check if port is available
    if netstat -tuln 2>/dev/null | grep -q ":${PORT} "; then
        echo "Port ${PORT} already in use. Cannot start OpenSpeedTest NGINX."
        return 1
    fi
    
    procd_open_instance
    procd_set_param command "$NGINX_BIN" -c "$NGINX_CONF" -g "daemon off;"
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-0}
    procd_set_param stdout 0
    procd_set_param stderr 1
    procd_set_param pidfile "$PID_FILE"
    procd_close_instance
}

stop_service() {
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi
}

reload_service() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        "$NGINX_BIN" -t -c "$NGINX_CONF" && kill -HUP $(cat "$PID_FILE")
    else
        start
    fi
}
EOF
  else
    log_verbose "Using traditional init.d service"
    # Create traditional init script
    cat <<EOF >"$STARTUP_SCRIPT"
#!/bin/sh /etc/rc.common
START=81
STOP=15

NGINX_BIN="/usr/sbin/nginx"
NGINX_CONF="${CONFIG_PATH}"
PID_FILE="${PID_FILE}"

start() {
    if netstat -tuln | grep -q ":${PORT} "; then
        printf "⚠️  Port ${PORT} already in use. Cannot start OpenSpeedTest NGINX.\n"
        return 1
    fi
    printf "Starting OpenSpeedTest NGINX Server..."
    "\$NGINX_BIN" -c "\$NGINX_CONF"
    printf " ✅\n"
}

stop() {
    if [ -s "\$PID_FILE" ]; then
        kill \$(cat "\$PID_FILE") 2>/dev/null
        rm -f "\$PID_FILE"
    fi
}

reload() {
    if [ -f "\$PID_FILE" ] && kill -0 \$(cat "\$PID_FILE") 2>/dev/null; then
        "\$NGINX_BIN" -t -c "\$NGINX_CONF" && kill -HUP \$(cat "\$PID_FILE")
    fi
}
EOF
  fi

  chmod +x "$STARTUP_SCRIPT"
  "$STARTUP_SCRIPT" enable || log_verbose "Service enable returned non-zero"

  # Create log rotation
  create_logrotate

  # Issue SSL certificate if requested
  if [ "$USE_SSL" -eq 1 ]; then
    if ! issue_certificate; then
      printf "${YELLOW}⚠️  SSL certificate issuance failed. Starting with HTTP only.${RESET}\n"
      USE_SSL=0
      # Regenerate config without SSL
      cat <<EOF >"$CONFIG_PATH"
# Fallback HTTP-only config after SSL failure
worker_processes  ${NGINX_WORKERS};
worker_rlimit_nofile 4096;
user nobody nogroup;

events {
    worker_connections ${NGINX_CONNECTIONS};
    multi_accept on;
}

error_log  ${ERROR_LOG} crit;
pid        ${PID_FILE};

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;
    keepalive_requests 50;
    client_body_timeout 30s;
    client_header_timeout 30s;
    send_timeout 30s;
    client_body_buffer_size 8k;
    client_header_buffer_size 1k;
    large_client_header_buffers 2 1k;
    server_tokens off;

    server {
        server_name _;
        listen ${PORT};
        root ${INSTALL_DIR}/Speed-Test-main;
        index index.html;
        client_max_body_size 1024M;
        access_log off;
        log_not_found off;
        error_page 405 =200 \$uri;

        location / {
            add_header 'Access-Control-Allow-Origin' "*" always;
            add_header 'Access-Control-Allow-Headers' 'Accept,Authorization,Cache-Control,Content-Type,DNT,If-Modified-Since,Keep-Alive,Origin,User-Agent,X-Mx-ReqToken,X-Requested-With' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Cache-Control' 'no-store, no-cache, max-age=0, no-transform';
            if (\$request_method = OPTIONS) {
                add_header 'Access-Control-Allow-Credentials' "true";
                return 204;
            }
        }

        location ~* ^.+\\.(?:css|cur|js|jpe?g|gif|htc|ico|png|html|xml|otf|ttf|eot|woff|woff2|svg)\$ {
            access_log off;
            expires 7d;
            add_header Cache-Control public;
            tcp_nodelay off;
        }
    }
}
EOF
      validate_nginx_config
    fi
  fi

  # Start NGINX
  printf "Starting OpenSpeedTest NGINX...\n"
  if ! "$STARTUP_SCRIPT" start; then
    error_exit "Failed to start NGINX service"
  fi

  # Verify it started
  sleep 2
  if [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    error_exit "NGINX started but is not running. Check logs: $ERROR_LOG"
  fi

  # Detect internal IP
  detect_internal_ip
  printf "\n✅ Installation complete!\n"
  
  if [ "$USE_SSL" -eq 1 ]; then
    printf "🔒 SSL enabled: ${GREEN}https://%s:%d${RESET}\n" "$DOMAIN" "$SSL_PORT"
    printf "🌐 HTTP redirect: http://%s (redirects to HTTPS)\n" "$DOMAIN"
    printf "📜 Certificate: ${CERT_DIR}/${DOMAIN}.crt\n"
    printf "🔄 Auto-renewal: Configured (daily check)\n"
  else
    printf "🌐 Access OpenSpeedTest at: ${CYAN}http://%s:%d${RESET}\n" "$INTERNAL_IP" "$PORT"
  fi
  
  printf "📊 Performance tuning: ${NGINX_WORKERS} workers, ${NGINX_CONNECTIONS} max connections\n"
  printf "📝 Error logs: ${ERROR_LOG} (errors only, rotated at 100KB)\n"

  INSTALLATION_STARTED=0  # Reset flag after successful installation
  prompt_persist
  press_any_key
}

# -----------------------------
# Diagnostics
# -----------------------------
diagnose_nginx() {
  printf "\n🔍 Running OpenSpeedTest diagnostics...\n\n"

  # Detect internal IP
  detect_internal_ip
  detect_hardware

  # Check if NGINX process is running
  if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    printf "✅ OpenSpeedTest NGINX process is running (PID: %s)\n" "$(cat "$PID_FILE")"
  else
    printf "❌ OpenSpeedTest NGINX process is NOT running\n"
  fi

  # Check if port is listening
  if netstat -tuln | grep ":$PORT " >/dev/null; then
    printf "✅ Port %d is open and listening on %s\n" "$PORT" "$INTERNAL_IP"
    printf "🌐 You can access OpenSpeedTest at: ${CYAN}http://%s:%d${RESET}\n" "$INTERNAL_IP" "$PORT"
  else
    printf "❌ Port %d is not listening on %s\n" "$PORT" "$INTERNAL_IP"
  fi

  # Check configuration
  if [ -f "$CONFIG_PATH" ]; then
    printf "✅ Configuration file exists: ${CONFIG_PATH}\n"
    if /usr/sbin/nginx -t -c "$CONFIG_PATH" >/dev/null 2>&1; then
      printf "✅ Configuration is valid\n"
    else
      printf "❌ Configuration has errors:\n"
      /usr/sbin/nginx -t -c "$CONFIG_PATH" 2>&1
    fi
  else
    printf "❌ Configuration file missing: ${CONFIG_PATH}\n"
  fi

  # Check logs
  if [ -f "$ERROR_LOG" ]; then
    LOG_SIZE=$(du -h "$ERROR_LOG" | cut -f1)
    printf "📝 Error log: ${ERROR_LOG} (${LOG_SIZE})\n"
    if [ -s "$ERROR_LOG" ]; then
      printf "   Last 5 errors:\n"
      tail -5 "$ERROR_LOG" | sed 's/^/   /'
    fi
  else
    printf "📝 Error log not yet created\n"
  fi

  # System resources
  printf "\n💻 System Resources:\n"
  printf "   CPU cores: %d\n" "$CPU_CORES"
  printf "   Total RAM: %dMB\n" "$TOTAL_RAM_MB"
  printf "   Free RAM: %dMB\n" "$(free -m | awk 'NR==2{print $4}')"
  printf "   Disk space at %s: %dMB free\n" "$INSTALL_DIR" "$(df -m "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}')"

  press_any_key
}

# -----------------------------
# Uninstall OpenSpeedTest
# -----------------------------
uninstall_all() {
  printf "\n🧹 This will remove OpenSpeedTest, the startup script, and /www2 contents.\n"
  printf "Are you sure? [y/N]: "
  read -r confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    printf "❌ Uninstall cancelled.\n"
    press_any_key
    return
  fi

  # Stop service
  if [ -f "$STARTUP_SCRIPT" ]; then
    printf "Stopping service...\n"
    "$STARTUP_SCRIPT" stop 2>/dev/null
    "$STARTUP_SCRIPT" disable 2>/dev/null
    rm -f "$STARTUP_SCRIPT"
  fi

  # Kill process if still running
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
  fi

  # Remove files
  [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR" && printf "✅ Removed ${INSTALL_DIR}\n"
  [ -L "/www2" ] && rm -f "/www2" && printf "✅ Removed /www2 symlink\n"
  [ -f "$CONFIG_PATH" ] && rm -f "$CONFIG_PATH" && printf "✅ Removed configuration\n"
  [ -f "$CONFIG_BACKUP" ] && rm -f "$CONFIG_BACKUP" && printf "✅ Removed backup configuration\n"
  [ -f "$LOGROTATE_SCRIPT" ] && rm -f "$LOGROTATE_SCRIPT" && printf "✅ Removed log rotation script\n"
  [ -f "$ERROR_LOG" ] && rm -f "$ERROR_LOG" && printf "✅ Removed error logs\n"
  find /var/log/ -name "nginx_openspeedtest_error.log.*" -delete 2>/dev/null

  remove_persistence
  printf "✅ OpenSpeedTest uninstall complete.\n"
  press_any_key
}

# -----------------------------
# Check for updates
# -----------------------------
command -v clear >/dev/null 2>&1 && clear
printf "%b\n" "$SPLASH"
check_self_update "$@"

# -----------------------------
# Main Menu
# -----------------------------
show_menu() {
  clear
  printf "%b\n" "$SPLASH"
  printf "%b\n" "${CYAN}Please select an option:${RESET}\n"
  printf "1️⃣  Install OpenSpeedTest\n"
  printf "2️⃣  Run diagnostics\n"
  printf "3️⃣  Uninstall everything\n"
  printf "4️⃣  Check for update\n"
  printf "5️⃣  Exit\n"
  printf "Choose [1-5]: "
  read opt
  printf "\n"
  case $opt in
  1) install_openspeedtest ;;
  2) diagnose_nginx ;;
  3) uninstall_all ;;
  4) check_self_update "$@" && press_any_key ;;
  5)
    cleanup_on_exit
    exit 0
    ;;
  *)
    printf "%b\n" "${RED}❌ Invalid option.  ${RESET}"
    sleep 1
    show_menu
    ;;
  esac
  show_menu
}

# -----------------------------
# Start
# -----------------------------
show_menu
