#!/bin/bash
# Linux 内核优化脚本
# 支持的系统: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+, AlmaLinux 9+

# 检查是否具有 root 权限
[ "$(id -u)" != "0" ] && { echo "错误: 必须使用 root 权限运行此脚本"; exit 1; }

# 检查系统兼容性
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian)
            [ "${VERSION_ID%%.*}" -ge 12 ] || echo "警告: 此脚本在 Debian 12 及更高版本上测试过"
            ;;
        almalinux)
            [ "${VERSION_ID%%.*}" -ge 9 ] || echo "警告: 此脚本在 AlmaLinux 9 及更高版本上测试过"
            ;;
        *)
            echo "警告: 未经测试的发行版: $ID"
            ;;
    esac
fi

# 检查必需的文件
[ ! -f /etc/security/limits.conf ] && { echo "错误: 未找到 limits.conf"; exit 1; }
[ ! -f /etc/sysctl.conf ] && { echo "错误: 未找到 sysctl.conf"; exit 1; }

# 创建配置文件备份
backup_date=$(date +%Y%m%d_%H%M%S)
cp /etc/sysctl.conf "/etc/sysctl.conf.backup_${backup_date}"
cp /etc/security/limits.conf "/etc/security/limits.conf.backup_${backup_date}"

# 配置 PAM limits
[ -e /etc/security/limits.d/*nproc.conf ] && rename nproc.conf nproc.conf_bk /etc/security/limits.d/*nproc.conf
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session

# 配置系统限制
sed -i '/^# End of file/,$d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
# 文件结束
# 设置所有用户的限制
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     soft   core      1048576
*     hard   core      1048576
*     hard   memlock   unlimited
*     soft   memlock   unlimited

# 设置 root 用户的限制
root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     soft   core      1048576
root     hard   core      1048576
root     hard   memlock   unlimited
root     soft   memlock   unlimited
EOF

# 清理旧的 sysctl 设置
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

# 添加新的 sysctl 设置
cat >> /etc/sysctl.conf << EOF
# 文件系统最大打开文件数
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192

# 网络核心参数
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# UDP 缓冲区设置
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP 缓冲区设置
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_mem = 65536 131072 262144

# TCP 连接优化
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

# TCP 性能优化
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

# 网络转发设置
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
EOF

# 配置 BBR 拥塞控制
if ! grep -q "tcp_bbr" /proc/modules; then
    modprobe tcp_bbr 2>/dev/null || {
        echo "警告: 无法加载 BBR 模块"
    }
fi

if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
else
    echo "警告: 此系统不支持 BBR"
fi

# 应用更改并验证
echo "正在应用新设置..."
sysctl -p 2>&1 | grep -i error && {
    echo "错误: 部分 sysctl 参数应用失败"
    exit 1
} || echo "系统参数应用成功"

# 验证限制
ulimit -n | grep "1048576" || echo "警告: 文件描述符限制可能需要重新登录后才能生效"

# 完成信息
echo "内核优化完成"
echo "已创建备份文件:"
echo "- /etc/sysctl.conf.backup_${backup_date}"
echo "- /etc/security/limits.conf.backup_${backup_date}"
echo "请重启系统以确保所有更改生效"
echo "由 apad.pro 提供支持"
