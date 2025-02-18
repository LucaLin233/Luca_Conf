#!/bin/bash
# Linux Kernel Optimization
# Supported platforms: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+, AlmaLinux 9+
# Check root privileges
[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Check system compatibility
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian)
            [ "${VERSION_ID%%.*}" -ge 12 ] || echo "Warning: This script is tested on Debian 12 and later"
            ;;
        almalinux)
            [ "${VERSION_ID%%.*}" -ge 9 ] || echo "Warning: This script is tested on AlmaLinux 9 and later"
            ;;
        *)
            echo "Warning: Untested distribution: $ID"
            ;;
    esac
fi

# Check required files
[ ! -f /etc/security/limits.conf ] && { echo "Error: limits.conf not found"; exit 1; }
[ ! -f /etc/sysctl.conf ] && { echo "Error: sysctl.conf not found"; exit 1; }

# Create backups
backup_date=$(date +%Y%m%d_%H%M%S)
cp /etc/sysctl.conf "/etc/sysctl.conf.backup_${backup_date}"
cp /etc/security/limits.conf "/etc/security/limits.conf.backup_${backup_date}"

# Configure PAM limits
[ -e /etc/security/limits.d/*nproc.conf ] && rename nproc.conf nproc.conf_bk /etc/security/limits.d/*nproc.conf
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session

# Configure limits.conf
sed -i '/^# End of file/,$d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
# End of file
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     soft   core      1048576
*     hard   core      1048576
*     hard   memlock   unlimited
*     soft   memlock   unlimited

root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     soft   core      1048576
root     hard   core      1048576
root     hard   memlock   unlimited
root     soft   memlock   unlimited
EOF

# Clean old sysctl settings
declare -a params=(
    "fs.file-max"
    "fs.inotify.max_user_instances"
    "net.core.somaxconn"
    "net.core.netdev_max_backlog"
    "net.core.rmem_max"
    "net.core.wmem_max"
    "net.ipv4.udp_rmem_min"
    "net.ipv4.udp_wmem_min"
    "net.ipv4.tcp_rmem"
    "net.ipv4.tcp_wmem"
    "net.ipv4.tcp_mem"
    "net.ipv4.udp_mem"
    "net.ipv4.tcp_syncookies"
    "net.ipv4.tcp_fin_timeout"
    "net.ipv4.tcp_tw_reuse"
    "net.ipv4.ip_local_port_range"
    "net.ipv4.tcp_max_syn_backlog"
    "net.ipv4.tcp_max_tw_buckets"
    "net.ipv4.route.gc_timeout"
    "net.ipv4.tcp_syn_retries"
    "net.ipv4.tcp_synack_retries"
    "net.ipv4.tcp_timestamps"
    "net.ipv4.tcp_max_orphans"
    "net.ipv4.tcp_no_metrics_save"
    "net.ipv4.tcp_ecn"
    "net.ipv4.tcp_frto"
    "net.ipv4.tcp_mtu_probing"
    "net.ipv4.tcp_rfc1337"
    "net.ipv4.tcp_sack"
    "net.ipv4.tcp_fack"
    "net.ipv4.tcp_window_scaling"
    "net.ipv4.tcp_adv_win_scale"
    "net.ipv4.tcp_moderate_rcvbuf"
    "net.ipv4.tcp_keepalive_time"
    "net.ipv4.tcp_notsent_lowat"
    "net.ipv4.conf.all.route_localnet"
    "net.ipv4.ip_forward"
    "net.ipv4.conf.all.forwarding"
    "net.ipv4.conf.default.forwarding"
    "net.core.default_qdisc"
    "net.ipv4.tcp_congestion_control"
)

for param in "${params[@]}"; do
    sed -i "/${param}/d" /etc/sysctl.conf
done

# Add new sysctl settings
cat >> /etc/sysctl.conf << EOF
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
EOF

# Configure BBR
if ! grep -q "tcp_bbr" /proc/modules; then
    modprobe tcp_bbr 2>/dev/null || {
        echo "Warning: Unable to load BBR module"
    }
fi

if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
else
    echo "Warning: BBR is not available on this system"
fi

# Apply changes and verify
echo "Applying new settings..."
sysctl -p 2>&1 | grep -i error && {
    echo "Error: Some sysctl parameters failed to apply"
    exit 1
} || echo "Sysctl parameters applied successfully"

# Verify limits
ulimit -n | grep "1048576" || echo "Warning: File descriptor limits may not be applied until next login"

# Final message
echo "Kernel optimization completed successfully"
echo "Backup files created:"
echo "- /etc/sysctl.conf.backup_${backup_date}"
echo "- /etc/security/limits.conf.backup_${backup_date}"
echo "Please reboot your system to ensure all changes take effect"
echo "Powered by apad.pro"
