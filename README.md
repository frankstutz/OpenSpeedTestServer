# OpenSpeedTest Installer for NGINX on GL.iNet Routers

```
   _____ _          _ _   _      _   
  / ____| |        (_) \ | |    | |  
 | |  __| |  ______ _|  \| | ___| |_ 
 | | |_ | | |______| | . ` |/ _ \ __|
 | |__| | |____    | | |\  |  __/ |_ 
  \_____|______|   |_|_| \_|\___|\__|

         OpenSpeedTest for GL-iNet

```
> 📡 Production-ready OpenSpeedTest deployment for OpenWRT-based routers with optimized NGINX configuration

> **Note**: This is a fork of [phantasm22/OpenSpeedTestServer](https://github.com/phantasm22/OpenSpeedTestServer) with enhanced performance optimizations, error handling, and resource management for embedded devices.

---

## Features

### Core Functionality
- 📦 Installs and configures [NGINX](https://nginx.org/) to run [OpenSpeedTest](https://openspeedtest.com/)
- 🔧 Custom NGINX configuration that avoids conflicts with the GL.iNet web UI
- 📁 Installs to `/www2`, with automatic detection of available storage space
- 🔗 Supports symlinking to external drives (e.g. SD cards or USB) if internal space is insufficient
- ⬆️ Supports persistence after firmware updates via `/etc/sysupgrade.conf`
- 🧹 Clean uninstall that removes configs, startup scripts, and any symlinked storage
- ⤵️ Automatic self-update with version checking

### Performance & Optimization (NEW!)
- 🚀 **Auto-tuned for embedded devices** - Detects CPU cores and RAM, adjusts NGINX workers and connections
- ⚡ **Optimized for low-resource routers** - Conservative memory usage and buffer sizes
- 📊 **Hardware-aware configuration**:
  - <128MB RAM: 1 worker, 256 connections
  - <256MB RAM: 1 worker, 512 connections
  - 256MB+ RAM: 2 workers, 1024 connections
- 🔄 **Connection timeout protection** - Prevents resource exhaustion from hung connections
- 💾 **Minimal disk I/O** - No access logs, error-only logging

### Reliability & Error Handling (NEW!)
- 🛡️ **Robust error handling** - Automatic cleanup on failures
- ✅ **Configuration validation** - Tests NGINX config before applying
- 🔄 **Automatic rollback** - Restores previous config if new one fails
- 🔒 **Port conflict detection** - Checks port availability before installation
- 📥 **Download validation** - Verifies file integrity after downloads
- 🔐 **Lock file protection** - Prevents concurrent installations

### Service Management (NEW!)
- 🔁 **procd support** - Modern OpenWrt process supervision with auto-restart
- 🔄 **Traditional init.d fallback** - Compatible with older OpenWrt versions
- 🩺 **Enhanced diagnostics** - System resource monitoring, config validation, log preview
- 📝 **Aggressive log rotation** - Errors only, auto-rotate at 100KB, 2-day retention

### Developer Features (NEW!)
- 🐛 **Debug mode** - Detailed execution logs for troubleshooting
- 📢 **Verbose mode** - Additional informational output
- 🎛️ **Custom port support** - Override default port 8888
- 🧪 **Interactive CLI** with confirmations and safe prompts

### SSL/HTTPS Support (NEW!)
- 🔒 **Let's Encrypt integration** - Automatic SSL certificate generation
- 🤖 **acme.sh client** - Industry-standard ACME protocol
- 🔄 **Auto-renewal** - Daily certificate expiry checks
- 🔐 **TLS 1.2/1.3** - Modern encryption standards
- ♻️ **HTTP → HTTPS redirect** - Automatic upgrade to secure connection
- 📜 **Certificate persistence** - Survives firmware updates

### Tested Devices
- 🧪 GL-BE9300, GL-BE3600, GL-MT3000, GL-MT1300 (with SD card)
- ✅ Any OpenWrt-based router with 64MB+ free space

### License
- 🆓 Licensed under GPLv3

---

## 🚀 Quick Start

### 1. SSH into your router:

```bash
ssh root@192.168.8.1
```

### 2. Download and run the installer:

```bash
wget -O install_openspeedtest.sh https://raw.githubusercontent.com/frankstutz/OpenSpeedTestServer/main/install_openspeedtest.sh && chmod +x install_openspeedtest.sh
./install_openspeedtest.sh
```

### 3. Follow the interactive menu to install, diagnose, or uninstall.

---

## 🌐 Access the Speed Test

After installation, open:
```
http://<router-ip>:8888
```

Example:
```
http://192.168.8.1:8888
```

---

## ⚙️ Advanced Usage

### Environment Variables

Customize installation behavior with environment variables:

```bash
# Enable debug mode for troubleshooting
DEBUG=1 ./install_openspeedtest.sh

