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

cleanup_on_exit() {
  rm -f "$LOCK_FILE" 2>/dev/null
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
  trap cleanup_on_exit EXIT INT TERM
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
  *)
    printf "❌ Invalid option. Defaulting to official repository.\n"
    DOWNLOAD_URL="https://github.com/openspeedtest/Speed-Test/archive/refs/heads/main.zip"
    ;;
  esac
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
  detect_hardware
  check_port_available
  install_dependencies
  check_space
  choose_download_source

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
  wget_pid=$!
  if ! spinner "$wget_pid" "Downloading OpenSpeedTest"; then
    error_exit "Download failed or timed out"
  fi
  validate_download "main.zip" 100000

  # Unzip with spinner
  unzip -o main.zip >/dev/null 2>&1 &
  unzip_pid=$!
  if ! spinner "$unzip_pid" "Unzipping"; then
    error_exit "Extraction failed"
  fi
  rm main.zip

  # Verify extraction
  [ -d Speed-Test-main ] || error_exit "Speed-Test-main directory not found after extraction"

  # Create optimized NGINX config for embedded devices
  cat <<EOF >"$CONFIG_PATH"
# Optimized NGINX config for OpenWrt/embedded devices
# Auto-tuned for: ${CPU_CORES} cores, ${TOTAL_RAM_MB}MB RAM

worker_processes  ${NGINX_WORKERS};
worker_rlimit_nofile 4096;  # Reduced from 100000 for embedded devices
worker_priority -5;
user nobody nogroup;

events {
    worker_connections ${NGINX_CONNECTIONS};  # Tuned based on available RAM
    multi_accept on;
    use epoll;  # Efficient for Linux
}

# Only log critical errors to conserve disk space
error_log  ${ERROR_LOG} crit;
pid        ${PID_FILE};

http {
    include       mime.types;
    default_type  application/octet-stream;

    # Performance tuning for embedded devices
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;  # Reduced from default 65
    keepalive_requests 50;  # Limit reuse
    reset_timedout_connection on;
    
    # Connection timeouts to prevent resource exhaustion
    client_body_timeout 30s;
    client_header_timeout 30s;
    send_timeout 30s;
    
    # Buffer sizes - conservative for low RAM
    client_body_buffer_size 8k;
    client_header_buffer_size 1k;
    large_client_header_buffers 2 1k;
    
    # Disable unused features
    server_tokens off;
    gzip off;  # Speed test should not use compression

    server {
        server_name _ localhost;
        listen ${PORT};
        root ${INSTALL_DIR}/Speed-Test-main;
        index index.html;

        # Reasonable limit for speed tests (1GB)
        client_max_body_size 1024M;
        
        # No logging for performance
        access_log off;
        log_not_found off;
        
        error_page 405 =200 \$uri;
        
        # DNS resolver (use local dnsmasq)
        resolver 127.0.0.1 valid=300s;
        resolver_timeout 5s;

        location / {
            add_header 'Access-Control-Allow-Origin' "*" always;
            add_header 'Access-Control-Allow-Headers' 'Accept,Authorization,Cache-Control,Content-Type,DNT,If-Modified-Since,Keep-Alive,Origin,User-Agent,X-Mx-ReqToken,X-Requested-With' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header Cache-Control 'no-store, no-cache, max-age=0, no-transform';
            if (\$request_method = OPTIONS) {
                add_header Access-Control-Allow-Credentials "true";
                return 204;
            }
        }

        location ~* ^.+\\.(?:css|cur|js|jpe?g|gif|htc|ico|png|html|xml|otf|ttf|eot|woff|woff2|svg)\$ {
            access_log off;
            expires 7d;  # Reduced from 365d to save RAM
            add_header Cache-Control public;
            add_header Vary Accept-Encoding;
            tcp_nodelay off;  # Allow buffering for static files
        }
    }
}
EOF

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
  printf "🌐 Access OpenSpeedTest at: ${CYAN}http://%s:%d${RESET}\n" "$INTERNAL_IP" "$PORT"
  printf "📊 Performance tuning: ${NGINX_WORKERS} workers, ${NGINX_CONNECTIONS} max connections\n"
  printf "📝 Error logs: ${ERROR_LOG} (errors only, rotated at 100KB)\n"

  prompt_persist
  cleanup_on_exit
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
