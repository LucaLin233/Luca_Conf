#!/bin/bash
# Linux Kernel Optimization Reversion (Retain BBR and FQ)
# This script reverts most changes made by kernel_optimization.sh but retains BBR and FQ optimizations.

[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Restore original nproc.conf if it was renamed
if [ -e /etc/security/limits.d/*nproc.conf_bk ]; then
    rename nproc.conf_bk nproc.conf /etc/security/limits.d/*nproc.conf_bk
fi

# Remove the session required pam_limits.so line from /etc/pam.d/common-session
if [ -f /etc/pam.d/common-session ]; then
    sed -i '/session required pam_limits.so/d' /etc/pam.d/common-session
fi

# Restore the original /etc/security/limits.conf
sed -i '/# End of file/,$d' /etc/security/limits.conf

# Revert sysctl.conf changes but retain BBR and FQ settings
sed -i '/fs.file-max/d' /etc/sysctl.conf
sed -i '/fs.inotify.max_user_instances/d' /etc/sysctl.conf
sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/net.ipv4.udp_rmem_min/d' /etc/sysctl.conf
sed -i '/net.ipv4.udp_wmem_min/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_mem/d' /etc/sysctl.conf
sed -i '/net.ipv4.udp_mem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syncookies/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_tw_buckets/d' /etc/sysctl.conf
sed -i '/net.ipv4.route.gc_timeout/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syn_retries/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_synack_retries/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_timestamps/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_orphans/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_no_metrics_save/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_frto/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_rfc1337/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_sack/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fack/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_adv_win_scale/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_moderate_rcvbuf/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_keepalive_time/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.all.route_localnet/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.all.forwarding/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.default.forwarding/d' /etc/sysctl.conf

# Keep BBR and FQ settings
cat << EOF >> /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# Optionally, reload sysctl settings if necessary
sysctl -p

echo "System settings have been reverted to their original state, except for BBR and FQ optimizations."