# Enable verbose output
VERBOSE=1 ./install_openspeedtest.sh

# Use custom port (instead of default 8888)
PORT=9999 ./install_openspeedtest.sh

# Combine options
DEBUG=1 VERBOSE=1 PORT=9090 ./install_openspeedtest.sh
```

### Custom Port Configuration

If port 8888 is already in use, the script will:
1. Detect the conflict
2. Prompt you to enter a different port
3. Validate the new port (1024-65535)
4. Retry until a free port is found

You can also set a custom port before installation:
```bash
PORT=9999 ./install_openspeedtest.sh
```

### Cancelling Installation (Ctrl-C)

You can safely cancel the installation at any time by pressing **Ctrl-C**. The script will:

1. **Immediately stop** all background processes (downloads, extraction, etc.)
2. **Clean up** partial installations:
   - Stop any NGINX processes started during installation
   - Remove incomplete downloads
   - Restore previous configuration (if it existed)
3. **Release resources** (lock files, temporary files)
4. **Exit gracefully** with proper cleanup

Example output when cancelled:
```
⚠️  Installation interrupted by user (Ctrl-C)
🧹 Cleaning up partial installation...
✅ Restored previous configuration
✅ Cleanup completed
Installation cancelled. Exiting.
```

**Note**: The interrupt handler ensures your system is left in a clean state even if you cancel mid-installation.

### SSL/HTTPS with Let's Encrypt

The installer supports automatic SSL certificate generation using Let's Encrypt with **three validation methods**:

#### Validation Methods:

**1. HTTP-01 Challenge** (Traditional - requires public IP)
- **Prerequisites:**
  - Valid domain name pointing to your router's public IP
  - Port 80 accessible from the internet
  - Port forwarding configured on your router if behind NAT

**2. DNS-01 Challenge** (Recommended - NO public IP required) ✨
- **Prerequisites:**
  - Valid domain name
  - DNS API access (Cloudflare, AWS Route53, etc.)
  - NO public IP or port forwarding needed!
  
- **Supported DNS Providers:**
  - ☁️ Cloudflare (recommended - easy API setup)
  - 🌐 AWS Route53
  - 🔵 Google Cloud DNS
  - 💧 DigitalOcean
  - 🅽 Namecheap
  - 🅶 GoDaddy
  - 🦆 Duck DNS (FREE!)
  - And 100+ more via acme.sh

**3. Manual DNS** (For testing or manual management)
- Script pauses and shows TXT record to create
- Works without API access
- Suitable for one-time setup

#### During Installation:

When prompted "Do you want to enable SSL/HTTPS with Let's Encrypt?":
1. Answer **Y** to enable SSL
2. Enter your fully qualified domain name (e.g., `speedtest.example.com`)
3. **Choose validation method:**
   - Option 1: HTTP-01 (requires public IP + port 80)
   - Option 2: DNS-01 (works without public IP!)
   - Option 3: Manual DNS (for testing)
4. If DNS-01: Select your DNS provider and enter API credentials
5. Confirm the setup

#### Example: DNS-01 with Cloudflare (No Public IP Needed!)

```
🔒 Do you want to enable SSL/HTTPS with Let's Encrypt? [y/N]: y
📝 Enter your fully qualified domain name (FQDN): speedtest.example.com

