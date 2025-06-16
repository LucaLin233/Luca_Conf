#!/bin/bash
# 系统优化模块: Zram, 时区, 服务管理

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# Zram Swap 配置
log "配置 Zram Swap..." "info"
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "安装 zram-tools" "info"
    apt update && apt install -y zram-tools
fi

if systemctl list-unit-files --type=service | grep -q "zramswap.service"; then
    systemctl enable --now zramswap.service
    log "Zram Swap 已启用" "info"
fi

# 时区设置
log "设置系统时区..." "info"
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        timedatectl set-timezone Asia/Shanghai
        log "时区已设置为 Asia/Shanghai" "info"
    else
        log "时区已是 Asia/Shanghai" "info"
    fi
fi

# 服务管理
log "优化系统服务..." "info"
for service in tuned systemd-timesyncd; do
    if systemctl list-unit-files --type=service | grep -q "${service}.service"; then
        systemctl enable --now "${service}.service" 2>/dev/null
        log "服务 $service 已启用" "info"
    fi
done

log "系统优化模块完成" "info"
exit 0
