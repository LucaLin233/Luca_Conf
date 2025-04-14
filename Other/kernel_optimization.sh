#!/bin/bash
# Linux 内核优化脚本
# 支持的系统: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+, AlmaLinux 9+

# 检查是否具有 root 权限
[ "$(id -u)" != "0" ] && { echo "错误: 必须使用 root 权限运行此脚本"; exit 1; }

# 定义备份目录
BACKUP_DIR="/root/kernel_tuning_backup"
mkdir -p "$BACKUP_DIR"

# 创建备份函数
backup_file() {
    local file="$1"
    local filename=$(basename "$file")
    local backup="${BACKUP_DIR}/${filename}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # 确保源文件存在
    if [ ! -f "$file" ]; then
        echo "警告: 文件 $file 不存在，跳过备份"
        return 1
    fi
    
    cp "$file" "$backup" && echo "已备份: $backup"
}

# 检查系统兼容性
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu)
            [ "${VERSION_ID%%.*}" -lt 9 ] && echo "警告: 此脚本在 ${ID^} 9+ 上测试过"
            ;;
        centos|rhel|almalinux|rocky)
            [ "${VERSION_ID%%.*}" -lt 7 ] && echo "警告: 此脚本在 ${ID^} 7+ 上测试过"
            ;;
        *)
            echo "警告: 未经测试的发行版: $ID $VERSION_ID，继续执行风险自负"
            ;;
    esac
else
    echo "警告: 无法识别系统类型，继续执行风险自负"
fi

# 检查并备份关键文件
echo "备份当前配置..."
FILES_TO_BACKUP=(
    "/etc/security/limits.conf"
    "/etc/sysctl.conf"
    "/etc/pam.d/common-session"
    "/etc/pam.d/login"
)

for file in "${FILES_TO_BACKUP[@]}"; do
    backup_file "$file"
done

# 记录备份信息到日志
echo "备份完成时间: $(date)" > "$BACKUP_DIR/backup_info.log"

