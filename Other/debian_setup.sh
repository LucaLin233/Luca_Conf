#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署脚本 (模块化版本 v2.1.0 - 优化版)
# 适用系统: Debian 12+
# 功能: 模块化部署 Zsh, Mise, Docker, 网络优化, SSH 加固等
# 作者: LucaLin233
# 优化: 错误处理、并行下载、状态管理、日志记录
# -----------------------------------------------------------------------------

# 严格模式和安全设置
set -euo pipefail
IFS=$'\n\t'

# 脚本配置
SCRIPT_VERSION="2.1.0"
SCRIPT_NAME=$(basename "$0")
STATUS_FILE="/var/lib/system-deploy-status.json"
LOG_FILE="/var/log/debian-setup.log"
CONFIG_FILE="/etc/debian-setup.conf"
MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/modules"
TEMP_DIR="/tmp/debian_setup_modules"

# 全局变量
RERUN_MODE=false
BATCH_MODE=false
DEBUG_MODE=false
PARALLEL_DOWNLOADS=3
EXECUTED_MODULES=()
FAILED_MODULES=()
SKIPPED_MODULES=()

# --- 清理和信号处理 ---
cleanup() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log "脚本异常退出 (退出码: $exit_code)" "error"
    fi
    
    # 清理临时文件
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    
    # 清理进程组
    local pids=$(jobs -p 2>/dev/null || true)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        wait $pids 2>/dev/null || true
    fi
    
    exit $exit_code
}

# 注册信号处理
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- 日志系统 ---
setup_logging() {
    # 创建日志目录
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 日志轮转（保留最近5个）
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]; then
        for i in {4..1}; do
            [ -f "${LOG_FILE}.$i" ] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
    
    # 记录开始时间
    echo "=== Debian Setup Script v$SCRIPT_VERSION - $(date) ===" >> "$LOG_FILE"
}

log() {
    local message="$1"
    local level="${2:-info}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 使用更兼容的颜色定义方式
    local color=""
    case "$level" in
        "default"|"info"|"") color='\033[0;36m' ;;  # 青色
        "warn") color='\033[0;33m' ;;  # 黄色
        "error") color='\033[0;31m' ;;  # 红色
        "title") color='\033[1;35m' ;;  # 紫色粗体
        "debug") color='\033[0;37m' ;;  # 灰色
        *) color='\033[0;32m' ;;  # 默认绿色
    esac
    
    local reset='\033[0m'
    
    # 控制台输出
    echo -e "${color}${message}${reset}"
    
    # 文件日志（无颜色）
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # 调试模式额外信息
    if [ "$DEBUG_MODE" = true ] && [ "$level" = "debug" ]; then
        echo -e "${color}[DEBUG] $message${reset}" >&2
    fi
}

debug_log() {
    [ "$DEBUG_MODE" = true ] && log "$1" "debug"
}

step_start() { 
    log "▶ 步骤 $1: $2..." "title"
    debug_log "开始执行步骤 $1"
}

step_end() { 
    log "✓ 步骤 $1 完成: $2" "info"
    debug_log "步骤 $1 执行完成"
    echo
}

step_fail() { 
    log "✗ 步骤 $1 失败: $2" "error"
    log "检查日志文件: $LOG_FILE" "info"
    exit 1
}

# --- 进度显示 ---
show_progress() {
    local current=$1
    local total=$2
    local desc="$3"
    local percent=$((current * 100 / total))
    local bar_length=30
    local filled_length=$((percent * bar_length / 100))
    
    local bar=""
    for ((i=0; i<filled_length; i++)); do bar+="█"; done
    for ((i=filled_length; i<bar_length; i++)); do bar+="░"; done
    
    printf "\r%s [%s] %d%% (%d/%d)" "$desc" "$bar" "$percent" "$current" "$total"
    
    if [ $current -eq $total ]; then
        echo
    fi
}