🔐 Choose certificate validation method:
1️⃣  HTTP-01 (requires public IP and port 80 accessible)
2️⃣  DNS-01 (works without public IP, requires DNS API)
3️⃣  Manual DNS (for testing or manual DNS record management)
Choose [1-3]: 2

🌐 Select your DNS provider:
1️⃣  Cloudflare (recommended)
Choose [1-9]: 1

📝 Cloudflare Configuration:
   Visit: https://dash.cloudflare.com/profile/api-tokens
   Create token with Zone:DNS:Edit permissions

Enter Cloudflare API Token: [paste your token]
✅ DNS provider configured: dns_cf

🌐 Using DNS-01 validation (dns_cf)
✅ No public IP or open ports required!
```

The installer will:
1. Install `acme.sh` (Let's Encrypt client)
2. Request and validate certificate using your chosen method
3. Configure NGINX with SSL on port 8443
4. Set up HTTP → HTTPS redirect on port 80
5. Configure automatic certificate renewal (daily check)

#### SSL Configuration:
```bash
# Access after SSL setup
https://speedtest.example.com:8443

# HTTP automatically redirects to HTTPS (if port 80 available)
http://speedtest.example.com → https://speedtest.example.com:8443
```

#### Certificate Renewal:
- **Automatic**: Cron job checks daily, renews if within 60 days of expiry
- **DNS-01 renewals**: Use saved API credentials (no manual intervention)
- **Manual renewal**: `/root/.acme.sh/acme.sh --cron --force`
- **Certificate location**: `/etc/nginx/ssl/`

#### Getting DNS API Credentials:

**Cloudflare (Easiest):**
1. Login to Cloudflare dashboard
2. Go to: Profile → API Tokens
3. Create token with "Zone:DNS:Edit" permission
4. Copy token and paste during installation

**Duck DNS (Free!):**
1. Visit https://www.duckdns.org/
2. Sign in with social account
3. Get your free subdomain (e.g., `myspeed.duckdns.org`)
4. Copy your token from the dashboard

**AWS Route53:**
1. Create IAM user with Route53 permissions
2. Generate access key ID and secret
3. Enter both during installation

#### Troubleshooting SSL:
If certificate issuance fails:
- **HTTP-01**: Verify domain DNS points to your router's public IP, ensure port 80 is open
- **DNS-01**: Check API credentials are correct and have sufficient permissions
- **Manual DNS**: Verify TXT record was created correctly, wait 5-30 min for DNS propagation
- Installation will continue with HTTP only if SSL fails

---

## 🔍 Menu Options

When running the script, choose from:

1. **Install OpenSpeedTest** – Full installation with hardware detection and optimization
2. **Run diagnostics** – Comprehensive system check including:
   - NGINX process status
   - Port availability
   - Configuration validation
   - System resources (CPU, RAM, disk)
   - Recent error logs
3. **Uninstall everything** – Complete removal of all components
4. **Check for update** – Manually check for script updates
5. **Exit** – Quit the installer

---

## 🎯 Performance Optimizations

The installer automatically optimizes NGINX based on your router's hardware:

### Automatic Hardware Detection
- Reads CPU cores from `/proc/cpuinfo`
- Reads total RAM from `/proc/meminfo`
- Configures NGINX workers and connections accordingly

### NGINX Tuning Applied

| Router RAM | Worker Processes | Max Connections | File Descriptors |
|------------|------------------|-----------------|------------------|
| < 128MB    | 1                | 256             | 4096             |
| < 256MB    | 1                | 512             | 4096             |
| 256MB+     | 2                | 1024            | 4096             |

### Additional Optimizations
- **epoll**: Efficient Linux event handling
- **Connection timeouts**: 30s to prevent hangs
- **Keepalive**: 30s timeout, 50 request limit
- **Buffer sizes**: Minimized (8k body, 1k headers)
- **Client body size**: 1GB (realistic for speed tests)
- **Static files**: 7-day cache
- **Compression**: Disabled (speed tests shouldn't compress)
- **Reset timedout connections**: Enabled

---

## 📝 Log Management

### Aggressive Log Rotation

To conserve disk space on embedded devices:

- **Error-only logging** at `crit` level (critical errors only)
- **No access logs** - Completely disabled
- **Automatic rotation** when log exceeds 100KB
- **2-day retention** - Old logs auto-deleted
- **Cron-based** - Daily check via `/etc/cron.daily/nginx_openspeedtest_logrotate`
- **Signal-based reload** - NGINX reopens logs without restart (USR1 signal)

### Log Locations
- Error log: `/var/log/nginx_openspeedtest_error.log`
- Rotated logs: `/var/log/nginx_openspeedtest_error.log.1`

### Manual Log Rotation
```bash
# Force log rotation
/etc/cron.daily/nginx_openspeedtest_logrotate

