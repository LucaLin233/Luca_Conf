#!/bin/bash
# 从旧优化脚本迁移到新优化的一键脚本 - 修复版

# 检查root权限
[ "$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

echo "开始迁移优化设置..."

# 创建备份目录
BACKUP_DIR="/root/kernel_tuning_backup"
mkdir -p "$BACKUP_DIR"

# 复制现有备份到新目录
echo "保存现有的备份文件..."
if ls /etc/sysctl.conf.backup_* >/dev/null 2>&1; then
    cp /etc/sysctl.conf.backup_* "$BACKUP_DIR/"
    echo "- 已复制sysctl备份"
fi

if ls /etc/security/limits.conf.backup_* >/dev/null 2>&1; then
    cp /etc/security/limits.conf.backup_* "$BACKUP_DIR/"
    echo "- 已复制limits备份"
fi

# 备份当前配置
echo "备份当前的配置..."
cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.current_$(date +%Y%m%d_%H%M%S)"
cp /etc/security/limits.conf "$BACKUP_DIR/limits.conf.current_$(date +%Y%m%d_%H%M%S)"

# 应用新的limits配置
echo "更新limits配置..."
cat > /etc/security/limits.conf <<EOF
# 由内核优化迁移脚本更新 - $(date)
# 通用限制设置
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     655360
*     hard   nproc     655360
*     soft   core      unlimited
*     hard   core      unlimited
*     hard   memlock   unlimited
*     soft   memlock   unlimited

# root 用户限制设置
root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     655360
root     hard   nproc     655360
root     soft   core      unlimited
root     hard   core      unlimited
root     hard   memlock   unlimited
root     soft   memlock   unlimited
EOF

# 修复PAM配置
for pam_file in /etc/pam.d/common-session /etc/pam.d/login; do
    if [ -f "$pam_file" ]; then
        if ! grep -q "pam_limits.so" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
            echo "已添加 pam_limits 到 $pam_file"
        fi
    fi
done

# 定义更优的sysctl参数
declare -A sysctl_settings=(
    # 文件系统
    ["fs.file-max"]="1048576"
    ["fs.inotify.max_user_instances"]="8192"
    ["fs.inotify.max_user_watches"]="524288"
    
    # 网络核心
    ["net.core.somaxconn"]="32768"
    ["net.core.netdev_max_backlog"]="32768"
    ["net.core.rmem_max"]="16777216"
    ["net.core.wmem_max"]="16777216"
    ["net.core.rmem_default"]="262144"
    ["net.core.wmem_default"]="262144"
    
    # UDP 设置
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.udp_mem"]="65536 131072 262144"
    
    # TCP 缓冲
    ["net.ipv4.tcp_rmem"]="4096 87380 16777216"
    ["net.ipv4.tcp_wmem"]="4096 65536 16777216"
    ["net.ipv4.tcp_mem"]="786432 1048576 26777216"
    
    # TCP 连接优化
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.ip_local_port_range"]="1024 65000"
    ["net.ipv4.tcp_max_syn_backlog"]="32768"
    ["net.ipv4.tcp_max_tw_buckets"]="32768"
    ["net.ipv4.route.gc_timeout"]="100"
    ["net.ipv4.tcp_syn_retries"]="2"
    ["net.ipv4.tcp_synack_retries"]="2"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_max_orphans"]="262144"
    ["net.ipv4.tcp_no_metrics_save"]="1"
    
    # TCP 性能
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_window_scaling"]="1"
    ["net.ipv4.tcp_moderate_rcvbuf"]="1"
    ["net.ipv4.tcp_keepalive_time"]="600"
    ["net.ipv4.tcp_keepalive_intvl"]="60"
    ["net.ipv4.tcp_keepalive_probes"]="3"
    
    # 网络转发
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.forwarding"]="1"
    ["net.ipv4.conf.default.forwarding"]="1"
)

# 定义BBR相关参数
sysctl_settings["net.core.default_qdisc"]="fq"
sysctl_settings["net.ipv4.tcp_congestion_control"]="bbr"

# 更新sysctl配置
echo "更新sysctl配置..."
{
    echo "# 系统优化参数 - 迁移更新于 $(date)"
    echo "# 文件系统设置"
    for param in fs.file-max fs.inotify.max_user_instances fs.inotify.max_user_watches; do
        echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# 网络核心设置"
    for param in net.core.somaxconn net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max \
                 net.core.rmem_default net.core.wmem_default; do
        echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# UDP 设置"
    for param in net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min net.ipv4.udp_mem; do
        echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# TCP 缓冲设置"
    for param in net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem; do
        echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# TCP 连接优化"
    for param in net.ipv4.tcp_syncookies net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse \
                 net.ipv4.ip_local_port_range net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets \
                 net.ipv4.route.gc_timeout net.ipv4.tcp_syn_retries net.ipv4.tcp_synack_retries \
                 net.ipv4.tcp_timestamps net.ipv4.tcp_max_orphans net.ipv4.tcp_no_metrics_save; do
        [ -n "${sysctl_settings[$param]}" ] && echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# TCP 性能优化"
    for param in net.ipv4.tcp_sack net.ipv4.tcp_window_scaling \
                 net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_keepalive_time \
                 net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes; do
        [ -n "${sysctl_settings[$param]}" ] && echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# 网络转发设置"
    for param in net.ipv4.ip_forward \
                 net.ipv4.conf.all.forwarding net.ipv4.conf.default.forwarding; do
        [ -n "${sysctl_settings[$param]}" ] && echo "${param} = ${sysctl_settings[$param]}"
    done
    
    # 检查是否能启用BBR (不用bc)
    kernel_version=$(uname -r)
    major_version=$(echo "$kernel_version" | cut -d. -f1)
    minor_version=$(echo "$kernel_version" | cut -d. -f2)
    
    if [ "$major_version" -ge 4 ] && [ "$minor_version" -ge 9 ]; then
        # 如果可以加载模块或已加载
        if lsmod | grep -q "tcp_bbr" || modprobe tcp_bbr 2>/dev/null; then
            echo -e "\n# BBR 拥塞控制"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
            echo "已配置BBR拥塞控制"
        else
            echo "# 警告: BBR模块无法加载，但内核版本支持($kernel_version)"
        fi
    else
        echo "# 警告: 内核版本($kernel_version)不支持BBR，需要4.9+版本"
    fi
} > /etc/sysctl.conf

# 确保保留原始脚本中的一些特殊参数
if grep -q "net.ipv4.tcp_ecn" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_ecn = 0" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_frto" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_frto = 0" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_mtu_probing" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_mtu_probing = 0" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_rfc1337" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_rfc1337 = 0" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_fack" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_fack = 1" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_adv_win_scale" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_adv_win_scale = 1" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.tcp_notsent_lowat" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.tcp_notsent_lowat = 16384" >> /etc/sysctl.conf
fi

if grep -q "net.ipv4.conf.all.route_localnet" "$BACKUP_DIR/sysctl.conf.current_"*; then
    echo "net.ipv4.conf.all.route_localnet = 1" >> /etc/sysctl.conf
fi

# 创建新的恢复脚本
cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/bin/bash
# 自动生成的恢复脚本 - $(date)

# 检查root权限
[ "\$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

# 显示可用备份
echo "可用备份文件:"
ls -l "$BACKUP_DIR"/*.backup_* "$BACKUP_DIR"/*.current_*

# 询问用户选择哪个备份
echo "请选择要恢复的备份类型:"
echo "1) 恢复到最初的备份(优化前的状态)"
echo "2) 恢复到当前迁移前的状态"
read -p "请选择 [1/2]: " choice

case \$choice in
    1)
        # 恢复最早的备份
        SYSCTL_BACKUP=\$(ls -tr "$BACKUP_DIR"/sysctl.conf.backup_* 2>/dev/null | head -1)
        LIMITS_BACKUP=\$(ls -tr "$BACKUP_DIR"/limits.conf.backup_* 2>/dev/null | head -1)
        ;;
    2)
        # 恢复迁移前的备份
        SYSCTL_BACKUP=\$(ls -t "$BACKUP_DIR"/sysctl.conf.current_* 2>/dev/null | head -1)
        LIMITS_BACKUP=\$(ls -t "$BACKUP_DIR"/limits.conf.current_* 2>/dev/null | head -1)
        ;;
    *)
        echo "无效的选择，退出"
        exit 1
        ;;
esac

# 确认恢复
echo "将恢复以下文件:"
[ -n "\$SYSCTL_BACKUP" ] && echo "- \$SYSCTL_BACKUP → /etc/sysctl.conf"
[ -n "\$LIMITS_BACKUP" ] && echo "- \$LIMITS_BACKUP → /etc/security/limits.conf"

read -p "是否继续? [y/N]: " confirm
if [[ "\$confirm" != "y" && "\$confirm" != "Y" ]]; then
    echo "取消恢复"
    exit 0
fi

# 执行恢复
if [ -n "\$SYSCTL_BACKUP" ]; then
    cp "\$SYSCTL_BACKUP" /etc/sysctl.conf
    echo "已恢复: \$SYSCTL_BACKUP → /etc/sysctl.conf"
    sysctl -p
fi

if [ -n "\$LIMITS_BACKUP" ]; then
    cp "\$LIMITS_BACKUP" /etc/security/limits.conf
    echo "已恢复: \$LIMITS_BACKUP → /etc/security/limits.conf"
fi

echo "恢复完成，建议重启系统使所有更改生效"
EOF

chmod +x "$BACKUP_DIR/restore.sh"
echo "创建了新的恢复脚本: $BACKUP_DIR/restore.sh"

# 应用新的sysctl设置
echo "应用新的系统参数..."
if sysctl -p; then
    echo "所有系统参数应用成功"
else
    echo "注意: 部分参数可能未成功应用，请查看上面的错误信息"
fi

# 验证BBR是否已启用
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
    if [ "$current_cc" = "bbr" ]; then
        echo "BBR拥塞控制已成功启用"
    else
        echo "尝试手动启用BBR..."
        if modprobe tcp_bbr 2>/dev/null && \
           echo "fq" > /proc/sys/net/core/default_qdisc && \
           echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control; then
            echo "BBR拥塞控制已手动启用"
        else
            echo "警告: 无法启用BBR，可能需要更新内核或重启系统"
        fi
    fi
else
    echo "警告: 无法检测当前的拥塞控制算法"
fi

# 检查备份目录中的文件数量
backup_files=$(find "$BACKUP_DIR" -type f | wc -l)
echo "当前有 $backup_files 个文件在备份目录中"

# 最后显示一些系统参数
echo -e "\n当前系统参数状态:"
echo "文件描述符限制: $(ulimit -n)"
echo "进程数限制: $(ulimit -u)"
echo "TCP拥塞控制: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo '未知')"
echo "TCP缓冲区大小: $(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || echo '未知')"

echo -e "\n迁移完成!"
echo "所有备份文件保存在: $BACKUP_DIR"
echo "如需恢复，请运行: $BACKUP_DIR/restore.sh"
echo "建议重启系统以确保所有更改生效"
