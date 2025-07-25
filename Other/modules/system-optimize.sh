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

# 配置 Zram Swap
log "配置 Zram Swap..." "info"

# 获取物理内存大小 (MB)
PHYS_MEM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
TARGET_ZRAM_SIZE=""

# 根据物理内存设置 Zram 大小
if [ "$PHYS_MEM_MB" -gt 2048 ]; then # 大于 2GB 内存
    TARGET_ZRAM_SIZE="1G"
    log "Zram 将设置为 1GB" "info"
else # 小于等于 2GB 内存
    CALCULATED_ZRAM_MB=$((PHYS_MEM_MB * 2))
    if [ "$CALCULATED_ZRAM_MB" -ge 1024 ]; then
        TARGET_ZRAM_SIZE="$((CALCULATED_ZRAM_MB / 1024))G"
    else
        TARGET_ZRAM_SIZE="${CALCULATED_ZRAM_MB}M"
    fi
    log "Zram 将设置为 ${TARGET_ZRAM_SIZE} (物理内存的 2 倍)" "info"
fi

# 安装 zram-tools
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "安装 zram-tools" "info"
    apt update && apt install -y zram-tools
fi

# 确保 zramswap 服务已启用
if ! systemctl is-enabled zramswap.service &>/dev/null; then
    log "启用 zramswap.service" "info"
    systemctl enable zramswap.service
fi

# 停止 zramswap 服务以便应用新的配置
if systemctl is-active zramswap.service &>/dev/null; then
    log "停止 zramswap.service" "info"
    systemctl stop zramswap.service
fi

# 修改 /etc/default/zramswap 文件
if grep -q "^ZRAM_SIZE=" /etc/default/zramswap; then
    sudo sed -i "s/^ZRAM_SIZE=.*/ZRAM_SIZE=\"${TARGET_ZRAM_SIZE}\"/" /etc/default/zramswap
    log "更新 /etc/default/zramswap" "info"
else
    echo "ZRAM_SIZE=\"${TARGET_ZRAM_SIZE}\"" | sudo tee -a /etc/default/zramswap
    log "添加配置到 /etc/default/zramswap" "info"
fi

# 重新启动 zramswap 服务
log "启动 zramswap.service" "info"
systemctl start zramswap.service

log "Zram Swap 配置完成" "info"

# 设置系统时区
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

log "系统优化模块完成" "info"
exit 0
