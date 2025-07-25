#!/bin/bash
# 系统优化模块 v2.1.0 (优化版)
# 功能: Zram配置, 时区设置, 内核参数优化, 服务管理
# 适配主脚本框架
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="system-optimize"
ZRAM_CONFIG_FILE="/etc/default/zramswap"
SYSCTL_CONFIG_FILE="/etc/sysctl.d/99-system-optimize.conf"
SYSTEMD_CONFIG_DIR="/etc/systemd/system.conf.d"
BACKUP_DIR="/var/backups/system-optimize"
# 集成主脚本日志系统
log() {
    local message="$1"
    local level="${2:-info}"
    
    if declare -f log >/dev/null 2>&1 && [ "${MODULE_LOG_FILE:-}" ]; then
        echo "[$MODULE_NAME] $message" | tee -a "${MODULE_LOG_FILE}"
    else
        local colors=(
            ["info"]=$'\033[0;36m'
            ["warn"]=$'\033[0;33m'
            ["error"]=$'\033[0;31m'
            ["success"]=$'\033[0;32m'
        )
        local color="${colors[$level]:-$'\033[0;32m'}"
        echo -e "${color}[$MODULE_NAME] $message\033[0m"
    fi
}
debug_log() {
    if [ "${MODULE_DEBUG_MODE:-false}" = "true" ]; then
        log "[DEBUG] $1" "info"
    fi
}
# 检查系统要求
check_system_requirements() {
    log "检查系统要求..." "info"
    
    # 检查必要命令
    local required_commands=("zramctl" "swapon" "swapoff" "timedatectl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            debug_log "命令不存在: $cmd"
        else
            debug_log "命令检查通过: $cmd"
        fi
    done
    
    # 检查是否为root用户
    if [ "$(id -u)" != "0" ]; then
        log "此模块需要root权限执行" "error"
        return 1
    fi
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR" "$SYSTEMD_CONFIG_DIR"
    
    return 0
}
# 备份系统配置
backup_system_config() {
    log "备份系统配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份相关配置文件
    local backup_files=(
        "/etc/default/zramswap"
        "/etc/sysctl.conf"
        "/etc/sysctl.d/"
        "/etc/systemd/system.conf"
        "/proc/meminfo"
        "/proc/swaps"
    )
    
    for file in "${backup_files[@]}"; do
        if [ -e "$file" ]; then
            if [ -d "$file" ]; then
                cp -r "$file" "$backup_path/" 2>/dev/null || true
            else
                cp "$file" "$backup_path/" 2>/dev/null || true
            fi
            debug_log "已备份: $file"
        fi
    done
    
    # 记录当前系统状态
    {
        echo "=== 系统优化前状态 ==="
        echo "时间: $(date)"
        echo "内核版本: $(uname -r)"
        echo ""
        echo "=== 内存信息 ==="
        free -h
        echo ""
        echo "=== Swap信息 ==="
        swapon --show || echo "无Swap配置"
        echo ""
        echo "=== Zram状态 ==="
        zramctl 2>/dev/null || echo "无Zram配置"
        echo ""
        echo "=== 时区信息 ==="
        timedatectl status 2>/dev/null || echo "timedatectl不可用"
        echo ""
        echo "=== 系统负载 ==="
        uptime
    } > "$backup_path/system_status_before.txt"
    
    # 清理旧备份 (保留最近5个)
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +6 | xargs rm -rf 2>/dev/null || true
    
    debug_log "系统配置备份完成: $backup_path"
}
# 获取系统内存信息
analyze_system_memory() {
    log "分析系统内存配置..." "info"
    
    # 获取物理内存大小 (MB)
    local phys_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local phys_mem_mb=$((phys_mem_kb / 1024))
    local phys_mem_gb=$((phys_mem_mb / 1024))
    
    # 导出内存信息
    export PHYS_MEM_MB="$phys_mem_mb"
    export PHYS_MEM_GB="$phys_mem_gb"
    
    log "系统内存分析:" "info"
    log "  • 物理内存: ${phys_mem_mb} MB (${phys_mem_gb} GB)" "info"
    
    # 检查当前Swap状态
    local current_swap=$(swapon --show=SIZE --noheadings 2>/dev/null | head -n1 || echo "0")
    log "  • 当前Swap: ${current_swap:-无}" "info"
    
    # 检查Zram状态
    if command -v zramctl &>/dev/null; then
        local zram_info=$(zramctl --output-all --noheadings 2>/dev/null | head -n1 || echo "")
        if [ -n "$zram_info" ]; then
            log "  • Zram状态: 已配置" "info"
            debug_log "Zram详情: $zram_info"
        else
            log "  • Zram状态: 未配置" "info"
        fi
    fi
    
    # 计算推荐的Zram大小
    calculate_optimal_zram_size
}
# 计算最优Zram大小
calculate_optimal_zram_size() {
    local recommended_size=""
    
    if [ "$PHYS_MEM_MB" -gt 4096 ]; then
        # 大于4GB内存: 1GB Zram
        recommended_size="1G"
        log "  • 推荐Zram: 1GB (大内存系统)" "info"
    elif [ "$PHYS_MEM_MB" -gt 2048 ]; then
        # 2-4GB内存: 1GB Zram
        recommended_size="1G"
        log "  • 推荐Zram: 1GB (中等内存系统)" "info"
    elif [ "$PHYS_MEM_MB" -gt 1024 ]; then
        # 1-2GB内存: 物理内存的1.5倍
        local calc_size=$((PHYS_MEM_MB * 3 / 2))
        recommended_size="${calc_size}M"
        log "  • 推荐Zram: ${calc_size}MB (小内存系统 - 1.5倍)" "info"
    else
        # 小于1GB内存: 物理内存的2倍
        local calc_size=$((PHYS_MEM_MB * 2))
        recommended_size="${calc_size}M"
        log "  • 推荐Zram: ${calc_size}MB (极小内存系统 - 2倍)" "info"
    fi
    
    export RECOMMENDED_ZRAM_SIZE="$recommended_size"
}
# 安装并配置Zram
setup_zram_swap() {
    log "配置Zram Swap..." "info"
    
    # 检查并安装zram-tools
    if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
        log "安装zram-tools..." "info"
        if ! apt update && apt install -y zram-tools; then
            log "zram-tools安装失败" "error"
            return 1
        fi
        log "zram-tools安装成功" "success"
    else
        debug_log "zram-tools已安装"
    fi
    
    # 停止现有zramswap服务
    if systemctl is-active zramswap.service &>/dev/null; then
        log "停止现有zramswap服务..." "info"
        systemctl stop zramswap.service
    fi
    
    # 卸载现有zram设备
    if zramctl --find &>/dev/null; then
        debug_log "卸载现有zram设备"
        swapoff /dev/zram* 2>/dev/null || true
        zramctl --reset /dev/zram* 2>/dev/null || true
    fi
    
    # 配置zramswap
    configure_zramswap_settings
    
    # 启用并启动服务
    if ! systemctl is-enabled zramswap.service &>/dev/null; then
        log "启用zramswap服务..." "info"
        systemctl enable zramswap.service
    fi
    
    log "启动zramswap服务..." "info"
    if systemctl start zramswap.service; then
        # 验证配置
        sleep 2
        verify_zram_setup
    else
        log "zramswap服务启动失败" "error"
        return 1
    fi
}
# 配置zramswap设置
configure_zramswap_settings() {
    log "更新zramswap配置..." "info"
    
    # 备份原配置
    if [ -f "$ZRAM_CONFIG_FILE" ] && [ ! -f "${ZRAM_CONFIG_FILE}.backup.original" ]; then
        cp "$ZRAM_CONFIG_FILE" "${ZRAM_CONFIG_FILE}.backup.original"
    fi
    
    # 创建新配置
    cat > "$ZRAM_CONFIG_FILE" << EOF
# Zram Swap 配置 - 由系统优化模块生成
# 生成时间: $(date)
# Zram设备大小
ZRAM_SIZE="$RECOMMENDED_ZRAM_SIZE"
# 压缩算法 (lz4, lzo, zstd)
ZRAM_ALGO="lz4"
# 启用统计信息
ZRAM_STREAMS="\$(nproc)"
# 优先级设置
ZRAM_PRIORITY=100
EOF
    
    debug_log "zramswap配置已更新: $ZRAM_CONFIG_FILE"
}
# 验证Zram设置
verify_zram_setup() {
    log "验证Zram配置..." "info"
    
    # 检查zram设备
    if ! zramctl --output-all --noheadings 2>/dev/null | grep -q "/dev/zram"; then
        log "Zram设备创建失败" "error"
        return 1
    fi
    
    # 检查swap状态
    if ! swapon --show | grep -q "zram"; then
        log "Zram swap未激活" "error"
        return 1
    fi
    
    # 显示配置结果
    local zram_info=$(zramctl --output NAME,SIZE,COMP-ALGO,USED,COMP --noheadings 2>/dev/null | head -n1)
    log "Zram配置成功:" "success"
    log "  设备信息: $zram_info" "info"
    
    # 显示内存使用
    local mem_info=$(free -h | grep -E "(Mem|Swap)")
    log "  内存状态:" "info"
    echo "$mem_info" | while read line; do
        log "    $line" "info"
    done
    
    return 0
}
# 优化系统参数
optimize_system_parameters() {
    log "优化系统参数..." "info"
    
    # 创建sysctl配置
    cat > "$SYSCTL_CONFIG_FILE" << EOF
# 系统优化参数 - 由系统优化模块生成
# 生成时间: $(date)
# 内存管理优化
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
# 网络优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
# 文件系统优化
fs.file-max=65536
fs.inotify.max_user_watches=524288
# 安全参数
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
# 性能调优
kernel.pid_max=4194304
EOF
    
    # 应用配置
    if sysctl -p "$SYSCTL_CONFIG_FILE" &>/dev/null; then
        log "系统参数优化完成" "success"
        debug_log "sysctl配置已应用: $SYSCTL_CONFIG_FILE"
    else
        log "系统参数配置应用失败" "error"
        return 1
    fi
}
# 配置时区
setup_timezone() {
    log "配置系统时区..." "info"
    
    if ! command -v timedatectl &>/dev/null; then
        log "timedatectl命令不可用，跳过时区配置" "warn"
        return 0
    fi
    
    local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "未知")
    local target_tz="Asia/Shanghai"
    
    if [ "$current_tz" != "$target_tz" ]; then
        log "当前时区: $current_tz" "info"
        log "设置时区为: $target_tz" "info"
        
        if timedatectl set-timezone "$target_tz"; then
            log "时区设置成功" "success"
        else
            log "时区设置失败" "error"
            return 1
        fi
    else
        log "时区已正确设置: $target_tz" "info"
    fi
    
    # 显示时间信息
    local time_info=$(timedatectl status 2>/dev/null | head -n 5)
    log "当前时间状态:" "info"
    echo "$time_info" | while read line; do
        log "  $line" "info"
    done
}
# 优化服务配置
optimize_services() {
    log "优化系统服务配置..." "info"
    
    # 创建systemd配置目录
    mkdir -p "$SYSTEMD_CONFIG_DIR"
    
    # 优化systemd配置
    cat > "$SYSTEMD_CONFIG_DIR/optimize.conf" << EOF
# 系统服务优化配置
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=15s
DefaultRestartSec=1s
DefaultLimitNOFILE=65536
EOF
    
    # 重载systemd配置
    if systemctl daemon-reload; then
        log "systemd配置优化完成" "success"
    else
        log "systemd配置优化失败" "warn"
    fi
    
    # 清理不必要的服务（可选）
    local unnecessary_services=(
        "apt-daily.timer"
        "apt-daily-upgrade.timer"
    )
    
    for service in "${unnecessary_services[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            debug_log "禁用服务: $service"
            systemctl disable "$service" 2>/dev/null || true
        fi
    done
}
# 生成系统报告
generate_system_report() {
    log "生成系统优化报告..." "info"
    
    local report_file="$BACKUP_DIR/optimization_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "==============================================="
        echo "系统优化报告"
        echo "生成时间: $(date)"
        echo "==============================================="
        echo ""
        
        echo "=== 系统信息 ==="
        echo "内核版本: $(uname -r)"
        echo "发行版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
        echo "系统负载: $(uptime)"
        echo ""
        
        echo "=== 内存配置 ==="
        free -h
        echo ""
        
        echo "=== Zram状态 ==="
        zramctl --output-all 2>/dev/null || echo "无Zram配置"
        echo ""
        
        echo "=== Swap配置 ==="
        swapon --show || echo "无Swap配置"
        echo ""
        
        echo "=== 系统参数 ==="
        echo "vm.swappiness = $(sysctl -n vm.swappiness 2>/dev/null || echo '未设置')"
        echo "vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo '未设置')"
        echo ""
        
        echo "=== 时区信息 ==="
        timedatectl status 2>/dev/null || echo "timedatectl不可用"
        echo ""
        
        echo "=== 优化完成状态 ==="
        echo "✓ Zram Swap: 已配置"
        echo "✓ 系统参数: 已优化"
        echo "✓ 时区设置: 已完成"
        echo "✓ 服务配置: 已优化"
        
    } > "$report_file"
    
    log "系统优化报告已生成: $report_file" "info"
}
# 主执行函数
main() {
    log "开始系统优化模块执行..." "info"
    
    # 执行检查
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 备份配置
    backup_system_config
    
    # 分析系统
    analyze_system_memory
    
    # 执行优化
    if ! setup_zram_swap; then
        log "Zram配置失败" "error"
        exit 1
    fi
    
    if ! optimize_system_parameters; then
        log "系统参数优化失败" "error"
        exit 1
    fi
    
    if ! setup_timezone; then
        log "时区配置失败" "error"
        exit 1
    fi
    
    optimize_services
    
    # 生成报告
    generate_system_report
    
    log "系统优化模块执行完成" "success"
    return 0
}
# 执行主函数
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
exit 0
