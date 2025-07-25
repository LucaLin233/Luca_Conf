#!/bin/bash
# 自动更新系统配置模块 v2.1.0 (优化版)
# 功能: 配置系统自动更新，支持内核更新检测和智能重启

# 严格模式 (继承主脚本)
set -euo pipefail

# 模块配置
MODULE_NAME="auto-update-setup"
UPDATE_SCRIPT="/root/auto-update.sh"
UPDATE_CONFIG="/etc/auto-update.conf"
UPDATE_LOG="/var/log/auto-update.log"
BACKUP_DIR="/var/backups/auto-update"

# 集成主脚本日志系统
log() {
    local message="$1"
    local level="${2:-info}"
    
    # 如果主脚本的日志函数可用，使用它
    if declare -f log >/dev/null 2>&1 && [ "${MODULE_LOG_FILE:-}" ]; then
        echo "[$MODULE_NAME] $message" | tee -a "${MODULE_LOG_FILE}"
    else
        # 备用日志函数
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
check_requirements() {
    log "检查系统要求..." "info"
    
    # 检查必要命令
    local required_commands=("crontab" "systemctl" "dpkg-query" "apt-get")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            return 1
        fi
        debug_log "命令检查通过: $cmd"
    done
    
    # 检查 cron 服务
    if ! systemctl is-enabled cron.service &>/dev/null; then
        log "启用 cron 服务..." "warn"
        systemctl enable cron.service
    fi
    
    if ! systemctl is-active cron.service &>/dev/null; then
        log "启动 cron 服务..." "warn"
        systemctl start cron.service
    fi
    
    # 创建必要目录
    mkdir -p "$BACKUP_DIR" "$(dirname "$UPDATE_LOG")"
    
    debug_log "系统要求检查完成"
    return 0
}

# 加载配置文件
load_config() {
    # 创建默认配置文件
    if [ ! -f "$UPDATE_CONFIG" ]; then
        log "创建默认配置文件: $UPDATE_CONFIG" "info"
        
        cat > "$UPDATE_CONFIG" << 'EOF'
# 自动更新配置文件
# 更新策略: upgrade, dist-upgrade, security-only
UPDATE_TYPE="upgrade"

# 是否在内核更新后自动重启
AUTO_REBOOT="true"

# 重启前等待时间(秒)
REBOOT_DELAY="300"

# 是否发送邮件通知 (需要配置邮件系统)
MAIL_NOTIFY="false"
MAIL_TO="root@localhost"

# 更新前是否备份关键配置
BACKUP_CONFIGS="true"

# 日志保留天数
LOG_RETENTION_DAYS="30"

# 网络检查超时(秒)
NETWORK_TIMEOUT="30"

# 排除更新的软件包 (空格分隔)
EXCLUDE_PACKAGES=""

# 仅在特定时间窗口内重启 (24小时制, 格式: HH:MM-HH:MM)
REBOOT_WINDOW="02:00-06:00"
EOF
    fi
    
    # 加载配置
    if [ -f "$UPDATE_CONFIG" ]; then
        source "$UPDATE_CONFIG"
        debug_log "配置文件加载完成"
    fi
}

# 备份重要配置
backup_configs() {
    if [ "${BACKUP_CONFIGS:-true}" != "true" ]; then
        debug_log "跳过配置备份"
        return 0
    fi
    
    log "备份重要配置文件..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份关键配置文件
    local config_files=(
        "/etc/apt/sources.list"
        "/etc/apt/sources.list.d"
        "/etc/ssh/sshd_config"
        "/etc/crontab"
        "/var/spool/cron/crontabs/root"
        "$UPDATE_CONFIG"
    )
    
    for config in "${config_files[@]}"; do
        if [ -e "$config" ]; then
            cp -r "$config" "$backup_path/" 2>/dev/null || true
            debug_log "已备份: $config"
        fi
    done
    
    # 保留最近10个备份
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +11 | xargs rm -rf 2>/dev/null || true
    
    log "配置备份完成: $backup_path" "success"
}

# 验证网络连接
check_network() {
    local timeout="${NETWORK_TIMEOUT:-30}"
    local test_urls=(
        "http://deb.debian.org"
        "http://security.debian.org"
        "http://archive.debian.org"
    )
    
    log "检查网络连接..." "info"
    
    for url in "${test_urls[@]}"; do
        if timeout "$timeout" curl -fsSL --connect-timeout 10 "$url" &>/dev/null; then
            debug_log "网络连接正常: $url"
            return 0
        fi
        debug_log "网络连接失败: $url"
    done
    
    log "网络连接异常，自动更新可能失败" "warn"
    return 1
}
# --- 生成优化的自动更新脚本 ---
create_update_script() {
    log "生成自动更新脚本..." "info"
    
    # 备份现有脚本
    if [ -f "$UPDATE_SCRIPT" ]; then
        cp "$UPDATE_SCRIPT" "$UPDATE_SCRIPT.backup.$(date +%Y%m%d_%H%M%S)"
        debug_log "已备份现有更新脚本"
    fi
    
    cat > "$UPDATE_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# 自动系统更新脚本 v2.1.0 (优化版)
# 功能: 智能系统更新，支持配置文件、邮件通知、时间窗口控制

set -euo pipefail

# 配置文件和日志
CONFIG_FILE="/etc/auto-update.conf"
LOGFILE="/var/log/auto-update.log"
LOCK_FILE="/var/run/auto-update.lock"
PID_FILE="/var/run/auto-update.pid"

# 默认配置 (如果配置文件不存在)
UPDATE_TYPE="upgrade"
AUTO_REBOOT="true"
REBOOT_DELAY="300"
MAIL_NOTIFY="false"
MAIL_TO="root@localhost"
BACKUP_CONFIGS="true"
LOG_RETENTION_DAYS="30"
NETWORK_TIMEOUT="30"
EXCLUDE_PACKAGES=""
REBOOT_WINDOW="02:00-06:00"

# 加载配置文件
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 日志管理
setup_logging() {
    # 日志轮转
    if [ -f "$LOGFILE" ] && [ $(stat -c%s "$LOGFILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOGFILE" "${LOGFILE}.old"
        touch "$LOGFILE"
    fi
    
    # 清理旧日志
    find "$(dirname "$LOGFILE")" -name "$(basename "$LOGFILE").*" -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
    
    # 记录开始
    echo "=== Auto Update Started: $(date) ===" >> "$LOGFILE"
}

# 增强日志函数
log_update() {
    local level="${2:-INFO}"
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOGFILE"
    
    # 系统日志
    logger -t "auto-update" "$message"
}

# 错误处理
handle_error() {
    local exit_code=$?
    local line_number=$1
    
    log_update "脚本在第 $line_number 行出错 (退出码: $exit_code)" "ERROR"
    cleanup
    exit $exit_code
}

trap 'handle_error ${LINENO}' ERR

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE" "$PID_FILE" 2>/dev/null || true
}

trap cleanup EXIT

# 检查运行锁
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_update "另一个更新进程正在运行 (PID: $lock_pid)" "WARN"
            exit 1
        else
            log_update "发现僵尸锁文件，清理中..." "WARN"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 创建锁文件
    echo $$ > "$LOCK_FILE"
    echo $$ > "$PID_FILE"
}

# 网络连接检查
check_network_connectivity() {
    log_update "检查网络连接..."
    
    local test_hosts=("deb.debian.org" "security.debian.org" "archive.debian.org")
    local success_count=0
    
    for host in "${test_hosts[@]}"; do
        if timeout $NETWORK_TIMEOUT ping -c 1 -W 5 "$host" >/dev/null 2>&1; then
            ((success_count++))
        fi
    done
    
    if [ $success_count -eq 0 ]; then
        log_update "网络连接失败，取消更新" "ERROR"
        return 1
    fi
    
    log_update "网络连接正常 ($success_count/${#test_hosts[@]} 个主机可达)"
    return 0
}

# 系统负载检查
check_system_load() {
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local cpu_count=$(nproc)
    local load_threshold=$(echo "$cpu_count * 2" | bc 2>/dev/null || echo $((cpu_count * 2)))
    
    if (( $(echo "$load_avg > $load_threshold" | bc -l 2>/dev/null || echo 0) )); then
        log_update "系统负载过高 ($load_avg), 延迟更新" "WARN"
        return 1
    fi
    
    log_update "系统负载正常 ($load_avg)"
    return 0
}

# 磁盘空间检查
check_disk_space() {
    local required_space=1048576  # 1GB in KB
    local available_space=$(df / | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_update "磁盘空间不足 (可用: $((available_space/1024))MB, 需要: $((required_space/1024))MB)" "ERROR"
        return 1
    fi
    
    log_update "磁盘空间充足 (可用: $((available_space/1024))MB)"
    return 0
}

# 预更新检查
pre_update_checks() {
    log_update "执行预更新检查..."
    
    check_network_connectivity || return 1
    check_system_load || return 1
    check_disk_space || return 1
    
    # 检查APT锁
    local max_wait=300
    local wait_time=0
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ $wait_time -ge $max_wait ]; then
            log_update "APT被锁定超过5分钟，强制解锁" "WARN"
            killall apt apt-get dpkg 2>/dev/null || true
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
            break
        fi
        
        log_update "APT被锁定，等待解锁... ($wait_time/${max_wait}s)"
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    log_update "预更新检查完成"
    return 0
}

# 构建APT选项
build_apt_options() {
    local apt_opts="-y"
    apt_opts+=" -o Dpkg::Options::=--force-confdef"
    apt_opts+=" -o Dpkg::Options::=--force-confold"
    apt_opts+=" -o APT::ListChanges::Frontend=none"
    apt_opts+=" -o APT::Get::Assume-Yes=true"
    
    # 排除特定软件包
    if [ -n "$EXCLUDE_PACKAGES" ]; then
        for pkg in $EXCLUDE_PACKAGES; do
            apt_opts+=" -o APT::Get::Hold=$pkg"
        done
        log_update "排除软件包: $EXCLUDE_PACKAGES"
    fi
    
    echo "$apt_opts"
}

# 执行系统更新
perform_system_update() {
    log_update "开始系统更新 (类型: $UPDATE_TYPE)"
    
    local apt_options=$(build_apt_options)
    local update_success=true
    
    # 更新软件包列表
    log_update "更新软件包列表..."
    if timeout 300 apt-get update $apt_options >>$LOGFILE 2>&1; then
        log_update "软件包列表更新成功"
    else
        log_update "软件包列表更新失败" "ERROR"
        update_success=false
    fi
    
    # 执行更新
    case "$UPDATE_TYPE" in
        "security-only")
            log_update "仅安装安全更新..."
            if timeout 1800 apt-get upgrade $apt_options -t "$(lsb_release -cs)-security" >>$LOGFILE 2>&1; then
                log_update "安全更新完成"
            else
                log_update "安全更新失败" "ERROR"
                update_success=false
            fi
            ;;
        "dist-upgrade")
            log_update "执行发行版升级..."
            if timeout 3600 apt-get dist-upgrade $apt_options >>$LOGFILE 2>&1; then
                log_update "发行版升级完成"
            else
                log_update "发行版升级失败" "ERROR"
                update_success=false
            fi
            ;;
        *)
            log_update "执行标准升级..."
            if timeout 1800 apt-get upgrade $apt_options >>$LOGFILE 2>&1; then
                log_update "标准升级完成"
            else
                log_update "标准升级失败" "ERROR"
                update_success=false
            fi
            ;;
    esac
    
    if [ "$update_success" = true ]; then
        log_update "系统更新成功完成"
        return 0
    else
        log_update "系统更新过程中出现错误" "ERROR"
        return 1
    fi
}

