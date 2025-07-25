#!/bin/bash
# 网络性能优化模块 v2.1.0 (优化版)
# 功能: BBR拥塞控制, cake队列调度, sysctl优化, 网络接口管理
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="network-optimize"
BACKUP_DIR="/var/backups/network-optimize"
SYSCTL_BACKUP="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
NETWORK_CONFIG_FILE="/etc/network-optimization.conf"
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
    
    # 检查内核版本 (BBR需要4.9+)
    local kernel_version=$(uname -r | cut -d. -f1,2)
    local major=$(echo "$kernel_version" | cut -d. -f1)
    local minor=$(echo "$kernel_version" | cut -d. -f2)
    
    if [ "$major" -lt 4 ] || ([ "$major" -eq 4 ] && [ "$minor" -lt 9 ]); then
        log "内核版本过低: $(uname -r) (BBR需要 >= 4.9)" "error"
        return 1
    fi
    
    debug_log "内核版本检查通过: $(uname -r)"
    
    # 检查必要命令
    local required_commands=("tc" "sysctl" "modprobe" "lsmod")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            return 1
        fi
        debug_log "命令检查通过: $cmd"
    done
    
    # 检查BBR内核支持
    if ! check_bbr_support; then
        log "内核不支持BBR，无法启用" "error"
        return 1
    fi
    
    # 检查cake支持
    if ! check_cake_support; then
        log "系统不支持cake队列调度，将使用fq_codel" "warn"
        export FALLBACK_QDISC="fq_codel"
    else
        export FALLBACK_QDISC="cake"
    fi
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    
    return 0
}
# 检查BBR支持
check_bbr_support() {
    # 方法1: 检查模块是否可加载
    if modprobe tcp_bbr 2>/dev/null; then
        debug_log "BBR模块加载成功"
        return 0
    fi
    
    # 方法2: 检查内核配置
    if [ -f "/proc/config.gz" ]; then
        if zcat /proc/config.gz | grep -q "CONFIG_TCP_BBR=y"; then
            debug_log "BBR编译在内核中"
            return 0
        elif zcat /proc/config.gz | grep -q "CONFIG_TCP_BBR=m"; then
            debug_log "BBR作为模块编译"
            return 0
        fi
    fi
    
    # 方法3: 检查已加载模块
    if lsmod | grep -q "tcp_bbr"; then
        debug_log "BBR模块已加载"
        return 0
    fi
    
    # 方法4: 检查可用算法
    if [ -f "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            debug_log "BBR在可用算法列表中"
            return 0
        fi
    fi
    
    return 1
}
# 检查cake支持
check_cake_support() {
    # 检查tc是否支持cake
    if tc qdisc help 2>&1 | grep -q "cake"; then
        debug_log "tc支持cake队列调度"
        return 0
    fi
    
    # 检查内核模块
    if modprobe sch_cake 2>/dev/null; then
        debug_log "cake内核模块加载成功"
        return 0
    fi
    
    # 检查已加载模块
    if lsmod | grep -q "sch_cake"; then
        debug_log "cake模块已加载"
        return 0
    fi
    
    return 1
}
# 网络接口检测和验证
detect_network_interfaces() {
    log "检测网络接口..." "info"
    
    local interfaces=()
    local primary_interface=""
    
    # 方法1: 通过默认路由检测主接口
    primary_interface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}' || echo "")
    
    if [ -n "$primary_interface" ] && [ -d "/sys/class/net/$primary_interface" ]; then
        log "检测到主网络接口: $primary_interface" "info"
        interfaces+=("$primary_interface")
    else
        # 方法2: 备用检测方法
        log "主接口检测失败，使用备用方法..." "warn"
        
        # 获取活动的非回环接口
        while IFS= read -r interface; do
            if [ "$interface" != "lo" ] && ip link show "$interface" | grep -q "state UP"; then
                interfaces+=("$interface")
                debug_log "发现活动接口: $interface"
            fi
        done < <(ls /sys/class/net/ 2>/dev/null || echo "")
        
        if [ ${#interfaces[@]} -eq 0 ]; then
            log "未检测到可用的网络接口" "error"
            return 1
        elif [ ${#interfaces[@]} -eq 1 ]; then
            primary_interface="${interfaces[0]}"
            log "使用接口: $primary_interface" "info"
        else
            log "检测到多个网络接口: ${interfaces[*]}" "info"
            primary_interface=$(select_primary_interface "${interfaces[@]}")
        fi
    fi
    
    # 验证接口
    if ! validate_network_interface "$primary_interface"; then
        log "网络接口验证失败: $primary_interface" "error"
        return 1
    fi
    
    export PRIMARY_INTERFACE="$primary_interface"
    export ALL_INTERFACES=("${interfaces[@]}")
    
    return 0
}
select_primary_interface() {
    local interfaces=("$@")
    
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        # 批量模式: 选择第一个接口
        echo "${interfaces[0]}"
        return 0
    fi
    
    log "请选择主网络接口:" "info"
    for i in "${!interfaces[@]}"; do
        local interface="${interfaces[$i]}"
        local status=$(get_interface_info "$interface")
        log "  $((i+1)). $interface $status" "info"
    done
    
    while true; do
        read -p "请输入接口编号 (1-${#interfaces[@]}): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#interfaces[@]}" ]; then
            echo "${interfaces[$((choice-1))]}"
            return 0
        else
            log "无效选择，请重新输入" "error"
        fi
    done
}
get_interface_info() {
    local interface="$1"
    local info=""
    
    # 获取IP地址
    local ip_addr=$(ip addr show "$interface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1 | cut -d'/' -f1 || echo "")
    
    # 获取连接状态
    local link_status="DOWN"
    if ip link show "$interface" 2>/dev/null | grep -q "state UP"; then
        link_status="UP"
    fi
    
    # 获取接口类型
    local interface_type="unknown"
    if [ -f "/sys/class/net/$interface/type" ]; then
        local type_num=$(cat "/sys/class/net/$interface/type" 2>/dev/null || echo "1")
        case "$type_num" in
            1) interface_type="ethernet" ;;
            772) interface_type="loopback" ;;
            *) interface_type="other($type_num)" ;;
        esac
    fi
    
    info="($link_status"
    [ -n "$ip_addr" ] && info="$info, IP: $ip_addr"
    info="$info, Type: $interface_type)"
    
    echo "$info"
}
validate_network_interface() {
    local interface="$1"
    
    # 检查接口是否存在
    if [ ! -d "/sys/class/net/$interface" ]; then
        debug_log "接口不存在: $interface"
        return 1
    fi
    
    # 检查接口是否为回环接口
    if [ "$interface" = "lo" ]; then
        debug_log "跳过回环接口: $interface"
        return 1
    fi
    
    # 检查接口是否启用
    if ! ip link show "$interface" | grep -q "state UP"; then
        log "警告: 接口 $interface 未启用" "warn"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否继续使用此接口? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    debug_log "接口验证通过: $interface"
    return 0
}
# 备份现有配置
backup_existing_config() {
    log "备份现有配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份sysctl配置
    if [ -f "/etc/sysctl.conf" ]; then
        cp "/etc/sysctl.conf" "$backup_path/"
        cp "/etc/sysctl.conf" "$SYSCTL_BACKUP"
        debug_log "已备份: /etc/sysctl.conf"
    fi
    
    # 备份网络配置
    local network_configs=(
        "/etc/network/interfaces"
        "/etc/netplan/"
        "/etc/systemd/network/"
    )
    
    for config in "${network_configs[@]}"; do
        if [ -e "$config" ]; then
            cp -r "$config" "$backup_path/" 2>/dev/null || true
            debug_log "已备份: $config"
        fi
    done
    
    # 记录当前网络状态
    {
        echo "=== 网络优化前状态 ==="
        echo "时间: $(date)"
        echo "内核: $(uname -r)"
        echo ""
        echo "=== sysctl 当前值 ==="
        sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "tcp_congestion_control: 未知"
        sysctl net.core.default_qdisc 2>/dev/null || echo "default_qdisc: 未知"
        echo ""
        echo "=== 网络接口状态 ==="
        ip link show 2>/dev/null || echo "接口信息获取失败"
        echo ""
        echo "=== 队列调度状态 ==="
        for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
            echo "$iface: $(tc qdisc show dev "$iface" 2>/dev/null | head -1 || echo "未知")"
        done
    } > "$backup_path/network_status_before.txt"
    
    # 清理旧备份 (保留最近10个)
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +11 | xargs rm -rf 2>/dev/null || true
    
    debug_log "配置备份完成: $backup_path"
}
# --- sysctl参数优化配置 ---
configure_sysctl_optimization() {
    log "配置sysctl网络优化参数..." "info"
    
    # 检测系统资源以调整参数
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_mb=$((total_mem_kb / 1024))
    local cpu_cores=$(nproc)
    
    log "系统资源: ${total_mem_mb}MB 内存, ${cpu_cores} CPU核心" "info"
    
    # 根据系统资源调整缓冲区大小
    local tcp_rmem_max tcp_wmem_max
    if [ "$total_mem_mb" -ge 8192 ]; then
        # 8GB+ 内存：大缓冲区
        tcp_rmem_max="134217728"  # 128MB
        tcp_wmem_max="134217728"  # 128MB
    elif [ "$total_mem_mb" -ge 4096 ]; then
        # 4GB+ 内存：中等缓冲区
        tcp_rmem_max="67108864"   # 64MB
        tcp_wmem_max="67108864"   # 64MB
    elif [ "$total_mem_mb" -ge 2048 ]; then
        # 2GB+ 内存：标准缓冲区
        tcp_rmem_max="33554432"   # 32MB
        tcp_wmem_max="33554432"   # 32MB
    else
        # <2GB 内存：小缓冲区
        tcp_rmem_max="16777216"   # 16MB
        tcp_wmem_max="16777216"   # 16MB
    fi
    
    debug_log "TCP缓冲区大小: 读取=${tcp_rmem_max}, 发送=${tcp_wmem_max}"
    
    # 生成优化的sysctl配置
    create_optimized_sysctl_config "$tcp_rmem_max" "$tcp_wmem_max" "$cpu_cores"
    
    # 应用配置
    apply_sysctl_config
    
    return 0
}
create_optimized_sysctl_config() {
    local tcp_rmem_max="$1"
    local tcp_wmem_max="$2"
    local cpu_cores="$3"
    
    log "生成优化的sysctl配置..." "info"
    
    # 移除现有的网络优化配置
    remove_existing_network_config
    
    # 计算队列大小
    local max_syn_backlog=$((8192 * cpu_cores))
    [ "$max_syn_backlog" -gt 65536 ] && max_syn_backlog=65536
    
    local somaxconn=$((4096 * cpu_cores))
    [ "$somaxconn" -gt 32768 ] && somaxconn=32768
    
    # 生成配置文件
    cat >> /etc/sysctl.conf << EOF
# ==========================================
# 网络性能优化配置 v2.1.0
# 生成时间: $(date)
# 系统: $(uname -a)
# ==========================================
# === BBR拥塞控制配置 ===
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = ${FALLBACK_QDISC}
# === 连接队列优化 ===
net.ipv4.tcp_max_syn_backlog = $max_syn_backlog
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = 5000
# === TCP性能优化 ===
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
# === TCP窗口和缓冲区优化 ===
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rmem = 4096 87380 $tcp_rmem_max
net.ipv4.tcp_wmem = 4096 65536 $tcp_wmem_max
net.core.rmem_max = $tcp_rmem_max
net.core.wmem_max = $tcp_wmem_max
net.core.rmem_default = 262144
net.core.wmem_default = 262144
# === UDP优化 ===
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_budget = 600
# === TCP特性控制 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_abort_on_overflow = 0
# === 端口范围 ===
net.ipv4.ip_local_port_range = 1024 65535
# === 系统级优化 ===
fs.file-max = 2097152
net.netfilter.nf_conntrack_max = 1048576
# === 路由和转发 ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
# === 反向路径过滤 ===
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# === 安全和性能平衡 ===
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
# === 内存管理 ===
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    
    log "sysctl配置文件已更新" "success"
}
remove_existing_network_config() {
    debug_log "移除现有网络优化配置..."
    
    # 要移除的参数列表
    local params_to_remove=(
        "net.ipv4.tcp_congestion_control"
        "net.core.default_qdisc"
        "fs.file-max"
        "net.ipv4.tcp_max_syn_backlog"
        "net.core.somaxconn"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.tcp_abort_on_overflow"
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
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.default.rp_filter"
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.route_localnet"
    )
    
    # 移除旧配置行
    for param in "${params_to_remove[@]}"; do
        sed -i "/^${param//./\\.}[[:space:]]*=.*/d" /etc/sysctl.conf
    done
    
    # 移除旧的配置块
    sed -i '/^# 网络性能优化/,/^$/d' /etc/sysctl.conf
    sed -i '/^# ==========================================/,/^# ==========================================/d' /etc/sysctl.conf
}
apply_sysctl_config() {
    log "应用sysctl配置..." "info"
    
    # 验证配置文件语法
    if ! sysctl -e -p /etc/sysctl.conf >/dev/null 2>&1; then
        log "sysctl配置文件语法错误，恢复备份..." "error"
        
        if [ -f "$SYSCTL_BACKUP" ]; then
            cp "$SYSCTL_BACKUP" /etc/sysctl.conf
            log "已恢复备份配置" "warn"
        fi
        return 1
    fi
    
    # 应用配置
    local apply_output
    apply_output=$(sysctl -p 2>&1)
    local apply_status=$?
    
    if [ $apply_status -eq 0 ]; then
        log "sysctl配置应用成功" "success"
        debug_log "应用输出: $apply_output"
    else
        log "sysctl配置应用时出现警告:" "warn"
        echo "$apply_output" | while IFS= read -r line; do
            log "  $line" "warn"
        done
    fi
    
    return 0
}
# --- BBR和队列调度配置 ---
configure_bbr_and_qdisc() {
    log "配置BBR拥塞控制和队列调度..." "info"
    
    # 加载BBR模块
    if ! load_bbr_module; then
        log "BBR模块加载失败" "error"
        return 1
    fi
    
    # 配置队列调度算法
    configure_qdisc_for_interfaces
    
    # 验证BBR配置
    verify_bbr_configuration
    
    return 0
}
load_bbr_module() {
    log "加载BBR模块..." "info"
    
    # 检查模块是否已加载
    if lsmod | grep -q "tcp_bbr"; then
        debug_log "BBR模块已加载"
        return 0
    fi
    
    # 尝试加载模块
    if modprobe tcp_bbr 2>/dev/null; then
        log "BBR模块加载成功" "success"
        return 0
    fi
    
    # 检查是否编译在内核中
    if [ -f "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
        local available_algos
        available_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
        
        if echo "$available_algos" | grep -q "bbr"; then
            log "BBR已编译在内核中" "info"
            return 0
        fi
    fi
    
    log "BBR模块加载失败，检查内核支持" "error"
    return 1
}
configure_qdisc_for_interfaces() {
    log "配置网络接口队列调度..." "info"
    
    local qdisc="${FALLBACK_QDISC}"
    local interfaces_to_configure=("$PRIMARY_INTERFACE")
    
    # 询问是否配置所有接口
    if [ ${#ALL_INTERFACES[@]} -gt 1 ] && [ "${BATCH_MODE:-false}" != "true" ]; then
        log "检测到多个网络接口: ${ALL_INTERFACES[*]}" "info"
        read -p "是否为所有接口配置队列调度? (Y/n): " config_all
        if [[ ! "$config_all" =~ ^[Nn]$ ]]; then
            interfaces_to_configure=("${ALL_INTERFACES[@]}")
        fi
    elif [ ${#ALL_INTERFACES[@]} -gt 1 ]; then
        # 批量模式默认配置所有接口
        interfaces_to_configure=("${ALL_INTERFACES[@]}")
    fi
    
    log "将为以下接口配置 $qdisc 队列调度: ${interfaces_to_configure[*]}" "info"
    
    # 配置每个接口
    local success_count=0
    local total_count=${#interfaces_to_configure[@]}
    
    for interface in "${interfaces_to_configure[@]}"; do
        if configure_interface_qdisc "$interface" "$qdisc"; then
            ((success_count++))
        fi
    done
    
    log "队列调度配置完成: $success_count/$total_count 接口成功" "info"
    
    if [ $success_count -eq $total_count ]; then
        return 0
    else
        return 1
    fi
}
configure_interface_qdisc() {
    local interface="$1"
    local qdisc="$2"
    
    debug_log "配置接口 $interface 的队列调度..."
    
    # 检查当前队列调度
    local current_qdisc
    current_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | head -n 1 | awk '{print $2}' || echo "unknown")
    
    if [ "$current_qdisc" = "$qdisc" ]; then
        log "接口 $interface 已使用 $qdisc 队列调度" "info"
        return 0
    fi
    
    debug_log "当前队列调度: $current_qdisc, 目标: $qdisc"
    
    # 配置队列调度
    local qdisc_cmd=""
    case "$qdisc" in
        "cake")
            # cake参数优化
            qdisc_cmd="cake bandwidth 1Gbit besteffort"
            ;;
        "fq_codel")
            # fq_codel参数优化
            qdisc_cmd="fq_codel limit 10240 flows 1024 target 5ms interval 100ms"
            ;;
        "fq")
            # fq参数优化
            qdisc_cmd="fq limit 10000 flow_limit 100 buckets 1024"
            ;;
        *)
            qdisc_cmd="$qdisc"
            ;;
    esac
    
    # 应用队列调度配置
    if tc qdisc replace dev "$interface" root $qdisc_cmd 2>/dev/null; then
        log "接口 $interface 队列调度已设置为 $qdisc" "success"
        return 0
    else
        log "接口 $interface 队列调度配置失败" "error"
        return 1
    fi
}
verify_bbr_configuration() {
    log "验证BBR和队列调度配置..." "info"
    
    # 检查BBR是否生效
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    
    if [ "$current_cc" = "bbr" ]; then
        log "BBR拥塞控制已生效" "success"
    else
        log "BBR拥塞控制配置失败，当前: $current_cc" "error"
        return 1
    fi
    
    # 检查默认队列调度
    local current_qdisc
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    
    if [ "$current_qdisc" = "${FALLBACK_QDISC}" ]; then
        log "默认队列调度已设置为 $current_qdisc" "success"
    else
        log "默认队列调度配置异常，当前: $current_qdisc" "warn"
    fi
    
    # 检查接口队列调度状态
    log "接口队列调度状态:" "info"
    for interface in "${ALL_INTERFACES[@]}"; do
        local iface_qdisc
        iface_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | head -n 1 | awk '{print $2}' || echo "unknown")
        log "  • $interface: $iface_qdisc" "info"
    done
    
    return 0
}
# --- 网络性能测试 ---
perform_network_performance_test() {
    if [ "${SKIP_PERFORMANCE_TEST:-false}" = "true" ] || [ "${BATCH_MODE:-false}" = "true" ]; then
        log "跳过性能测试" "info"
        return 0
    fi
    
    read -p "是否执行网络性能测试? (y/N): " run_test
    if [[ ! "$run_test" =~ ^[Yy]$ ]]; then
        log "跳过性能测试" "info"
        return 0
    fi
    
    log "执行网络性能测试..." "info"
    
    # 基础连通性测试
    test_basic_connectivity
    
    # TCP性能测试
    test_tcp_performance
    
    # 延迟测试
    test_network_latency
}
test_basic_connectivity() {
    log "测试基础连通性..." "info"
    
    local test_hosts=("8.8.8.8" "1.1.1.1" "114.114.114.114")
    local success_count=0
    
    for host in "${test_hosts[@]}"; do
        if ping -c 3 -W 3 "$host" >/dev/null 2>&1; then
            local latency=$(ping -c 3 -W 3 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "N/A")
            log "  • $host: 连通 (平均延迟: ${latency}ms)" "success"
            ((success_count++))
        else
            log "  • $host: 连接失败" "error"
        fi
    done
    
    log "连通性测试: $success_count/${#test_hosts[@]} 主机可达" "info"
}
test_tcp_performance() {
    log "测试TCP性能..." "info"
    
    # 检查iperf3是否可用
    if ! command -v iperf3 &>/dev/null; then
        log "iperf3未安装，跳过TCP性能测试" "warn"
        log "提示: apt install iperf3" "info"
        return 0
    fi
    
    # 测试到公共iperf服务器
    local iperf_servers=("iperf.scottlinux.com" "bouygues.iperf.fr")
    
    for server in "${iperf_servers[@]}"; do
        log "测试服务器: $server" "info"
        
        if timeout 30 iperf3 -c "$server" -t 10 -P 1 2>/dev/null | grep -E "sender|receiver"; then
            log "TCP性能测试完成: $server" "success"
        else
            log "TCP性能测试失败: $server" "warn"
        fi
        
        sleep 2
    done
}
test_network_latency() {
    log "测试网络延迟..." "info"
    
    local test_targets=(
        "8.8.8.8|Google DNS"
        "1.1.1.1|Cloudflare DNS"
        "github.com|GitHub"
    )
    
    for target in "${test_targets[@]}"; do
        local host=$(echo "$target" | cut -d'|' -f1)
        local name=$(echo "$target" | cut -d'|' -f2)
        
        local result=$(ping -c 10 -i 0.2 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print "min/avg/max: " $4 "/" $5 "/" $6 "ms"}' || echo "测试失败")
        log "  • $name ($host): $result" "info"
    done
}
# --- 持久化配置管理 ---
create_persistent_configuration() {
    log "创建持久化配置..." "info"
    
    # 创建网络优化配置文件
    create_network_config_file
    
    # 创建systemd服务
    create_systemd_service
    
    # 创建网络接口配置脚本
    create_interface_config_script
    
    return 0
}
create_network_config_file() {
    log "创建网络优化配置文件..." "info"
    
    cat > "$NETWORK_CONFIG_FILE" << EOF
# 网络优化配置文件
# 生成时间: $(date)
# 生成脚本: network-optimize v2.1.0
[general]
version=2.1.0
timestamp=$(date +%s)
primary_interface=$PRIMARY_INTERFACE
fallback_qdisc=$FALLBACK_QDISC
[bbr]
enabled=true
congestion_control=bbr
default_qdisc=$FALLBACK_QDISC
[interfaces]
configured_interfaces=$(IFS=','; echo "${ALL_INTERFACES[*]}")
[system_info]
kernel_version=$(uname -r)
total_memory_mb=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
cpu_cores=$(nproc)
[backup]
sysctl_backup=$SYSCTL_BACKUP
backup_dir=$BACKUP_DIR
EOF
    
    debug_log "网络配置文件已创建: $NETWORK_CONFIG_FILE"
}
create_systemd_service() {
    log "创建systemd持久化服务..." "info"
    
    local service_file="/etc/systemd/system/network-optimize.service"
    local script_file="/usr/local/bin/network-optimize-apply.sh"
    
    # 创建应用脚本
    cat > "$script_file" << 'EOF'
#!/bin/bash
# 网络优化应用脚本
set -euo pipefail
CONFIG_FILE="/etc/network-optimization.conf"
LOG_FILE="/var/log/network-optimize.log"
# 日志函数
log_service() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    log_service "ERROR: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi
# 读取配置
source "$CONFIG_FILE" 2>/dev/null || {
    log_service "ERROR: 配置文件格式错误"
    exit 1
}
log_service "INFO: 应用网络优化配置..."
# 应用sysctl配置
if sysctl -p >/dev/null 2>&1; then
    log_service "INFO: sysctl配置应用成功"
else
    log_service "WARN: sysctl配置应用失败"
fi
# 重新配置网络接口队列调度
if [ -n "${configured_interfaces:-}" ]; then
    IFS=',' read -ra INTERFACES <<< "$configured_interfaces"
    for interface in "${INTERFACES[@]}"; do
        if [ -d "/sys/class/net/$interface" ]; then
            case "${fallback_qdisc:-cake}" in
                "cake")
                    tc qdisc replace dev "$interface" root cake bandwidth 1Gbit besteffort 2>/dev/null && \
                        log_service "INFO: 接口 $interface 队列调度已设置为 cake" || \
                        log_service "WARN: 接口 $interface 队列调度设置失败"
                    ;;
                "fq_codel")
                    tc qdisc replace dev "$interface" root fq_codel limit 10240 flows 1024 target 5ms interval 100ms 2>/dev/null && \
                        log_service "INFO: 接口 $interface 队列调度已设置为 fq_codel" || \
                        log_service "WARN: 接口 $interface 队列调度设置失败"
                    ;;
                *)
                    tc qdisc replace dev "$interface" root "${fallback_qdisc:-fq_codel}" 2>/dev/null && \
                        log_service "INFO: 接口 $interface 队列调度已设置为 ${fallback_qdisc:-fq_codel}" || \
                        log_service "WARN: 接口 $interface 队列调度设置失败"
                    ;;
            esac
        else
            log_service "WARN: 接口 $interface 不存在，跳过"
        fi
    done
