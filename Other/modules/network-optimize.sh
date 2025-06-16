#!/bin/bash
# 网络性能优化模块: BBR + fq_codel

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

log "配置网络性能优化..." "info"

read -p "是否启用 BBR + fq_codel 网络拥塞控制? (Y/n): " enable_bbr
enable_bbr="${enable_bbr:-y}"

if [[ ! "$enable_bbr" =~ ^[nN]$ ]]; then
    log "启用 BBR 拥塞控制算法..." "info"
    
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
    
    # 移除旧配置
    sed -i '/net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net\.core\.default_qdisc/d' /etc/sysctl.conf
    
    # 添加新配置
    cat >> /etc/sysctl.conf << 'EOF'

# 网络性能优化 - BBR + fq_codel
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel
EOF
    
    # 应用配置
    sysctl -p || log "警告: sysctl -p 执行失败" "warn"
    
    # 验证配置
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    log "当前拥塞控制算法: $CURRENT_CC" "info"
    log "当前队列调度算法: $CURRENT_QDISC" "info"
    
    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq_codel" ]; then
        log "BBR + fq_codel 配置成功" "info"
    else
        log "网络优化配置可能未完全生效" "warn"
        log "可能需要重启系统以完全应用配置" "warn"
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