# 检查内核更新
check_kernel_update() {
    local current_kernel=$(uname -r)
    log_update "当前运行内核: $current_kernel"
    
    # 获取最新安装的内核
    local latest_kernel=$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | \
                         grep 'install ok installed' | \
                         sort -k2 -V | tail -n1 | \
                         awk '{print $1}' | sed 's/^linux-image-//')
    
    if [ -n "$latest_kernel" ] && [ "$current_kernel" != "$latest_kernel" ]; then
        log_update "检测到新内核: $latest_kernel (当前: $current_kernel)"
        return 0
    else
        log_update "内核为最新版本，无需重启"
        return 1
    fi
}

# 检查重启时间窗口
check_reboot_window() {
    if [ -z "$REBOOT_WINDOW" ]; then
        return 0  # 无时间限制
    fi
    
    local current_time=$(date +%H:%M)
    local window_start=$(echo "$REBOOT_WINDOW" | cut -d'-' -f1)
    local window_end=$(echo "$REBOOT_WINDOW" | cut -d'-' -f2)
    
    # 简单的时间比较 (不处理跨日情况)
    if [[ "$current_time" > "$window_start" && "$current_time" < "$window_end" ]]; then
        log_update "当前时间 ($current_time) 在重启窗口内 ($REBOOT_WINDOW)"
        return 0
    else
        log_update "当前时间 ($current_time) 不在重启窗口内 ($REBOOT_WINDOW)"
        return 1
    fi
}

