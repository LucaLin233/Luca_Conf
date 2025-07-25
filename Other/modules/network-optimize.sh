#!/bin/bash
# 网络性能优化模块: BBR + cake + sysctl 优化参数 + 自动tc队列，无多余空格

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# 自动检测主用出口网卡
NET_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}')
if [ -z "$NET_IF" ]; then
    log "未检测到主用网卡名，请手动设置 NET_IF 变量！" "error"
    exit 1
else
    log "检测到主用网卡: $NET_IF" "info"
fi

log "配置网络性能优化..." "info"

read -p "是否启用 BBR + cake 网络拥塞控制及高级 sysctl 优化? (Y/n): " enable_bbr
enable_bbr="${enable_bbr:-y}"

if [[ ! "$enable_bbr" =~ ^[nN]$ ]]; then
    log "启用 BBR 拥塞控制算法及批量优化参数..." "info"
    
    # 检查 BBR 模块
    if ! modprobe tcp_bbr 2>/dev/null; then
        log "警告: 无法加载 tcp_bbr 模块" "warn"
        if [ -f "/proc/config.gz" ]; then
            if zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m; then
                log "BBR 模块编译在内核中" "info"
            else
                log "内核不支持 BBR，跳过配置" "error"
                exit 1
            fi
        else
            log "无法确定内核 BBR 支持状态" "warn"
        fi
    else
        log "BBR 模块加载成功" "info"
    fi
    
    # 备份 sysctl 配置
    [ ! -f /etc/sysctl.conf.backup ] && cp /etc/sysctl.conf /etc/sysctl.conf.backup
    
    # 配置 sysctl 参数
    log "配置 sysctl 参数..." "info"
    
    # 移除旧配置（可能重复的优化项）
    for param in \
      "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" \
      "fs.file-max" "net.ipv4.tcp_max_syn_backlog" "net.core.somaxconn" \
      "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_abort_on_overflow" \
      "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_ecn" "net.ipv4.tcp_frto" \
      "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack" \
      "net.ipv4.tcp_fack" "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale" \
      "net.ipv4.tcp_moderate_rcvbuf" "net.ipv4.tcp_fin_timeout" \
      "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.core.rmem_max" "net.core.wmem_max" \
      "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min" "net.ipv4.ip_local_port_range" \
      "net.ipv4.tcp_timestamps" "net.ipv4.conf.all.rp_filter" "net.ipv4.conf.default.rp_filter" \
      "net.ipv4.ip_forward" "net.ipv4.conf.all.route_localnet"
    do
        sed -i "/^${param//./\\.}[[:space:]]*=.*/d" /etc/sysctl.conf
    done

    # 添加新配置（无多余空格）
    cat >> /etc/sysctl.conf <<'EOF'

# 网络性能优化 - BBR + cake + 高级 sysctl 参数
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
fs.file-max = 6815744
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1

EOF

    # 应用配置
    sysctl -p || log "警告: sysctl -p 执行失败" "warn"
    
    # 强制切当前接口队列算法为 cake
    if ! which tc >/dev/null 2>&1; then
        log "未检测到 tc 命令，无法切换当前网卡队列。请手动安装 iproute2。" "warn"
    else
        if tc qdisc show dev $NET_IF 2>/dev/null | grep -q "cake"; then
            log "$NET_IF 已在使用 cake 队列" "info"
        else
            sudo tc qdisc replace dev $NET_IF root cake && log "$NET_IF 队列已切换为 cake" "info"
        fi
    fi

    # 验证配置
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    log "当前拥塞控制算法: $CURRENT_CC" "info"
    log "当前默认队列调度算法: $CURRENT_QDISC" "info"
    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "cake" ]; then
        log "BBR + cake sysctl 配置成功" "info"
    else
        log "网络优化配置可能未完全生效" "warn"
        log "建议重启系统以完全应用配置" "warn"
    fi

else
    log "跳过网络优化配置" "info"
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    log "当前拥塞控制算法: $CURRENT_CC" "info"
    log "当前队列调度算法: $CURRENT_QDISC" "info"
fi

log "网络优化配置完成" "info"
exit 0