# View current errors
tail -20 /var/log/nginx_openspeedtest_error.log

# Clear logs manually
> /var/log/nginx_openspeedtest_error.log
```

---

## 🔧 Service Management

### procd (Modern OpenWrt)

If your router uses procd (most modern GL.iNet routers):

```bash
# Start service
/etc/init.d/nginx_speedtest start

# Stop service
/etc/init.d/nginx_speedtest stop

# Restart service
/etc/init.d/nginx_speedtest restart

# Reload configuration (no downtime)
/etc/init.d/nginx_speedtest reload

# Enable auto-start on boot
/etc/init.d/nginx_speedtest enable

# Disable auto-start
/etc/init.d/nginx_speedtest disable

# Check status
/etc/init.d/nginx_speedtest status
```

**procd features:**
- Auto-restart on crashes
- Respawn limits (3600s threshold, 5s timeout)
- Daemon mode with proper supervision
- Graceful reload with config validation

### Traditional init.d (Older OpenWrt)

Same commands as above, but without auto-restart features.

---

## 🩺 Diagnostics & Troubleshooting

### Run Diagnostics

Option 2 in the menu provides comprehensive diagnostics:

```
🔍 Running OpenSpeedTest diagnostics...

✅ OpenSpeedTest NGINX process is running (PID: 12345)
✅ Port 8888 is open and listening on 192.168.8.1
🌐 You can access OpenSpeedTest at: http://192.168.8.1:8888
✅ Configuration file exists: /etc/nginx/nginx_openspeedtest.conf
✅ Configuration is valid
📝 Error log: /var/log/nginx_openspeedtest_error.log (2.5K)

💻 System Resources:
   CPU cores: 4
   Total RAM: 512MB
   Free RAM: 234MB
   Disk space at /www2: 45MB free
```

### Common Issues

#### Port Already in Use
**Symptom**: "Port 8888 already in use"
**Solution**: 
```bash
# Find what's using the port
netstat -tuln | grep 8888

# Use custom port
PORT=9999 ./install_openspeedtest.sh
```

#### NGINX Won't Start
**Symptom**: NGINX starts but immediately stops
**Solution**:
```bash
# Check configuration
nginx -t -c /etc/nginx/nginx_openspeedtest.conf

# View error log
tail -50 /var/log/nginx_openspeedtest_error.log

# Check for port conflicts
netstat -tuln | grep 8888
```

#### Insufficient Space
**Symptom**: "Not enough free space"
**Solution**: 
- Use external drive (script will prompt)
- Free up space: `opkg list-installed` and remove unused packages
- Required: 64MB free space

#### Download Failures
**Symptom**: "Download failed or timed out"
**Solution**:
```bash
# Check internet connectivity
ping -c 3 github.com

# Try GL.iNet mirror during installation (option 2)

