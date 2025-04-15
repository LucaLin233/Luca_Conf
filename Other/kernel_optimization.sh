#!/bin/bash
# Linux 内核优化脚本（推荐档案参数，1C1G~8C8G云服务器友好，适用大多数代理/运维轻量服务）

[ "$(id -u)" != "0" ] && { echo "错误: 必须使用 root 权限运行此脚本"; exit 1; }

BACKUP_DIR="/root/ktbak"
mkdir -p "$BACKUP_DIR"

backup_file() {
    local file="$1"
    local bak="$BACKUP_DIR/$(basename "$file").bak"
    if [ -f "$file" ]; then
        cp "$file" "$bak" && echo "已备份: $file → $bak"
    else
        echo "警告: 文件 $file 不存在，跳过备份"
    fi
}

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu) [ "${VERSION_ID%%.*}" -lt 9 ] && echo "警告: 此脚本只在 ${ID^} 9+ 测试过";;
        centos|rhel|almalinux|rocky) [ "${VERSION_ID%%.*}" -lt 7 ] && echo "警告: 此脚本只在 ${ID^} 7+ 测试过";;
        *) echo "警告: 未经测试的发行版: $ID $VERSION_ID，风险自负";;
    esac
else
    echo "警告: 无法识别系统类型，风险自负"
fi

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

echo "备份完成: $(date)" > "$BACKUP_DIR/backup_info.log"

# limits.d nproc特殊文件备份&冻结
if [ -d /etc/security/limits.d ]; then
    for nproc_conf in /etc/security/limits.d/*nproc.conf; do
        [ -f "$nproc_conf" ] && mv "$nproc_conf" "${nproc_conf}.bak" && echo "已备份并禁用: $nproc_conf"
    done
fi

# pam_limits.so 引入
for pam_file in /etc/pam.d/common-session /etc/pam.d/login; do
    [ -f "$pam_file" ] && ! grep -q "pam_limits.so" "$pam_file" && \
      echo "session required pam_limits.so" >> "$pam_file" && \
      echo "已添加 pam_limits 到 $pam_file"
done

# ----------- limits.conf 优化档位（先删后追加） -----------
sed -i '/^[* ].*nofile/d;/^[* ].*nproc/d;/^[* ].*memlock/d;/^[* ].*core/d/' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
# 由内核优化脚本生成 - $(date)
*     soft   nofile    65536
*     hard   nofile    65536
*     soft   nproc     4096
*     hard   nproc     4096
*     soft   core      unlimited
*     hard   core      unlimited
*     soft   memlock   65536
*     hard   memlock   65536

root     soft   nofile    65536
root     hard   nofile    65536
root     soft   nproc     4096
root     hard   nproc     4096
root     soft   core      unlimited
root     hard   core      unlimited
root     soft   memlock   65536
root     hard   memlock   65536
EOF

echo "系统limit限制配置完成"

# ----------- sysctl.conf 优化推荐档位，先删后追加 -----------
declare -A sysctl_settings=(
    ["fs.file-max"]="262144"
    ["fs.inotify.max_user_instances"]="512"
    ["fs.inotify.max_user_watches"]="8192"

    ["net.core.somaxconn"]="4096"
    ["net.core.netdev_max_backlog"]="4096"
    ["net.core.rmem_max"]="4194304"
    ["net.core.wmem_max"]="4194304"
    ["net.core.rmem_default"]="262144"
    ["net.core.wmem_default"]="262144"

    ["net.ipv4.tcp_rmem"]="4096 87380 4194304"
    ["net.ipv4.tcp_wmem"]="4096 65536 4194304"
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.udp_mem"]="65536 131072 262144"

    ["net.ipv4.tcp_max_syn_backlog"]="4096"
    ["net.ipv4.tcp_max_tw_buckets"]="10000"
    ["net.ipv4.tcp_max_orphans"]="32768"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_no_metrics_save"]="1"
    ["net.ipv4.tcp_fin_timeout"]="15"
    ["net.ipv4.route.gc_timeout"]="100"
    ["net.ipv4.tcp_syn_retries"]="2"
    ["net.ipv4.tcp_synack_retries"]="2"
    ["net.ipv4.tcp_timestamps"]="1"

    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
    ["net.ipv4.conf.all.forwarding"]="1"
    ["net.ipv4.conf.default.forwarding"]="1"

    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"

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
    ["net.ipv4.tcp_keepalive_intvl"]="60"
    ["net.ipv4.tcp_keepalive_probes"]="3"
    ["net.ipv4.tcp_notsent_lowat"]="16384"

    # IPv6转发
    ["net.ipv6.conf.all.forwarding"]="1"
    ["net.ipv6.conf.default.forwarding"]="1"
)

for key in "${!sysctl_settings[@]}"; do
    sed -i "/^[[:space:]]*${key}[[:space:]]*=.*/d" /etc/sysctl.conf
done

cat >> /etc/sysctl.conf <<EOF

# ========== 云主机优化参数 by 内核优化脚本，$(date) ==========
fs.file-max = 262144
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 8192

net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 65536 131072 262144

net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 10000
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_timestamps = 1

net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

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
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_notsent_lowat = 16384

net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

# --------- sysctl 生效 ---------
echo "正在应用 sysctl 设置..."
if sysctl -p; then
    echo "系统参数应用成功"
else
    echo "警告: sysctl -p 执行失败，请手动检查。"
fi

# --------- 生效关键参数检测 ---------
echo -e "\n参数生效检测："
check_param() {
    local key="$1"
    local expect="$2"
    local now
    now="$(sysctl -n "$key" 2>/dev/null)"
    if [ "$now" = "$expect" ]; then
        echo "✅ $key = $now (已生效)"
    else
        echo "❌ $key = $now (应为 $expect)"
    fi
}

check_param fs.file-max "262144"
check_param net.core.somaxconn "4096"
check_param net.ipv4.tcp_congestion_control "bbr"
check_param net.core.default_qdisc "fq"
check_param net.ipv4.ip_forward "1"
check_param net.ipv4.tcp_syncookies "1"
check_param net.ipv4.tcp_fin_timeout "15"
check_param net.ipv4.tcp_max_syn_backlog "4096"

echo "如有参数未生效，请排查内核支持/环境/是否需重启。"

# ------ 恢复脚本 ------
cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/bin/bash
[ "\$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }
echo "恢复配置..."

for cfg in limits.conf sysctl.conf common-session login; do
    bak="$BACKUP_DIR/\${cfg}.bak"
    case "\$cfg" in
      limits.conf) dest="/etc/security/limits.conf" ;;
      sysctl.conf) dest="/etc/sysctl.conf" ;;
      common-session) dest="/etc/pam.d/common-session" ;;
      login) dest="/etc/pam.d/login" ;;
    esac
    [ -f "\$bak" ] && cp "\$bak" "\$dest" && echo "\$bak → \$dest 恢复完成"
done

for nproc_conf_bak in /etc/security/limits.d/*nproc.conf.bak; do
    [ -f "\$nproc_conf_bak" ] && mv "\$nproc_conf_bak" "\${nproc_conf_bak%.bak}"
done

echo "恢复完成，建议重启或执行 sysctl -p"
EOF

chmod +x "$BACKUP_DIR/restore.sh"
echo "恢复脚本已创建: $BACKUP_DIR/restore.sh"

echo
echo "内核优化完成，唯一备份保存在: $BACKUP_DIR"
echo "如需恢复，请直接执行："
echo -e "\033[32m    bash $BACKUP_DIR/restore.sh\033[0m"
echo "由 apad.pro 支持"