# --- 网络检查增强版 ---
network_check() {
    local test_endpoints=(
        "8.8.8.8"
        "1.1.1.1" 
        "114.114.114.114"
        "223.5.5.5"
    )
    
    local http_endpoints=(
        "https://www.google.com"
        "https://www.github.com"
        "https://www.debian.org"
    )
    
    log "执行网络连通性检查..." "info"
    
    # ICMP 检查
    local icmp_success=0
    for endpoint in "${test_endpoints[@]}"; do
        if timeout 5 ping -c 1 -W 3 "$endpoint" &>/dev/null; then
            ((icmp_success++))
            debug_log "ICMP 连接成功: $endpoint"
        else
            debug_log "ICMP 连接失败: $endpoint"
        fi
    done
    
    # HTTP 检查
    local http_success=0
    for endpoint in "${http_endpoints[@]}"; do
        if timeout 10 curl -fsSL --connect-timeout 5 "$endpoint" &>/dev/null; then
            ((http_success++))
            debug_log "HTTP 连接成功: $endpoint"
        else
            debug_log "HTTP 连接失败: $endpoint"
        fi
    done
    
    debug_log "网络检查结果: ICMP $icmp_success/${#test_endpoints[@]}, HTTP $http_success/${#http_endpoints[@]}"
    
    # 至少要有一半的连接成功
    if [ $icmp_success -ge 2 ] || [ $http_success -ge 1 ]; then
        log "网络连接正常" "info"
        return 0
    else
        log "网络连接异常，部分功能可能受影响" "warn"
        return 1
    fi
}

# --- 配置文件支持 ---
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log "加载配置文件: $CONFIG_FILE" "info"
        source "$CONFIG_FILE"
        debug_log "配置文件加载完成"
    else
        debug_log "未找到配置文件，使用默认配置"
    fi
}

create_default_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "创建默认配置文件: $CONFIG_FILE" "info"
        cat > "$CONFIG_FILE" << 'EOF'
# Debian Setup 配置文件
# 设置为 true 表示自动执行该模块，false 表示跳过，unset 表示询问用户

# 模块配置
AUTO_SYSTEM_OPTIMIZE=true
AUTO_ZSH_SETUP=true
AUTO_MISE_SETUP=true
AUTO_DOCKER_SETUP=true
AUTO_NETWORK_OPTIMIZE=false
AUTO_SSH_SECURITY=false
AUTO_UPDATE_SETUP=false

# 高级配置
PARALLEL_DOWNLOADS=3
ENABLE_MODULE_VERIFICATION=true
NETWORK_TIMEOUT=30
EOF
    fi
}

# --- 模块完整性验证 ---
verify_module() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    
    # 简单的文件头验证
    if ! head -n 1 "$module_file" | grep -q "^#!/bin/bash"; then
        log "模块 $module_name 格式验证失败" "error"
        return 1
    fi
    
    # 检查文件大小（防止下载不完整）
    local file_size=$(stat -c%s "$module_file" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 100 ]; then
        log "模块 $module_name 文件过小，可能下载不完整" "error"
        return 1
    fi
    
    debug_log "模块 $module_name 验证通过 (大小: ${file_size} 字节)"
    return 0
}

# --- 增强的模块下载 ---
download_module_with_retry() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        debug_log "下载模块 $module_name (尝试 $((retry_count + 1))/$max_retries)"
        
        if curl -fsSL --connect-timeout 10 --max-time 30 \
               -H "User-Agent: debian-setup/$SCRIPT_VERSION" \
               "$MODULE_BASE_URL/${module_name}.sh" -o "$module_file"; then
            
            # 验证下载的文件
            if verify_module "$module_name"; then
                chmod +x "$module_file"
                debug_log "模块 $module_name 下载并验证成功"
                return 0
            else
                rm -f "$module_file"
                log "模块 $module_name 验证失败，重试..." "warn"
            fi
        else
            debug_log "模块 $module_name 下载失败"
        fi
        
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            sleep $((retry_count * 2))  # 指数退避
        fi
    done
    
    log "模块 $module_name 下载失败 ($max_retries 次尝试)" "error"
    return 1
}