# Manual download with debug
DEBUG=1 ./install_openspeedtest.sh
```

#### Configuration Validation Failed
**Symptom**: "Invalid NGINX configuration"
**Solution**:
- Script automatically restores backup
- Check error details in output
- Verify port is not already in use

#### SSL Certificate Issuance Failed
**Symptom**: "Failed to issue certificate"
**Solutions**:

1. **Verify DNS**:
```bash
# Check if domain resolves to your public IP
nslookup speedtest.example.com
dig speedtest.example.com

# Get your public IP
curl ifconfig.me
```

2. **Check Port 80 Access**:
```bash
# From external network, test port 80
curl -I http://your-domain.com

# Check if port 80 is listening
netstat -tuln | grep :80
```

3. **Firewall Rules**:
```bash
# Check OpenWrt firewall (if applicable)
iptables -L -n | grep 80

# Allow HTTP for Let's Encrypt validation
uci set firewall.http=rule
uci set firewall.http.name='Allow-HTTP'
uci set firewall.http.src='wan'
uci set firewall.http.dest_port='80'
uci set firewall.http.proto='tcp'
uci set firewall.http.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
```

4. **Manual Certificate Request**:
```bash
# Test acme.sh manually
/root/.acme.sh/acme.sh --issue --standalone -d your-domain.com --debug

# Check acme.sh logs
cat /root/.acme.sh/acme.sh.log
```

5. **Use DNS Challenge (Alternative)**:
```bash
# If port 80 is unavailable, use DNS challenge
/root/.acme.sh/acme.sh --issue --dns -d your-domain.com
```

**Note**: If SSL fails, installation continues with HTTP only. You can manually configure SSL later.

#### SSL Certificate Not Renewing
**Symptom**: Certificate expired
**Solution**:
```bash
# Check renewal cron job
crontab -l | grep acme

# Force renewal
/root/.acme.sh/acme.sh --cron --force

# Check certificate expiry
/root/.acme.sh/acme.sh --list

# Reload NGINX after renewal
/etc/init.d/nginx_speedtest reload
```

### Debug Mode

Enable detailed logging:
```bash
DEBUG=1 ./install_openspeedtest.sh
```

Output includes:
- Function entry/exit
- Variable values
- Download details
- Configuration checks
- Cleanup operations

### Manual Verification

```bash
# Check if NGINX is running
ps | grep nginx

# Check PID file
cat /var/run/nginx_OpenSpeedTest.pid

# Test configuration
nginx -t -c /etc/nginx/nginx_openspeedtest.conf

# Check port listener
netstat -tuln | grep 8888

# View NGINX config
cat /etc/nginx/nginx_openspeedtest.conf

# Check disk space
df -h /www2

# View system resources
free -m
cat /proc/cpuinfo | grep processor
```

---

## 🧹 Uninstallation

### Interactive Uninstall

Re-run the script and choose **option 3: Uninstall everything**.

This removes:
- OpenSpeedTest files (`/www2`)
- NGINX configuration
- Startup scripts
- Log files and rotated logs
- Persistence entries from `/etc/sysupgrade.conf`
- Symlinks (if external drive was used)

### Manual Uninstall

If the script is unavailable:

```bash
# Stop service
/etc/init.d/nginx_speedtest stop
/etc/init.d/nginx_speedtest disable

# Remove files
rm -rf /www2/Speed-Test-main
rm -f /etc/nginx/nginx_openspeedtest.conf
rm -f /etc/nginx/nginx_openspeedtest.conf.backup
rm -f /etc/init.d/nginx_speedtest
rm -f /etc/cron.daily/nginx_openspeedtest_logrotate
rm -f /var/log/nginx_openspeedtest_error.log*
rm -f /var/run/nginx_OpenSpeedTest.pid

# Remove symlink (if used external drive)
rm -f /www2