# 发送邮件通知
send_notification() {
    local subject="$1"
    local message="$2"
    
    if [ "$MAIL_NOTIFY" != "true" ] || [ -z "$MAIL_TO" ]; then
        return 0
    fi
    
    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$MAIL_TO"
        log_update "邮件通知已发送至: $MAIL_TO"
    else
        log_update "mail 命令不可用，跳过邮件通知" "WARN"
    fi
}
SCRIPT_EOF

    log "自动更新脚本第一部分生成完成" "success"
}
# --- 完成自动更新脚本生成 ---
complete_update_script() {
    log "完成自动更新脚本生成..." "info"
    
    # 追加脚本的剩余部分
    cat >> "$UPDATE_SCRIPT" << 'SCRIPT_EOF'
# 系统清理
perform_cleanup() {
    log_update "执行系统清理..."
    
    # 清理软件包缓存
    apt-get autoremove -y >>$LOGFILE 2>&1 || log_update "autoremove 失败" "WARN"
    apt-get autoclean >>$LOGFILE 2>&1 || log_update "autoclean 失败" "WARN"
    
    # 清理日志文件
    journalctl --vacuum-time=30d >/dev/null 2>&1 || log_update "journalctl清理失败" "WARN"
    
    # 清理临时文件
    find /tmp -type f -mtime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
    
    # 更新locate数据库
    if command -v updatedb >/dev/null 2>&1; then
        updatedb 2>/dev/null &
    fi
    
    log_update "系统清理完成"
}
# 智能重启逻辑
handle_reboot() {
    local need_reboot=false
    local reboot_reason=""
    
    # 检查内核更新
    if check_kernel_update; then
        need_reboot=true
        reboot_reason="内核更新"
    fi
    
    # 检查是否有需要重启的服务
    local restart_required="/var/run/reboot-required"
    if [ -f "$restart_required" ]; then
        need_reboot=true
        local reason_file="${restart_required}.pkgs"
        if [ -f "$reason_file" ]; then
            local packages=$(cat "$reason_file" 2>/dev/null | tr '\n' ' ')
            reboot_reason="${reboot_reason:+$reboot_reason, }系统组件更新: $packages"
        else
            reboot_reason="${reboot_reason:+$reboot_reason, }系统组件更新"
        fi
    fi
    
    # 检查重要服务状态
    local critical_services=("sshd" "systemd-logind" "dbus")
    for service in "${critical_services[@]}"; do
        if systemctl is-failed "$service" >/dev/null 2>&1; then
            log_update "关键服务 $service 状态异常，建议重启" "WARN"
            need_reboot=true
            reboot_reason="${reboot_reason:+$reboot_reason, }服务异常"
        fi
    done
    
    if [ "$need_reboot" = false ]; then
        log_update "系统无需重启"
        return 0
    fi
    
    if [ "$AUTO_REBOOT" != "true" ]; then
        log_update "检测到需要重启 ($reboot_reason)，但自动重启已禁用" "WARN"
        send_notification "系统更新完成 - 需要手动重启" \
            "服务器 $(hostname) 完成自动更新，检测到需要重启: $reboot_reason。请尽快手动重启系统。"
        return 0
    fi
    
    # 检查重启时间窗口
    if ! check_reboot_window; then
        log_update "不在重启时间窗口内，推迟重启" "WARN"
        send_notification "系统更新完成 - 重启已推迟" \
            "服务器 $(hostname) 完成自动更新，需要重启: $reboot_reason。由于不在重启时间窗口内，重启已推迟。"
        return 0
    fi
    
    log_update "系统将在 $REBOOT_DELAY 秒后重启，原因: $reboot_reason"
    
    # 发送重启通知
    send_notification "系统自动重启通知" \
        "服务器 $(hostname) 完成自动更新，将在 $REBOOT_DELAY 秒后重启。重启原因: $reboot_reason"
    
    # 确保关键服务正常
    local services_to_check=("sshd" "cron")
    for service in "${services_to_check[@]}"; do
        if ! systemctl is-active "$service" >/dev/null 2>&1; then
            log_update "重启前启动关键服务: $service" "WARN"
            systemctl start "$service" 2>/dev/null || true
        fi
    done
    
    # 同步文件系统
    sync
    
    # 等待指定时间
    sleep "$REBOOT_DELAY"
    
    # 执行重启
    log_update "开始重启系统..."
    shutdown -r now "Auto-update reboot: $reboot_reason"
}
# 生成更新报告
generate_report() {
    local start_time="$1"
    local end_time=$(date)
    local duration=$(($(date +%s) - $(date -d "$start_time" +%s)))
    
    log_update "=== 更新报告 ==="
    log_update "开始时间: $start_time"
    log_update "结束时间: $end_time"
    log_update "执行时长: ${duration}秒"
    log_update "更新类型: $UPDATE_TYPE"
    
    # 统计更新的软件包
    local updated_packages=$(grep -c "Unpacking\|Setting up" "$LOGFILE" 2>/dev/null || echo "0")
    log_update "更新软件包数量: $updated_packages"
    
    # 检查错误
    local error_count=$(grep -c "ERROR" "$LOGFILE" 2>/dev/null || echo "0")
    local warning_count=$(grep -c "WARN" "$LOGFILE" 2>/dev/null || echo "0")
    
    log_update "警告数量: $warning_count"
    log_update "错误数量: $error_count"
    
    # 系统状态
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local memory_usage=$(free | awk '/^Mem/ {printf "%.1f%%", $3/$2 * 100.0}')
    local disk_usage=$(df / | awk 'NR==2 {print $5}')
    
    log_update "当前负载: $load_avg"
    log_update "内存使用: $memory_usage"
    log_update "磁盘使用: $disk_usage"
    log_update "================="
}
# 主执行流程
main() {
    local start_time=$(date)
    
    setup_logging
    check_lock
    
    log_update "自动更新脚本开始执行"
    log_update "配置: 更新类型=$UPDATE_TYPE, 自动重启=$AUTO_REBOOT, 重启延迟=${REBOOT_DELAY}s"
    
    # 预检查
    if ! pre_update_checks; then
        log_update "预检查失败，取消更新" "ERROR"
        exit 1
    fi
    
    # 执行更新
    if perform_system_update; then
        log_update "系统更新完成"
        
        # 清理系统
        perform_cleanup
        
        # 处理重启
        handle_reboot
        
        # 生成报告
        generate_report "$start_time"
        
        # 发送成功通知
        send_notification "系统自动更新成功" \
            "服务器 $(hostname) 自动更新已成功完成。详细信息请查看日志文件: $LOGFILE"
        
        log_update "自动更新流程完成"
        exit 0
    else
        log_update "系统更新失败" "ERROR"
        
        # 发送失败通知
        send_notification "系统自动更新失败" \
            "服务器 $(hostname) 自动更新失败。请检查日志文件: $LOGFILE"
        
        exit 1
    fi
}
# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
SCRIPT_EOF
    # 设置脚本权限
    chmod +x "$UPDATE_SCRIPT"
    
    log "自动更新脚本生成完成: $UPDATE_SCRIPT" "success"
    debug_log "脚本大小: $(du -h "$UPDATE_SCRIPT" | cut -f1)"
}
# --- Cron配置优化 ---
configure_cron_advanced() {
    log "配置高级Cron任务..." "info"
    
    # 显示当前cron任务
    log "当前root用户的Cron任务:" "info"
    if crontab -l 2>/dev/null | grep -q .; then
        crontab -l 2>/dev/null | while IFS= read -r line; do
            log "  $line" "info"
        done
    else
        log "  (无)" "info"
    fi
    
    # 检查现有任务
    local script_pattern=$(echo "$UPDATE_SCRIPT" | sed 's/[\/&]/\\&/g')
    local existing_cron=""
    
    if crontab -l 2>/dev/null | grep -q "$script_pattern"; then
        existing_cron=$(crontab -l 2>/dev/null | grep "$script_pattern")
        log "检测到现有自动更新任务:" "warn"
        log "  $existing_cron" "warn"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否替换现有任务? (y/N): " replace_existing
            if [[ ! "$replace_existing" =~ ^[Yy]$ ]]; then
                log "保持现有Cron任务不变" "info"
                return 0
            fi
        else
            log "批量模式: 自动替换现有任务" "info"
        fi
    fi
    
    # 提供预设选项
    local cron_presets=(
        "0 2 * * 0|每周日凌晨2点"
        "0 3 * * 1|每周一凌晨3点"  
        "0 1 1 * *|每月1号凌晨1点"
        "0 4 * * 6|每周六凌晨4点"
        "0 2 * * 2,5|每周二、五凌晨2点"
        "custom|自定义时间"
    )
    
    log "请选择更新时间:" "info"
    for i in "${!cron_presets[@]}"; do
        local preset="${cron_presets[$i]}"
        local schedule=$(echo "$preset" | cut -d'|' -f1)
        local description=$(echo "$preset" | cut -d'|' -f2)
        log "  $((i+1)). $description ($schedule)" "info"
    done
    
    local selected_cron=""
    
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        # 批量模式使用默认选项
        selected_cron="0 2 * * 0"
        log "批量模式: 使用默认时间 (每周日凌晨2点)" "info"
    else
        # 交互模式
        while true; do
            read -p "请选择 (1-${#cron_presets[@]}): " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#cron_presets[@]}" ]; then
                local preset="${cron_presets[$((choice-1))]}"
                local schedule=$(echo "$preset" | cut -d'|' -f1)
                
                if [ "$schedule" = "custom" ]; then
                    # 自定义时间
                    log "Cron时间格式: 分 时 日 月 周" "info"
                    log "示例: 0 2 * * 0 (每周日凌晨2点)" "info"
                    
                    while true; do
                        read -p "请输入Cron表达式: " custom_schedule
                        if [[ "$custom_schedule" =~ ^[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+[[:space:]]+[0-9*,-/]+$ ]]; then
                            selected_cron="$custom_schedule"
                            break
                        else
                            log "格式错误，请重新输入" "error"
                        fi
                    done
                else
                    selected_cron="$schedule"
                fi
                break
            else
                log "无效选择，请重新输入" "error"
            fi
        done
    fi
    
    # 创建新的cron任务
    local new_cron_job="$selected_cron $UPDATE_SCRIPT"
    
    log "配置Cron任务: $new_cron_job" "info"
    
    # 安全更新crontab
    local temp_cron=$(mktemp)
    
    # 保存现有crontab，排除我们的脚本
    crontab -l 2>/dev/null | grep -v "$script_pattern" > "$temp_cron" || true
    
    # 添加新任务
    echo "$new_cron_job" >> "$temp_cron"
    
    # 验证crontab格式
    if ! crontab -T "$temp_cron" 2>/dev/null; then
        log "Cron任务格式验证失败" "error"
        rm -f "$temp_cron"
        return 1
    fi
    
    # 应用新crontab
    if crontab "$temp_cron"; then
        log "Cron任务配置成功" "success"
    else
        log "Cron任务配置失败" "error"
        rm -f "$temp_cron"
        return 1
    fi
    
    rm -f "$temp_cron"
    
    # 验证配置
    if crontab -l 2>/dev/null | grep -q "$script_pattern"; then
        log "Cron任务验证成功" "success"
        return 0
    else
        log "Cron任务验证失败" "error"
        return 1
    fi
}
# --- 显示配置摘要 ---
show_configuration_summary() {
    log "自动更新系统配置摘要:" "success"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    # 基本信息
    log "📋 基本配置:" "info"
    log "  • 更新脚本: $UPDATE_SCRIPT" "info"
    log "  • 配置文件: $UPDATE_CONFIG" "info" 
    log "  • 日志文件: $UPDATE_LOG" "info"
    log "  • 备份目录: $BACKUP_DIR" "info"
    
    # Cron配置
    local cron_schedule=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" | awk '{print $1, $2, $3, $4, $5}')
    log "⏰ 执行计划: $cron_schedule" "info"
    
    # 运行时配置
    log "⚙️  运行配置:" "info"
    log "  • 更新类型: ${UPDATE_TYPE:-upgrade}" "info"
    log "  • 自动重启: ${AUTO_REBOOT:-true}" "info"
    log "  • 重启延迟: ${REBOOT_DELAY:-300}秒" "info"
    log "  • 邮件通知: ${MAIL_NOTIFY:-false}" "info"
    log "  • 配置备份: ${BACKUP_CONFIGS:-true}" "info"
    
    # 使用提示
    log "💡 使用提示:" "info"
    log "  • 手动执行: $UPDATE_SCRIPT" "info"
    log "  • 查看日志: tail -f $UPDATE_LOG" "info"
    log "  • 编辑配置: nano $UPDATE_CONFIG" "info"
    log "  • 查看任务: crontab -l" "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
}
# --- 主函数 ---
main() {
    log "开始配置自动更新系统..." "info"
    
    # 检查系统要求
    if ! check_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 加载配置
    load_config
    
    # 备份配置
    backup_configs
    
    # 检查网络
    check_network || log "网络检查失败，但继续执行" "warn"
    
    # 生成更新脚本
    create_update_script
    complete_update_script
    
    # 配置Cron任务
    if ! configure_cron_advanced; then
        log "Cron配置失败" "error"
        exit 1
    fi
    
    # 显示配置摘要
    show_configuration_summary
    
    # 询问是否测试
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        echo
        read -p "是否立即测试自动更新脚本? (y/N): " test_now
        if [[ "$test_now" =~ ^[Yy]$ ]]; then
            log "开始测试自动更新脚本..." "info"
            log "注意: 这将执行真实的系统更新!" "warn"
            read -p "确认继续测试? (y/N): " confirm_test
            if [[ "$confirm_test" =~ ^[Yy]$ ]]; then
                "$UPDATE_SCRIPT" || log "测试执行失败" "error"
                log "测试完成，请检查日志: $UPDATE_LOG" "info"
            fi
        fi
    fi
    
    log "🎉 自动更新系统配置完成!" "success"
    exit 0
}
# 执行主函数
main "$@"