# --- 并行下载模块 ---  
download_modules_parallel() {
    local modules=("$@")
    local total=${#modules[@]}
    local completed=0
    local pids=()
    local results=()
    
    log "并行下载 $total 个模块..." "info"
    
    # 限制并行数量
    local max_parallel=${PARALLEL_DOWNLOADS:-3}
    local active_jobs=0
    
    for module in "${modules[@]}"; do
        # 控制并行数量
        while [ $active_jobs -ge $max_parallel ]; do
            wait -n  # 等待任意一个后台任务完成
            ((active_jobs--))
            ((completed++))
            show_progress $completed $total "下载进度"
        done
        
        # 启动下载任务
        (
            if download_module_with_retry "$module"; then
                echo "SUCCESS:$module"
            else
                echo "FAILED:$module"
            fi
        ) &
        
        pids+=($!)
        ((active_jobs++))
    done
    
    # 等待所有任务完成
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((completed++))
            show_progress $completed $total "下载进度"
        fi
    done
    
    echo
    log "模块下载完成" "info"
}
# --- 状态文件管理（JSON安全处理） ---
init_status_file() {
    if [ ! -f "$STATUS_FILE" ]; then
        log "初始化状态文件: $STATUS_FILE" "info"
        cat > "$STATUS_FILE" << 'EOF'
{
  "script_version": "",
  "last_run": "",
  "executed_modules": [],
  "failed_modules": [],
  "skipped_modules": [],
  "system_info": {},
  "module_status": {}
}
EOF
    fi
}
save_module_status() {
    local module="$1"
    local status="$2"  # SUCCESS, FAILED, SKIPPED
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # 确保jq可用
    if ! command -v jq &>/dev/null; then
        # 如果没有jq，使用简单的手工方法
        debug_log "jq 不可用，使用备用方法保存状态"
        return 0
    fi
    
    local temp_file="${STATUS_FILE}.tmp"
    
    jq --arg module "$module" \
       --arg status "$status" \
       --arg timestamp "$timestamp" \
       --arg version "$SCRIPT_VERSION" \
       --arg last_run "$(date '+%Y-%m-%d %H:%M:%S')" \
       '.script_version = $version |
        .last_run = $last_run |
        .module_status[$module] = {
          "status": $status,
          "timestamp": $timestamp,
          "version": $version
        }' "$STATUS_FILE" > "$temp_file" && mv "$temp_file" "$STATUS_FILE"
    
    debug_log "模块 $module 状态已保存: $status"
}
update_final_status() {
    if ! command -v jq &>/dev/null; then
        # 手工构建JSON（备用方案）
        cat > "$STATUS_FILE" << EOF
{
  "script_version": "$SCRIPT_VERSION",
  "last_run": "$(date '+%Y-%m-%d %H:%M:%S')",
  "executed_modules": [$(printf '"%s",' "${EXECUTED_MODULES[@]}" | sed 's/,$//')],
  "failed_modules": [$(printf '"%s",' "${FAILED_MODULES[@]}" | sed 's/,$//')],
  "skipped_modules": [$(printf '"%s",' "${SKIPPED_MODULES[@]}" | sed 's/,$//')],
  "system_info": {
    "os": "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')",
    "kernel": "$(uname -r)",
    "ssh_port": "$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '22')",
    "hostname": "$(hostname)",
    "cpu_cores": "$(nproc)",
    "memory": "$(free -h | awk '/^Mem:/ {print $2}')"
  }
}
EOF
        return 0
    fi
    
    # 使用jq更新完整状态
    local temp_file="${STATUS_FILE}.tmp"
    
    jq --arg version "$SCRIPT_VERSION" \
       --arg last_run "$(date '+%Y-%m-%d %H:%M:%S')" \
       --argjson executed "$(printf '"%s",' "${EXECUTED_MODULES[@]}" | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')" \
       --argjson failed "$(printf '"%s",' "${FAILED_MODULES[@]}" | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')" \
       --argjson skipped "$(printf '"%s",' "${SKIPPED_MODULES[@]}" | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')" \
       '.script_version = $version |
        .last_run = $last_run |
        .executed_modules = $executed |
        .failed_modules = $failed |
        .skipped_modules = $skipped |
        .system_info = {
          "os": "'"$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')"'",
          "kernel": "'"$(uname -r)"'",
          "ssh_port": "'"$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '22')"'",
          "hostname": "'"$(hostname)"'",
          "cpu_cores": "'"$(nproc)"'",
          "memory": "'"$(free -h | awk '/^Mem:/ {print $2}')"'"
        }' "$STATUS_FILE" > "$temp_file" && mv "$temp_file" "$STATUS_FILE"
}
# --- 增强的模块执行 ---
execute_module_safe() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    local start_time=$(date +%s)
    
    if [ ! -f "$module_file" ]; then
        log "模块文件不存在: $module_file" "error"
        return 1
    fi
    
    log "执行模块: $module_name" "title"
    debug_log "模块执行开始: $module_name"
    
    # 创建模块专用的临时目录
    local module_temp_dir="$TEMP_DIR/${module_name}_temp"
    mkdir -p "$module_temp_dir"
    
    # 设置模块执行环境
    export MODULE_TEMP_DIR="$module_temp_dir"
    export MODULE_LOG_FILE="$LOG_FILE"
    export MODULE_DEBUG_MODE="$DEBUG_MODE"
    
    # 执行模块（在子shell中，避免污染主环境）
    local exit_code=0
    (
        cd "$module_temp_dir"
        bash "$module_file" 2>&1 | while IFS= read -r line; do
            echo "  [$module_name] $line"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [$module_name] $line" >> "$LOG_FILE"
        done
    ) || exit_code=$?
    
    # 清理模块临时目录
    rm -rf "$module_temp_dir" 2>/dev/null || true
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ]; then
        log "模块 $module_name 执行成功 (耗时: ${duration}s)" "info"
        debug_log "模块执行成功: $module_name, 耗时: ${duration}s"
        save_module_status "$module_name" "SUCCESS"
        return 0
    else
        log "模块 $module_name 执行失败 (耗时: ${duration}s, 退出码: $exit_code)" "error"
        debug_log "模块执行失败: $module_name, 退出码: $exit_code, 耗时: ${duration}s"
        save_module_status "$module_name" "FAILED"
        return 1
    fi
}
# --- 智能用户交互 ---
ask_user_module() {
    local module_name="$1"
    local description="$2"
    local default="$3"
    
    # 批量模式直接返回默认值
    if [ "$BATCH_MODE" = true ]; then
        debug_log "批量模式: 模块 $module_name 使用默认选择: $default"
        [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
    
    # 检查配置文件中的预设
    local config_var="AUTO_${module_name^^}"
    config_var="${config_var//-/_}"  # 替换连字符为下划线
    
    if [ -n "${!config_var:-}" ]; then
        local config_value="${!config_var}"
        if [ "$config_value" = "true" ]; then
            log "配置文件设置: 自动执行 $description" "info"
            return 0
        elif [ "$config_value" = "false" ]; then
            log "配置文件设置: 跳过 $description" "info"
            return 1
        fi
    fi
    
    # 交互式询问
    while true; do
        read -p "是否执行 $description 模块? (Y/n/s=跳过所有): " choice
        choice="${choice:-$default}"
        
        case "$choice" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            [Ss]|[Ss][Kk][Ii][Pp])
                log "用户选择跳过所有剩余模块" "warn"
                BATCH_MODE=true
                return 1
                ;;
            *) 
                echo "请输入 Y(是), N(否), 或 S(跳过所有)"
                continue
                ;;
        esac
    done
}
# --- 参数解析 ---
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --batch|-b)
                BATCH_MODE=true
                log "启用批量模式" "info"
                shift
                ;;
            --debug|-d)
                DEBUG_MODE=true
                log "启用调试模式" "debug"
                shift
                ;;
            --yes|-y)
                BATCH_MODE=true
                # 设置所有模块为自动执行
                export AUTO_SYSTEM_OPTIMIZE=true
                export AUTO_ZSH_SETUP=true
                export AUTO_MISE_SETUP=true
                export AUTO_DOCKER_SETUP=true
                export AUTO_NETWORK_OPTIMIZE=true
                export AUTO_SSH_SECURITY=true
                export AUTO_UPDATE_SETUP=true
                log "启用全自动模式" "info"
                shift
                ;;
            --config|-c)
                if [ -n "${2:-}" ]; then
                    CONFIG_FILE="$2"
                    shift 2
                else
                    log "错误: --config 需要指定配置文件路径" "error"
                    exit 1
                fi
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "Debian Setup Script v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                log "未知参数: $1" "error"
                log "使用 --help 查看帮助" "info"
                exit 1
                ;;
        esac
    done
}
show_help() {
    cat << 'EOF'
Debian 系统部署脚本 v2.1.0
用法: debian_setup.sh [选项]
选项:
  -b, --batch           批量模式（使用配置文件或默认设置）
  -y, --yes             全自动模式（所有模块都自动执行）
  -d, --debug           调试模式（显示详细日志）
  -c, --config FILE     指定配置文件路径
  -h, --help            显示此帮助信息
  -v, --version         显示版本信息
配置文件:
  默认位置: /etc/debian-setup.conf
  可以预设各模块的执行选项，避免交互式询问
日志文件:
  /var/log/debian-setup.log
示例:
  debian_setup.sh --batch           # 使用配置文件批量执行
  debian_setup.sh --yes             # 全自动执行所有模块
  debian_setup.sh --debug           # 调试模式运行
  debian_setup.sh -c my.conf        # 使用自定义配置文件
EOF
}
# --- 系统环境检查增强版 ---
check_system_requirements() {
    log "检查系统环境..." "info"
    
    # 检查是否为root用户
    if [ "$(id -u)" != "0" ]; then
        log "此脚本必须以 root 用户身份运行" "error"
        log "请使用: sudo $0 或切换到 root 用户" "error"
        exit 1
    fi
    
    # 检查是否为Debian系统
    if [ ! -f /etc/debian_version ]; then
        log "此脚本仅适用于 Debian 系统" "error"
        log "当前系统: $(uname -s)" "error"
        exit 1
    fi
    
    # 检查Debian版本
    local debian_version
    debian_version=$(cut -d. -f1 < /etc/debian_version 2>/dev/null || echo "0")
    
    if ! [[ "$debian_version" =~ ^[0-9]+$ ]]; then
        # 处理测试版本（如 "bookworm/sid"）
        if grep -q "bookworm\|12" /etc/debian_version; then
            debian_version=12
        elif grep -q "bullseye\|11" /etc/debian_version; then
            debian_version=11
        else
            debian_version=0
        fi
    fi
    
    if [ "$debian_version" -lt 11 ]; then
        log "警告: 此脚本为 Debian 11+ 优化" "warn"
        log "当前版本: $(cat /etc/debian_version)" "warn"
        
        if [ "$BATCH_MODE" != true ]; then
            read -p "确定继续? (y/n): " continue_install
            [[ "$continue_install" != "y" ]] && exit 1
        else
            log "批量模式: 继续执行（可能存在兼容性问题）" "warn"
        fi
    else
        log "系统版本检查通过: Debian $(cat /etc/debian_version)" "info"
    fi
    
    # 检查磁盘空间
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=2097152  # 2GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "警告: 磁盘空间不足 (可用: $((available_space/1024))MB, 建议: 2GB+)" "warn"
        
        if [ "$BATCH_MODE" != true ]; then
            read -p "继续执行? (y/n): " continue_install
            [[ "$continue_install" != "y" ]] && exit 1
        fi
    else
        debug_log "磁盘空间检查通过: $((available_space/1024))MB 可用"
    fi
    
    # 检查内存
    local total_mem
    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    
    if [ "$total_mem" -lt 512 ]; then
        log "警告: 内存较低 (${total_mem}MB)，可能影响部分功能" "warn"
    else
        debug_log "内存检查通过: ${total_mem}MB"
    fi
    
    log "系统环境检查完成" "info"
}
# --- 初始化函数 ---
initialize_script() {
    # 解析命令行参数
    parse_arguments "$@"
    
    # 设置日志
    setup_logging
    
    # 加载配置
    load_config
    
    # 创建默认配置（如果不存在）
    create_default_config
    
    # 初始化状态文件
    init_status_file
    
    # 检查是否为重复运行
    if [ -f "$STATUS_FILE" ] && jq -e '.last_run' "$STATUS_FILE" &>/dev/null; then
        RERUN_MODE=true
        local last_run=$(jq -r '.last_run // "未知"' "$STATUS_FILE" 2>/dev/null)
        log "检测到之前的部署记录 (上次运行: $last_run)" "info"
        log "以更新模式执行" "info"
    fi
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    debug_log "临时目录已创建: $TEMP_DIR"
    
    log "脚本初始化完成" "info"
}
# --- 基础工具安装增强版 ---
install_essential_tools() {
    local essential_tools=("curl" "wget" "apt" "git" "jq")
    local missing_tools=()
    
    log "检查基础工具..." "info"
    
    # 检查缺失的工具
    for tool in "${essential_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
            debug_log "缺失工具: $tool"
        else
            debug_log "工具已安装: $tool"
        fi
    done
    
    # 安装缺失的工具
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "安装基础工具: ${missing_tools[*]}" "warn"
        
        # 更新软件包列表
        if ! apt-get update -qq 2>/dev/null; then
            log "软件包列表更新失败，尝试修复..." "warn"
            apt-get update --fix-missing -qq || step_fail 1 "无法更新软件包列表"
        fi
        
        # 安装工具
        for tool in "${missing_tools[@]}"; do
            log "安装 $tool..." "info"
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$tool"; then
                log "工具 $tool 安装失败" "error"
                if [[ "$tool" == "jq" ]]; then
                    log "jq 安装失败，将使用备用的JSON处理方法" "warn"
                else
                    step_fail 1 "关键工具 $tool 安装失败"
                fi
            else
                log "工具 $tool 安装成功" "info"
            fi
        done
    else
        log "所有基础工具已就绪" "info"
    fi
}
# --- 系统更新增强版 ---
perform_system_update() {
    log "开始系统更新..." "info"
    
    # 清理可能的锁文件
    if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null; then
        log "检测到正在运行的apt进程，等待完成..." "warn"
        while pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null; do
            sleep 5
        done
    fi
    
    # 移除可能的锁文件
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
    
    # 配置 dpkg
    dpkg --configure -a 2>/dev/null || true
    
    log "更新软件包列表..." "info"
    if ! apt update 2>&1 | tee -a "$LOG_FILE"; then
        log "软件包列表更新失败" "error"
        return 1
    fi
    
    # 根据运行模式选择更新策略
    if [ "$RERUN_MODE" = true ]; then
        log "更新模式: 执行软件包升级" "info"
        apt upgrade -y 2>&1 | tee -a "$LOG_FILE"
    else
        log "首次运行: 执行完整系统升级" "info"
        apt full-upgrade -y 2>&1 | tee -a "$LOG_FILE"
    fi
    
    # 安装核心软件包
    local core_packages=(
        "dnsutils"      # DNS工具
        "wget"          # 下载工具
        "curl"          # HTTP客户端
        "rsync"         # 同步工具
        "chrony"        # 时间同步
        "cron"          # 定时任务
        "iproute2"      # 网络工具
        "ca-certificates" # SSL证书
        "gnupg"         # GPG工具
        "lsb-release"   # 系统信息
        "software-properties-common" # 软件源管理
    )
    
    local missing_packages=()
    
    log "检查核心软件包..." "info"
    for pkg in "${core_packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
            debug_log "缺失软件包: $pkg"
        else
            debug_log "软件包已安装: $pkg"
        fi
    done
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log "安装核心软件包: ${missing_packages[*]}" "info"
        if ! DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "${missing_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            step_fail 2 "核心软件包安装失败"
        fi
    else
        log "所有核心软件包已安装" "info"
    fi
    
    # 修复 hosts 文件
    local hostname
    hostname=$(hostname)
    if ! grep -q "^127.0.1.1.*$hostname" /etc/hosts; then
        log "修复 hosts 文件" "info"
        sed -i "/^127.0.1.1/d" /etc/hosts
        echo "127.0.1.1 $hostname" >> /etc/hosts
        debug_log "hosts 文件已修复，添加: 127.0.1.1 $hostname"
    else
        debug_log "hosts 文件检查通过"
    fi
    
    # 清理不需要的软件包
    log "清理系统..." "info"
    apt autoremove -y &>/dev/null || true
    apt autoclean &>/dev/null || true
    
    log "系统更新完成" "info"
}
# --- 主要模块部署流程 ---
deploy_modules() {
    step_start 3 "模块化功能部署"
    
    # 定义可用模块
    declare -A MODULES=(
        ["system-optimize"]="系统优化 (Zram, 时区)"
        ["zsh-setup"]="Zsh Shell 环境 (Oh-My-Zsh + 主题插件)"
        ["mise-setup"]="Mise 版本管理器 (Python 环境)"
        ["docker-setup"]="Docker 容器化平台"
        ["network-optimize"]="网络性能优化 (BBR + cake)"
        ["ssh-security"]="SSH 安全配置"
        ["auto-update-setup"]="自动更新系统"
    )
    
    # 模块执行顺序（考虑依赖关系）
    local module_order=(
        "system-optimize"
        "zsh-setup"
        "mise-setup"
        "docker-setup"
        "network-optimize"
        "ssh-security"
        "auto-update-setup"
    )
    
    # 第一步：收集要执行的模块
    local selected_modules=()
    local total_modules=${#module_order[@]}
    
    log "模块选择阶段..." "title"
    for module in "${module_order[@]}"; do
        local description="${MODULES[$module]}"
        
        if ask_user_module "$module" "$description" "y"; then
            selected_modules+=("$module")
            log "✓ 已选择: $description" "info"
        else
            SKIPPED_MODULES+=("$module")
            log "⊝ 已跳过: $description" "warn"
            save_module_status "$module" "SKIPPED"
        fi
    done
    
    if [ ${#selected_modules[@]} -eq 0 ]; then
        log "未选择任何模块，跳过部署阶段" "warn"
        step_end 3 "模块化部署完成（无模块执行）"
        return 0
    fi
    
    log "将执行 ${#selected_modules[@]} 个模块: ${selected_modules[*]}" "title"
    
    # 第二步：并行下载选中的模块
    log "开始下载模块..." "title"
    download_modules_parallel "${selected_modules[@]}"
    
    # 第三步：按顺序执行模块
    log "开始执行模块..." "title"
    local current=0
    local total=${#selected_modules[@]}
    
    for module in "${selected_modules[@]}"; do
        ((current++))
        local description="${MODULES[$module]}"
        
        log "\n[$current/$total] 开始处理模块: $module" "title"
        log "描述: $description" "info"
        
        # 检查模块文件是否存在
        local module_file="$TEMP_DIR/${module}.sh"
        if [ ! -f "$module_file" ]; then
            log "模块文件不存在，尝试重新下载..." "warn"
            if ! download_module_with_retry "$module"; then
                FAILED_MODULES+=("$module")
                log "模块 $module 下载失败，跳过执行\n" "error"
                continue
            fi
        fi
        
        # 执行模块
        if execute_module_safe "$module"; then
            EXECUTED_MODULES+=("$module")
            log "✓ 模块 $module 执行成功\n" "info"
        else
            FAILED_MODULES+=("$module")
            log "✗ 模块 $module 执行失败，继续执行其他模块\n" "warn"
            
            # 询问是否继续
            if [ "$BATCH_MODE" != true ] && [ $current -lt $total ]; then
                read -p "是否继续执行剩余模块? (Y/n): " continue_choice
                if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
                    log "用户选择终止，跳过剩余模块" "warn"
                    # 将剩余模块标记为跳过
                    for ((i=current; i<total; i++)); do
                        local remaining_module="${selected_modules[$i]}"
                        SKIPPED_MODULES+=("$remaining_module")
                        save_module_status "$remaining_module" "SKIPPED"
                    done
                    break
                fi
            fi
        fi
        
        # 显示进度
        show_progress $current $total "模块执行进度"
    done
    
    step_end 3 "模块化部署完成"
}
# --- 生成部署摘要 ---
generate_deployment_summary() {
    step_start 4 "生成部署摘要"
    
    log "\n╔═════════════════════════════════════════╗" "title"
    log "║           系统部署完成摘要                ║" "title"
    log "╚═════════════════════════════════════════╝" "title"
    
    local show_info() { log " • $1: $2" "info"; }
    
    # 基本信息
    show_info "脚本版本" "$SCRIPT_VERSION"
    show_info "部署模式" "$(if [ "$RERUN_MODE" = true ]; then echo "更新模式"; else echo "首次部署"; fi)"
    show_info "执行模式" "$(if [ "$BATCH_MODE" = true ]; then echo "批量模式"; else echo "交互模式"; fi)"
    show_info "操作系统" "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')"
    show_info "内核版本" "$(uname -r)"
    show_info "CPU 核心" "$(nproc)"
    show_info "总内存" "$(free -h | grep Mem | awk '{print $2}')"
    show_info "执行时长" "$(date -d@$(($(date +%s) - ${SCRIPT_START_TIME:-$(date +%s)})) -u +%H:%M:%S)"
    
    # 模块执行统计
    local total_selected=$((${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]}))
    local success_rate=0
    if [ $total_selected -gt 0 ]; then
        success_rate=$((${#EXECUTED_MODULES[@]} * 100 / total_selected))
    fi
    
    show_info "模块统计" "成功: ${#EXECUTED_MODULES[@]}, 失败: ${#FAILED_MODULES[@]}, 跳过: ${#SKIPPED_MODULES[@]}"
    show_info "成功率" "${success_rate}%"
    
    # 成功执行的模块
    if [ ${#EXECUTED_MODULES[@]} -gt 0 ]; then
        log "\n✅ 成功执行的模块:" "info"
        for module in "${EXECUTED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "info"
        done
    fi
    
    # 失败的模块
    if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
        log "\n❌ 执行失败的模块:" "error"
        for module in "${FAILED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "error"
        done
        log "\n💡 提示: 检查日志文件了解失败原因: $LOG_FILE" "info"
    fi
    
    # 跳过的模块
    if [ ${#SKIPPED_MODULES[@]} -gt 0 ]; then
        log "\n⊝ 跳过的模块:" "warn"
        for module in "${SKIPPED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "warn"
        done
    fi
    
    # 系统状态检查
    log "\n📊 当前系统状态:" "info"
    
    # Zsh 状态
    if command -v zsh &>/dev/null; then
        local zsh_version
        zsh_version=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
        show_info "Zsh Shell" "已安装 (版本: $zsh_version)"
        
        local root_shell
        root_shell=$(getent passwd root | cut -d: -f7)
        if [ "$root_shell" = "$(which zsh)" ]; then
            show_info "默认 Shell" "Zsh"
        else
            show_info "默认 Shell" "Bash (可手动切换到 Zsh)"
        fi
    else
        show_info "Zsh Shell" "未安装"
    fi
    
    # Docker 状态
    if command -v docker &>/dev/null; then
        local docker_version containers_count
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        show_info "Docker" "已安装 (版本: $docker_version, 运行容器: $containers_count)"
    else
        show_info "Docker" "未安装"
    fi
    
    # Mise 状态
    if [ -f "$HOME/.local/bin/mise" ] || command -v mise &>/dev/null; then
        local mise_version
        mise_version=$(mise --version 2>/dev/null || echo "未知")
        show_info "Mise" "已安装 ($mise_version)"
    else
        show_info "Mise" "未安装"
    fi
    
    # 网络优化状态
    local curr_cc curr_qdisc
    curr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    curr_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    show_info "网络优化" "拥塞控制: $curr_cc, 队列调度: $curr_qdisc"
    
    # SSH 端口
    local ssh_port
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    show_info "SSH 端口" "$ssh_port"
    
    log "\n──────────────────────────────────────────────────" "title"
    log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "info"
    log "──────────────────────────────────────────────────\n" "title"
    
    step_end 4 "摘要生成完成"
}
# --- 最终清理和提示 ---
finalize_deployment() {
    log "保存部署状态..." "info"
    update_final_status
    
    log "✅ 所有部署任务完成!" "title"
    
    # SSH 端口变更提醒
    if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
        local new_ssh_port
        new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        if [ "$new_ssh_port" != "22" ] && [ -n "$new_ssh_port" ]; then
            log "⚠️  重要: SSH 端口已更改为 $new_ssh_port" "warn"
            log "   请使用新端口连接: ssh -p $new_ssh_port user@server" "warn"
            log "   确保防火墙允许新端口访问！" "warn"
        fi
    fi
    
    # Zsh 使用提示
    if [[ " ${EXECUTED_MODULES[*]} " =~ " zsh-setup " ]]; then
        log "🐚 Zsh 使用提示:" "info"
        log "   立即体验 Zsh: exec zsh" "info"
        log "   Powerlevel10k (Rainbow) 主题已就绪" "info"
    fi
    
    # Docker 使用提示
    if [[ " ${EXECUTED_MODULES[*]} " =~ " docker-setup " ]]; then
        log "🐳 Docker 使用提示:" "info"
        log "   检查服务状态: systemctl status docker" "info"
        log "   查看容器: docker ps" "info"
    fi
    
    # 通用提示
    log "🔄 可随时重新运行此脚本进行更新或维护:" "info"
    log "   $0 --batch    # 批量模式" "info"
    log "   $0 --debug    # 调试模式" "info"
    log "📄 状态文件: $STATUS_FILE" "info"
    log "📝 日志文件: $LOG_FILE" "info"
    
    # 如果有失败的模块，提供重试建议
    if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
        log "\n🔧 失败模块重试建议:" "warn"
        log "   1. 检查日志文件: cat $LOG_FILE" "info"
        log "   2. 修复问题后重新运行脚本" "info"
        log "   3. 或者单独重新执行失败的模块" "info"
    fi
    
    # 输出性能统计
    if [ "$DEBUG_MODE" = true ]; then
        local total_time=$(($(date +%s) - ${SCRIPT_START_TIME:-$(date +%s)}))
        log "\n📈 性能统计:" "debug"
        log "   总执行时间: ${total_time}s" "debug"
        log "   成功模块数: ${#EXECUTED_MODULES[@]}" "debug"
        log "   平均每模块: $((total_time / (${#EXECUTED_MODULES[@]} + 1)))s" "debug"
    fi
}
# --- 主函数 ---
main() {
    # 记录脚本开始时间
    export SCRIPT_START_TIME=$(date +%s)
    
    log "╔═══════════════════════════════════════════════════╗" "title"
    log "║   Debian 系统部署脚本 v$SCRIPT_VERSION (优化版)          ║" "title"
    log "║   开始时间: $(date '+%Y-%m-%d %H:%M:%S %Z')                ║" "title"
    log "╚═══════════════════════════════════════════════════╝" "title"
    
    # 初始化脚本环境
    initialize_script "$@"
    
    # 步骤 1: 基础环境检查
    step_start 1 "基础环境检查和准备"
    check_system_requirements
    
    # 网络检查
    if ! network_check; then
        if [ "$BATCH_MODE" != true ]; then
            read -p "网络连接存在问题，是否继续执行? (y/n): " continue_install
            [[ "$continue_install" != "y" ]] && exit 1
        else
            log "批量模式: 网络异常但继续执行" "warn"
        fi
    fi
    
    # 安装基础工具
    install_essential_tools
    step_end 1 "基础环境就绪"
    
    # 步骤 2: 系统更新
    step_start 2 "系统更新"
    perform_system_update
    step_end 2 "系统更新完成"
    
    # 步骤 3: 模块化部署
    deploy_modules
    
    # 步骤 4: 部署摘要
    generate_deployment_summary
    
    # 最终清理
    finalize_deployment
    
    # 根据执行结果确定退出码
    if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
        log "部署完成，但存在失败的模块" "warn"
        exit 2  # 部分失败
    else
        log "部署完成，所有选定模块执行成功" "info"
        exit 0  # 完全成功
    fi
}
# --- 脚本入口点 ---
# 确保脚本直接执行而非被source
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
else
    log "错误: 此脚本应该直接执行，而不是被 source" "error"
    return 1 2>/dev/null || exit 1
fi