# Remove persistence entries
sed -i '/www2/d' /etc/sysupgrade.conf
sed -i '/nginx_speedtest/d' /etc/sysupgrade.conf
sed -i '/nginx_openspeedtest/d' /etc/sysupgrade.conf
```

---

## 🔄 Persistence Through Firmware Updates

When you choose to enable persistence during installation, the following paths are added to `/etc/sysupgrade.conf`:

- `/www2` (or custom install directory)
- `/etc/nginx/nginx_openspeedtest.conf`
- `/etc/init.d/nginx_speedtest`
- `/etc/cron.daily/nginx_openspeedtest_logrotate`
- All rc.d symlinks for the service

This ensures OpenSpeedTest survives OpenWrt firmware upgrades.

**Note**: External drive installations (symlinked to `/www2`) are automatically preserved.

---

## 🔐 Security Considerations

### Network Security
- OpenSpeedTest runs on LAN only by default (port 8888)
- No external exposure unless you configure port forwarding
- CORS headers allow cross-origin requests (required for speed test)

### File Permissions
- NGINX runs as `nobody:nogroup` (unprivileged)
- Configuration files: `root:root` with 644 permissions
- Scripts: `root:root` with 755 permissions

### Recommendations
- Keep router firmware updated
- Use strong SSH passwords
- Don't expose port 8888 to WAN
- Run diagnostics after installation to verify

---

## 🛠️ Development & Contributions

### Contributing

Contributions welcome! Please:
1. Test on actual GL.iNet/OpenWrt hardware
2. Verify compatibility with different router models
3. Include debug output for any issues
4. Follow existing code style

### Reporting Issues

When reporting issues, include:
```bash
# Run with debug mode
DEBUG=1 VERBOSE=1 ./install_openspeedtest.sh

# Include diagnostics output (option 2)

# Include system info
cat /etc/openwrt_release
free -m
df -h
```

### Version History

- **2025-12-23**: Major rewrite with performance optimizations, error handling, procd support, log rotation
- **2025-11-13**: Initial release

---

## 📚 Technical Details

### Files Created/Modified

| Path | Purpose |
|------|---------|
| `/www2/Speed-Test-main/` | OpenSpeedTest application files |
| `/etc/nginx/nginx_openspeedtest.conf` | NGINX configuration (auto-tuned) |
| `/etc/init.d/nginx_speedtest` | Service startup script (procd or init.d) |
| `/etc/cron.daily/nginx_openspeedtest_logrotate` | Automatic log rotation |
| `/var/log/nginx_openspeedtest_error.log` | Error log (critical only) |
| `/var/run/nginx_OpenSpeedTest.pid` | NGINX process ID |
| `/etc/sysupgrade.conf` | Persistence configuration (if enabled) |

### Dependencies Installed

- `nginx-ssl` - NGINX with SSL support
- `curl` - HTTP client
- `wget` - File downloader
- `unzip` - Archive extraction
- `coreutils-timeout` - Command timeouts

### Resource Usage

Typical resource consumption on a 512MB RAM router:
- **RAM**: 10-20MB for NGINX workers
- **Disk**: ~40-50MB for OpenSpeedTest files
- **CPU**: <5% idle, scales with active speed tests

---

## 🧑 Authors

**frankstutz** - Current maintainer and performance optimizations

**phantasm22** - [Original author](https://github.com/phantasm22/OpenSpeedTestServer)

This project is a fork of [phantasm22/OpenSpeedTestServer](https://github.com/phantasm22/OpenSpeedTestServer) with significant enhancements for production use on resource-constrained embedded devices.

Contributions, suggestions, and PRs welcome!

---

## 📜 License

This project is licensed under the GNU GPL v3.0 License - see the [LICENSE](https://www.gnu.org/licenses/gpl-3.0.en.html) file for details.

---

## 🙏 Acknowledgments

- [OpenSpeedTest](https://openspeedtest.com/) - The speed test application
- [NGINX](https://nginx.org/) - High-performance web server
- [OpenWrt](https://openwrt.org/) - Linux distribution for embedded devices
- [GL.iNet](https://www.gl-inet.com/) - Router hardware and firmware