# 配置 PAM limits
if [ -d /etc/security/limits.d ]; then
    for nproc_conf in /etc/security/limits.d/*nproc.conf; do
        if [ -f "$nproc_conf" ]; then
            mv "$nproc_conf" "${nproc_conf}_bk"
            echo "已备份并禁用: $nproc_conf"
        fi
    done
fi

# 确保PAM使用limits
for pam_file in /etc/pam.d/common-session /etc/pam.d/login; do
    if [ -f "$pam_file" ]; then
        if ! grep -q "pam_limits.so" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
            echo "已添加 pam_limits 到 $pam_file"
        fi
    fi
done

# 配置系统限制
cat > /etc/security/limits.conf <<EOF
# 由内核优化脚本生成 - $(date)
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

echo "系统限制配置完成"

# 清理和设置 sysctl 参数
# 使用数组整合相关参数并简化维护
declare -A sysctl_settings=(
    # 文件系统
    ["fs.file-max"]="1048576"
    ["fs.inotify.max_user_instances"]="8192"
    ["fs.inotify.max_user_watches"]="524288"
    
    # 网络核心
    ["net.core.somaxconn"]="32768"
    ["net.core.netdev_max_backlog"]="32768"
    ["net.core.rmem_max"]="16777216"  # 更合理的值
    ["net.core.wmem_max"]="16777216"  # 更合理的值
    ["net.core.rmem_default"]="262144"
    ["net.core.wmem_default"]="262144"
    
    # UDP 设置
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.udp_mem"]="65536 131072 262144"
    
    # TCP 缓冲
    ["net.ipv4.tcp_rmem"]="4096 87380 16777216"  # 更合理的最大值
    ["net.ipv4.tcp_wmem"]="4096 65536 16777216"  # 更合理的最大值
    ["net.ipv4.tcp_mem"]="786432 1048576 26777216"
    
    # TCP 连接优化
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.ip_local_port_range"]="1024 65000"
    ["net.ipv4.tcp_max_syn_backlog"]="32768"
    ["net.ipv4.tcp_max_tw_buckets"]="32768"
    ["net.ipv4.route.gc_timeout"]="100"
    ["net.ipv4.tcp_syn_retries"]="2"  # 更合理，避免连接问题
    ["net.ipv4.tcp_synack_retries"]="2"  # 更合理
    ["net.ipv4.tcp_timestamps"]="1"  # 保持开启，有助于防止序列号攻击
    ["net.ipv4.tcp_max_orphans"]="262144"
    ["net.ipv4.tcp_no_metrics_save"]="1"
    
    # TCP 性能
    ["net.ipv4.tcp_ecn"]="0"
    ["net.ipv4.tcp_frto"]="0" 
    ["net.ipv4.tcp_mtu_probing"]="0"
    ["net.ipv4.tcp_rfc1337"]="0"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_fack"]="1"
    ["net.ipv4.tcp_window_scaling"]="1"
    ["net.ipv4.tcp_adv_win_scale"]="1"
    ["net.ipv4.tcp_moderate_rcvbuf"]="1"
    ["net.ipv4.tcp_keepalive_time"]="600"
    ["net.ipv4.tcp_keepalive_intvl"]="60"  # 新增
    ["net.ipv4.tcp_keepalive_probes"]="3"  # 新增
    ["net.ipv4.tcp_notsent_lowat"]="16384"
    
    # 网络转发
    ["net.ipv4.conf.all.route_localnet"]="1"
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.forwarding"]="1"
    ["net.ipv4.conf.default.forwarding"]="1"
)

# 清理现有配置
> /etc/sysctl.conf

# 添加新配置，按分类添加
{
    echo "# 系统优化参数 - $(date)"
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
    for param in net.ipv4.tcp_ecn net.ipv4.tcp_frto net.ipv4.tcp_mtu_probing \
                 net.ipv4.tcp_rfc1337 net.ipv4.tcp_sack net.ipv4.tcp_fack \
                 net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale \
                 net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_keepalive_time \
                 net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
                 net.ipv4.tcp_notsent_lowat; do
        [ -n "${sysctl_settings[$param]}" ] && echo "${param} = ${sysctl_settings[$param]}"
    done

    echo -e "\n# 网络转发设置"
    for param in net.ipv4.conf.all.route_localnet net.ipv4.ip_forward \
                 net.ipv4.conf.all.forwarding net.ipv4.conf.default.forwarding; do
        [ -n "${sysctl_settings[$param]}" ] && echo "${param} = ${sysctl_settings[$param]}"
    done
} >> /etc/sysctl.conf

# 配置 BBR (改进后的检测方法，不依赖bc)
kernel_version=$(uname -r)
major_version=$(echo "$kernel_version" | cut -d. -f1)
minor_version=$(echo "$kernel_version" | cut -d. -f2)

if [ "$major_version" -ge 4 ] && [ "$minor_version" -ge 9 ]; then
    if lsmod | grep -q "tcp_bbr" || modprobe tcp_bbr 2>/dev/null; then
        echo -e "\n# BBR 拥塞控制" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        echo "已启用 BBR 拥塞控制"
    else
        echo "警告: 无法加载 BBR 模块，但内核版本支持(${kernel_version})。请检查系统配置。"
    fi
else
    echo "警告: 内核版本(${kernel_version})不支持 BBR，需要 4.9+ 才能启用"
fi

# 应用更改并验证
echo "正在应用新设置..."
if ! sysctl -p; then
    echo "错误: sysctl 参数应用失败，请检查上面的错误信息"
    echo "备份文件保存在 $BACKUP_DIR"
    exit 1
else
    echo "系统参数应用成功"
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

# 创建恢复脚本
cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/bin/bash
# 自动生成的恢复脚本 - $(date)

# 检查root权限
[ "\$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

# 显示可用备份
echo "可用备份文件:"
ls -l "$BACKUP_DIR"/*.backup_* 2>/dev/null || { echo "未找到备份文件"; exit 1; }

# 询问用户是否继续
read -p "是否继续恢复 (y/n)? " answer
if [[ "\$answer" != "y" && "\$answer" != "Y" ]]; then
    echo "操作已取消"
    exit 0
fi

# 恢复文件的函数
restore_file() {
    local backup="\$1"
    local target="\$2"
    
    if [ -f "\$backup" ]; then
        cp "\$backup" "\$target"
        echo "已恢复: \$backup → \$target"
        return 0
    else
        echo "警告: 备份文件 \$backup 不存在"
        return 1
    fi
}

# 寻找最近的备份文件
SYSCTL_BACKUP=\$(ls -t "$BACKUP_DIR"/sysctl.conf.backup_* 2>/dev/null | head -1)
LIMITS_BACKUP=\$(ls -t "$BACKUP_DIR"/limits.conf.backup_* 2>/dev/null | head -1)
COMMON_SESSION_BACKUP=\$(ls -t "$BACKUP_DIR"/common-session.backup_* 2>/dev/null | head -1)
LOGIN_BACKUP=\$(ls -t "$BACKUP_DIR"/login.backup_* 2>/dev/null | head -1)

# 恢复系统配置文件
if [ -n "\$SYSCTL_BACKUP" ]; then
    restore_file "\$SYSCTL_BACKUP" "/etc/sysctl.conf"
    sysctl_restored=true
else
    echo "警告: 未找到 sysctl.conf 备份"
fi

if [ -n "\$LIMITS_BACKUP" ]; then
    restore_file "\$LIMITS_BACKUP" "/etc/security/limits.conf"
    limits_restored=true
else
    echo "警告: 未找到 limits.conf 备份"
fi

if [ -n "\$COMMON_SESSION_BACKUP" ]; then
    restore_file "\$COMMON_SESSION_BACKUP" "/etc/pam.d/common-session"
fi

if [ -n "\$LOGIN_BACKUP" ]; then
    restore_file "\$LOGIN_BACKUP" "/etc/pam.d/login"
fi

# 恢复limits.d下的配置
for nproc_conf_bk in /etc/security/limits.d/*nproc.conf_bk; do
    if [ -f "\$nproc_conf_bk" ]; then
        restored_name=\$(echo "\$nproc_conf_bk" | sed 's/_bk\$//')
        mv "\$nproc_conf_bk" "\$restored_name"
        echo "已恢复: \$nproc_conf_bk → \$restored_name"
    fi
done

# 应用配置
if [ "\$sysctl_restored" = true ]; then
    echo "正在应用恢复的系统参数..."
    sysctl -p
fi

# 完成信息
if [ "\$sysctl_restored" = true ] || [ "\$limits_restored" = true ]; then
    echo "系统配置恢复完成"
    echo "请重启系统以确保所有更改生效"
else
    echo "警告: 未能恢复任何配置文件"
fi
EOF

chmod +x "$BACKUP_DIR/restore.sh"
echo "恢复脚本已创建: $BACKUP_DIR/restore.sh"

# 完成信息
echo "内核优化完成"
echo "所有备份文件保存在: $BACKUP_DIR"
echo "请重启系统以确保所有更改生效"
echo "如需恢复，请运行: $BACKUP_DIR/restore.sh"
echo "由 apad.pro 提供支持"