else
    log_service "WARN: 未找到配置的网络接口"
fi
log_service "INFO: 网络优化配置应用完成"
EOF
    
    chmod +x "$script_file"
    
    # 创建systemd服务单元
    cat > "$service_file" << EOF
[Unit]
Description=Network Optimization Service
Documentation=man:sysctl(8) man:tc(8)
After=network.target
Wants=network.target
[Service]
Type=oneshot
ExecStart=$script_file
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    
    # 启用服务
    systemctl daemon-reload
    if systemctl enable network-optimize.service 2>/dev/null; then
        log "网络优化systemd服务已启用" "success"
    else
        log "systemd服务启用失败" "warn"
    fi
    
    debug_log "systemd服务文件: $service_file"
    debug_log "应用脚本: $script_file"
}
create_interface_config_script() {
    log "创建网络接口配置脚本..." "info"
    
    local config_script="/usr/local/bin/network-optimize-interfaces.sh"
    
    cat > "$config_script" << EOF
#!/bin/bash
# 网络接口优化配置脚本
# 用途: 手动应用网络接口优化或故障恢复
set -euo pipefail
QDISC="${FALLBACK_QDISC}"
INTERFACES=(${ALL_INTERFACES[*]})
# 显示当前状态
show_status() {
    echo "=== 网络接口状态 ==="
    for iface in "\${INTERFACES[@]}"; do
        if [ -d "/sys/class/net/\$iface" ]; then
            local qdisc=\$(tc qdisc show dev "\$iface" 2>/dev/null | head -1 | awk '{print \$2}' || echo "unknown")
            local status=\$(ip link show "\$iface" | grep -o "state [A-Z]*" | awk '{print \$2}' || echo "UNKNOWN")
            echo "  \$iface: \$qdisc (状态: \$status)"
        else
            echo "  \$iface: 不存在"
        fi
    done
    echo
    echo "=== sysctl状态 ==="
    echo "  拥塞控制: \$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "  默认队列: \$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
}
# 应用优化配置
apply_optimization() {
    echo "应用网络接口优化配置..."
    
    for iface in "\${INTERFACES[@]}"; do
        if [ -d "/sys/class/net/\$iface" ]; then
            case "\$QDISC" in
                "cake")
                    tc qdisc replace dev "\$iface" root cake bandwidth 1Gbit besteffort && \\
                        echo "  \$iface: cake 配置成功" || \\
                        echo "  \$iface: cake 配置失败"
                    ;;
                "fq_codel")
                    tc qdisc replace dev "\$iface" root fq_codel limit 10240 flows 1024 target 5ms interval 100ms && \\
                        echo "  \$iface: fq_codel 配置成功" || \\
                        echo "  \$iface: fq_codel 配置失败"
                    ;;
                *)
                    tc qdisc replace dev "\$iface" root "\$QDISC" && \\
                        echo "  \$iface: \$QDISC 配置成功" || \\
                        echo "  \$iface: \$QDISC 配置失败"
                    ;;
            esac
        fi
    done
}
# 恢复默认配置
restore_default() {
    echo "恢复默认网络配置..."
    
    for iface in "\${INTERFACES[@]}"; do
        if [ -d "/sys/class/net/\$iface" ]; then
            tc qdisc del dev "\$iface" root 2>/dev/null && \\
                echo "  \$iface: 已恢复默认队列调度" || \\
                echo "  \$iface: 恢复失败或已是默认"
        fi
    done
}
# 主函数
case "\${1:-status}" in
    "status"|"show")
        show_status
        ;;
    "apply"|"optimize")
        apply_optimization
        ;;
    "restore"|"default")
        restore_default
        ;;
    "help"|"-h"|"--help")
        echo "用法: \$0 [status|apply|restore|help]"
        echo "  status   - 显示当前网络状态"
        echo "  apply    - 应用优化配置"
        echo "  restore  - 恢复默认配置"
        echo "  help     - 显示此帮助"
        ;;
    *)
        echo "未知命令: \$1"
        echo "使用 '\$0 help' 查看帮助"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$config_script"
    debug_log "接口配置脚本: $config_script"
}
# --- 配置验证和测试 ---
verify_complete_configuration() {
    log "验证完整配置..." "info"
    
    local verification_passed=true
    
    # 验证sysctl配置
    log "验证sysctl配置..." "info"
    local required_sysctls=(
        "net.ipv4.tcp_congestion_control:bbr"
        "net.core.default_qdisc:${FALLBACK_QDISC}"
        "net.ipv4.tcp_window_scaling:1"
        "net.ipv4.tcp_sack:1"
    )
    
    for check in "${required_sysctls[@]}"; do
        local param=$(echo "$check" | cut -d':' -f1)
        local expected=$(echo "$check" | cut -d':' -f2)
        local actual=$(sysctl -n "$param" 2>/dev/null || echo "")
        
        if [ "$actual" = "$expected" ]; then
            debug_log "✓ $param = $actual"
        else
            log "✗ $param: 期望 $expected, 实际 $actual" "warn"
            verification_passed=false
        fi
    done
    
    # 验证网络接口配置
    log "验证网络接口配置..." "info"
    local interface_issues=0
    
    for interface in "${ALL_INTERFACES[@]}"; do
        if [ ! -d "/sys/class/net/$interface" ]; then
            log "✗ 接口 $interface 不存在" "warn"
            ((interface_issues++))
            continue
        fi
        
        local current_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | head -1 | awk '{print $2}' || echo "")
        if [ -n "$current_qdisc" ]; then
            debug_log "✓ $interface: $current_qdisc"
        else
            log "✗ 接口 $interface 队列调度获取失败" "warn"
            ((interface_issues++))
        fi
    done
    
    # 验证持久化配置
    log "验证持久化配置..." "info"
    local config_files=(
        "$NETWORK_CONFIG_FILE"
        "/etc/systemd/system/network-optimize.service"
        "/usr/local/bin/network-optimize-apply.sh"
        "/usr/local/bin/network-optimize-interfaces.sh"
    )
    
    for config_file in "${config_files[@]}"; do
        if [ -f "$config_file" ]; then
            debug_log "✓ $config_file 存在"
        else
            log "✗ 配置文件缺失: $config_file" "warn"
            verification_passed=false
        fi
    done
    
    # 生成验证报告
    if [ "$verification_passed" = true ] && [ $interface_issues -eq 0 ]; then
        log "配置验证通过" "success"
        return 0
    else
        log "配置验证发现问题，请检查上述警告" "warn"
        return 1
    fi
}
# --- 生成网络优化状态报告 ---
generate_network_report() {
    log "生成网络优化状态报告..." "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    log "🌐 网络性能优化状态报告" "success"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    # 基本信息
    log "📋 基本信息:" "info"
    log "  • 优化版本: v2.1.0" "info"
    log "  • 配置时间: $(date)" "info"
    log "  • 系统内核: $(uname -r)" "info"
    log "  • 主网络接口: $PRIMARY_INTERFACE" "info"
    
    # BBR和队列调度状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    log "🚀 拥塞控制配置:" "info"
    log "  • TCP拥塞控制: $current_cc" "info"
    log "  • 默认队列调度: $current_qdisc" "info"
    
    # 网络接口状态
    log "🔧 网络接口状态:" "info"
    for interface in "${ALL_INTERFACES[@]}"; do
        if [ -d "/sys/class/net/$interface" ]; then
            local iface_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | head -1 | awk '{print $2}' || echo "未知")
            local iface_status=$(ip link show "$interface" | grep -o "state [A-Z]*" | awk '{print $2}' || echo "未知")
            local iface_speed=""
            
            if [ -f "/sys/class/net/$interface/speed" ]; then
                local speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null || echo "")
                [ -n "$speed" ] && [ "$speed" != "-1" ] && iface_speed=" (${speed}Mbps)"
            fi
            
            log "  • $interface: $iface_qdisc, $iface_status$iface_speed" "info"
        else
            log "  • $interface: 不存在" "warn"
        fi
    done
    
    # 关键参数状态
    log "⚙️  关键参数状态:" "info"
    local key_params=(
        "net.ipv4.tcp_window_scaling:TCP窗口缩放"
        "net.ipv4.tcp_sack:选择性确认"
        "net.ipv4.tcp_timestamps:时间戳"
        "net.core.rmem_max:最大接收缓冲区"
        "net.core.wmem_max:最大发送缓冲区"
    )
    
    for param_info in "${key_params[@]}"; do
        local param=$(echo "$param_info" | cut -d':' -f1)
        local desc=$(echo "$param_info" | cut -d':' -f2)
        local value=$(sysctl -n "$param" 2>/dev/null || echo "未知")
        
        case "$param" in
            *rmem_max|*wmem_max)
                # 转换字节为可读格式
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    local mb=$((value / 1024 / 1024))
                    value="${mb}MB"
                fi
                ;;
        esac
        
        log "  • $desc: $value" "info"
    done
    
    # 持久化配置状态
    log "💾 持久化配置:" "info"
    if systemctl is-enabled network-optimize.service &>/dev/null; then
        log "  • 开机自启: 已启用" "success"
    else
        log "  • 开机自启: 未启用" "warn"
    fi
    
    if [ -f "$NETWORK_CONFIG_FILE" ]; then
        log "  • 配置文件: $NETWORK_CONFIG_FILE" "info"
    fi
    
    if [ -f "$SYSCTL_BACKUP" ]; then
        log "  • 配置备份: $SYSCTL_BACKUP" "info"
    fi
    
    # 性能提示
    log "💡 性能提示:" "info"
    log "  • 重启系统后优化配置将自动生效" "info"
    log "  • 使用 network-optimize-interfaces.sh 管理接口配置" "info"
    log "  • 监控网络性能: iftop, nload, iperf3" "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
}
# --- 主函数 ---
main() {
    log "开始网络性能优化配置..." "info"
    
    # 1. 系统要求检查
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 2. 网络接口检测
    if ! detect_network_interfaces; then
        log "网络接口检测失败" "error"
        exit 1
    fi
    
    # 3. 备份现有配置
    backup_existing_config
    
    # 4. 用户确认
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "将要进行以下网络优化:" "info"
        log "  • 启用BBR拥塞控制算法" "info"
        log "  • 配置${FALLBACK_QDISC}队列调度" "info"
        log "  • 优化TCP/UDP缓冲区大小" "info"
        log "  • 调整网络相关系统参数" "info"
        log "  • 主网络接口: $PRIMARY_INTERFACE" "info"
        
        read -p "是否继续执行网络优化? (Y/n): " confirm_optimize
        if [[ "$confirm_optimize" =~ ^[Nn]$ ]]; then
            log "用户取消网络优化" "info"
            exit 0
        fi
    else
        log "批量模式: 自动执行网络优化" "info"
    fi
    
    # 5. 配置sysctl优化
    if ! configure_sysctl_optimization; then
        log "sysctl优化配置失败" "error"
        exit 1
    fi
    
    # 6. 配置BBR和队列调度
    if ! configure_bbr_and_qdisc; then
        log "BBR和队列调度配置失败" "error"
        exit 1
    fi
    
    # 7. 创建持久化配置
    create_persistent_configuration
    
    # 8. 执行性能测试 (可选)
    perform_network_performance_test
    
    # 9. 验证完整配置
    if ! verify_complete_configuration; then
        log "配置验证失败" "warn"
    fi
    
    # 10. 生成状态报告
    generate_network_report
    
    log "🎉 网络性能优化配置完成!" "success"
    
    # 使用提示
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "💡 使用提示:" "info"
        log "  • 重启系统以完全应用所有优化" "info"
        log "  • 检查状态: network-optimize-interfaces.sh status" "info"
        log "  • 手动应用: network-optimize-interfaces.sh apply" "info"
        log "  • 恢复默认: network-optimize-interfaces.sh restore" "info"
        log "  • 性能测试: iperf3 -c <server>" "info"
        
        read -p "是否现在重启系统以应用所有优化? (y/N): " reboot_now
        if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
            log "系统将在10秒后重启..." "warn"
            sleep 10
            reboot
        fi
    fi
    
    exit 0
}
# 执行主函数
main "$@"
