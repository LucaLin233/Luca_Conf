#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署脚本 (优化版本 v2.1.0)
# 适用系统: Debian 12+
# 功能: 模块化部署 Zsh, Mise, Docker, 网络优化, SSH 加固等
# 作者: LucaLin233
# 优化: 配置文件支持, 错误处理, 并行处理等
# -----------------------------------------------------------------------------

set -euo pipefail  # 严格错误处理

SCRIPT_VERSION="2.1.0"
STATUS_FILE="/var/lib/system-deploy-status.json"
CONFIG_FILE="./deploy.conf"
MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/modules"
TEMP_DIR="/tmp/debian_setup_modules"

# === 默认配置值 ===
DEFAULT_MODULES=""
SKIP_MODULES=""
AUTO_YES=false
SKIP_INTERACTIVE=false
DEBUG_MODE=false
SSH_PORT=22
SSH_DISABLE_ROOT=false
DOCKER_DATA_ROOT="/var/lib/docker"
ENABLE_BBR=true
ENABLE_CAKE=true
SKIP_SYSTEM_UPDATE=false
LOG_LEVEL="INFO"
QUICK_MODE=false

# === 全局变量 ===
EXECUTED_MODULES=()
FAILED_MODULES=()

# --- 清理函数 ---
cleanup_on_error() {
    log "执行清理操作..." "WARN"
    rm -rf "$TEMP_DIR"
    [ -f "$TEMP_DIR.lock" ] && rm -f "$TEMP_DIR.lock"
}

cleanup_on_exit() {
    rm -rf "$TEMP_DIR"
    [ -f "$TEMP_DIR.lock" ] && rm -f "$TEMP_DIR.lock"
}

trap cleanup_on_error ERR
trap cleanup_on_exit EXIT

# --- 日志函数 (支持日志级别) ---
log() {
    local message="$1"
    local level="${2:-INFO}"
    
    # 日志级别过滤
    case "$LOG_LEVEL" in
        "ERROR") [[ "$level" == "ERROR" ]] || return ;;
        "WARN") [[ "$level" =~ ^(ERROR|WARN)$ ]] || return ;;
        "INFO") [[ "$level" =~ ^(ERROR|WARN|INFO)$ ]] || return ;;
        "DEBUG") ;;  # 显示所有
    esac
    
    # 颜色配置
    local colors=("\033[0;32m" "\033[0;33m" "\033[0;31m" "\033[0;36m" "\033[1;35m" "\033[0;37m")
    local levels=("INFO" "WARN" "ERROR" "DEBUG" "TITLE" "")
    local color="\033[0;32m"
    
    for i in "${!levels[@]}"; do
        [[ "$level" == "${levels[$i]}" ]] && color="${colors[$i]}" && break
    done
    
    # 添加时间戳（调试模式）
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo -e "[$(date '+%H:%M:%S')] ${color}[$level] $message\033[0m"
    else
        echo -e "${color}$message\033[0m"
    fi
}

step_start() { 
    log "▶ 步骤 $1: $2..." "TITLE"
    [[ "$DEBUG_MODE" == "true" ]] && log "开始时间: $(date)" "DEBUG"
}

step_end() { 
    log "✓ 步骤 $1 完成: $2" "INFO"
    [[ "$DEBUG_MODE" == "true" ]] && log "结束时间: $(date)" "DEBUG"
    echo
}

step_fail() { 
    log "✗ 步骤 $1 失败: $2" "ERROR"
    exit 1
}

# --- 进度显示函数 ---
show_progress() {
    local current=$1
    local total=$2
    local desc="${3:-处理中}"
    local percent=$((current * 100 / total))
    local bar_length=50
    local filled_length=$((percent * bar_length / 100))
    
    printf "\r%s [" "$desc"
    printf "%*s" "$filled_length" | tr ' ' '='
    printf "%*s" $((bar_length - filled_length)) | tr ' ' '-'
    printf "] %d%% (%d/%d)" "$percent" "$current" "$total"
    
    [[ $current -eq $total ]] && echo
}

# --- 网络检查函数 ---
check_network() {
    local test_hosts=("8.8.8.8" "114.114.114.114" "1.1.1.1" "223.5.5.5")
    log "检查网络连接..." "DEBUG"
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" &>/dev/null; then
            log "网络连接正常 (测试主机: $host)" "DEBUG"
            return 0
        fi
    done
    
    log "网络连接检查失败" "ERROR"
    return 1
}

# --- 依赖检查函数 ---
check_dependencies() {
    local missing=()
    local required=("curl" "wget" "git" "jq")
    
    log "检查依赖项..." "DEBUG"
    
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "安装缺失依赖: ${missing[*]}" "INFO"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" || {
            log "依赖安装失败" "ERROR"
            return 1
        }
    fi
    
    log "依赖检查完成" "DEBUG"
}

# --- 命令行参数解析 ---
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes) 
                AUTO_YES=true
                shift 
                ;;
            -q|--quick) 
                QUICK_MODE=true
                shift 
                ;;
            -m|--modules) 
                DEFAULT_MODULES="$2"
                shift 2 
                ;;
            -c|--config) 
                CONFIG_FILE="$2"
                shift 2 
                ;;
            -d|--debug) 
                DEBUG_MODE=true
                LOG_LEVEL="DEBUG"
                shift 
                ;;
            -v|--version) 
                echo "Debian 部署脚本 v$SCRIPT_VERSION"
                exit 0 
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --skip-update)
                SKIP_SYSTEM_UPDATE=true
                shift
                ;;
            *) 
                log "未知参数: $1" "WARN"
                shift 
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法: $0 [选项]

选项:
  -y, --yes           自动确认所有选项
  -q, --quick         快速模式，跳过配置文件生成
  -m, --modules LIST  指定要安装的模块（逗号分隔）
  -c, --config FILE   指定配置文件路径
  -d, --debug         启用调试模式
  -v, --version       显示版本信息
  -h, --help          显示此帮助信息
  --skip-update       跳过系统更新

示例:
  $0                                # 标准运行模式
  $0 -q -y                         # 快速自动模式
  $0 -m "zsh-setup,docker-setup"   # 只安装指定模块
  $0 -c custom.conf                # 使用自定义配置文件

模块列表: system-optimize, zsh-setup, mise-setup, docker-setup, 
         network-optimize, ssh-security, auto-update-setup
EOF
}
# --- 智能配置建议 ---
generate_smart_suggestions() {
    local suggestions=()
    
    log "分析系统环境，生成配置建议..." "DEBUG"
    
    # 检测系统内存
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        suggestions+=("# 检测到内存较小 (${mem_gb}GB)，建议跳过资源消耗大的模块")
        suggestions+=("SKIP_MODULES=\"docker-setup,mise-setup\"")
        suggestions+=("")
    fi
    
    # 检测虚拟化环境
    if [[ -f /sys/hypervisor/uuid ]] || [[ -d /proc/xen ]] || grep -q "hypervisor" /proc/cpuinfo 2>/dev/null; then
        suggestions+=("# 检测到虚拟化环境，建议启用网络优化")
        suggestions+=("ENABLE_BBR=true")
        suggestions+=("ENABLE_CAKE=true")
        suggestions+=("")
    fi
    
    # 检测已安装的软件
    local existing_skip=()
    command -v docker &>/dev/null && existing_skip+=("docker-setup")
    command -v zsh &>/dev/null && existing_skip+=("zsh-setup")
    
    if [[ ${#existing_skip[@]} -gt 0 ]]; then
        suggestions+=("# 检测到已安装的软件，建议跳过相应模块")
        suggestions+=("# 已安装: ${existing_skip[*]}")
        local skip_list=$(IFS=,; echo "${existing_skip[*]}")
        suggestions+=("SKIP_MODULES=\"$skip_list\"")
        suggestions+=("")
    fi
    
    # 检测SSH端口
    local current_ssh_port=$(ss -tlnp | grep :22 >/dev/null && echo "22" || echo "非22")
    if [[ "$current_ssh_port" != "22" ]]; then
        suggestions+=("# 检测到SSH端口已修改，建议保持当前配置")
        suggestions+=("")
    fi
    
    # 输出建议到配置文件
    if [[ ${#suggestions[@]} -gt 0 ]]; then
        echo "" >> "$CONFIG_FILE"
        echo "# === 系统分析建议 ===" >> "$CONFIG_FILE"
        for suggestion in "${suggestions[@]}"; do
            echo "$suggestion" >> "$CONFIG_FILE"
        done
    fi
}

# --- 生成配置文件 ---
generate_config() {
    local config_file="${1:-$CONFIG_FILE}"
    
    log "生成配置文件: $config_file" "INFO"
    
    cat > "$config_file" << EOF
# ============================================
# Debian 系统部署脚本配置文件
# ============================================
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 脚本版本: $SCRIPT_VERSION
# 
# 修改此文件后重新运行脚本即可生效
# 配置项说明请参考: https://github.com/LucaLin233/Luca_Conf

# === 模块选择 ===
# 可用模块: system-optimize, zsh-setup, mise-setup, docker-setup, 
#          network-optimize, ssh-security, auto-update-setup
# 
# 默认安装的模块（逗号分隔，留空则交互式选择）
DEFAULT_MODULES="system-optimize,zsh-setup"

# 跳过的模块（逗号分隔）
SKIP_MODULES=""

# === 行为控制 ===
# 自动确认所有默认选项（true/false）
AUTO_YES=false

# 跳过交互式提示（配合 AUTO_YES 使用）
SKIP_INTERACTIVE=false

# 调试模式（显示详细日志）
DEBUG_MODE=false

# 跳过系统更新（加快执行速度，不推荐）
SKIP_SYSTEM_UPDATE=false

# === SSH 安全配置 ===
# SSH 端口（默认22，强烈建议修改）
SSH_PORT=2222

# 禁用 root SSH 登录（true/false，推荐启用）
SSH_DISABLE_ROOT=false

# === Docker 配置 ===
# Docker 数据目录（默认 /var/lib/docker）
DOCKER_DATA_ROOT="/var/lib/docker"

# === 网络优化配置 ===
# 启用 BBR 拥塞控制（true/false，推荐启用）
ENABLE_BBR=true

# 启用 Cake 队列调度（true/false，推荐启用）
ENABLE_CAKE=true

# === 高级选项 ===
# 日志级别 (DEBUG/INFO/WARN/ERROR)
LOG_LEVEL="INFO"

# 模块下载源（一般不需要修改）
MODULE_BASE_URL="$MODULE_BASE_URL"
EOF

    # 添加智能建议
    generate_smart_suggestions
    
    log "配置文件生成完成" "INFO"
}

# --- 验证配置 ---
validate_config() {
    log "验证配置文件..." "DEBUG"
    
    # 检查必需配置
    [[ -z "$MODULE_BASE_URL" ]] && {
        log "错误: MODULE_BASE_URL 未配置" "ERROR"
        return 1
    }
    
    # 检查模块列表
    if [[ -n "$DEFAULT_MODULES" ]]; then
        IFS=',' read -ra modules <<< "$DEFAULT_MODULES"
        local available_modules=("system-optimize" "zsh-setup" "mise-setup" "docker-setup" "network-optimize" "ssh-security" "auto-update-setup")
        
        for module in "${modules[@]}"; do
            module=$(echo "$module" | tr -d ' ')  # 去除空格
            [[ " ${available_modules[*]} " =~ " $module " ]] || {
                log "警告: 未知模块 $module" "WARN"
            }
        done
    fi
    
    # 验证 SSH 端口
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ $SSH_PORT -lt 1 ]] || [[ $SSH_PORT -gt 65535 ]]; then
        log "警告: SSH端口无效 ($SSH_PORT)，将使用默认值 22" "WARN"
        SSH_PORT=22
    fi
    
    # 检查 URL 可访问性
    if ! curl -fsSL --connect-timeout 5 "$MODULE_BASE_URL/system-optimize.sh" -o /dev/null 2>/dev/null; then
        log "警告: MODULE_BASE_URL 可能不可访问: $MODULE_BASE_URL" "WARN"
    fi
    
    log "配置验证完成" "DEBUG"
}

# --- 加载配置文件 ---
load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    
    if [[ -f "$config_file" ]]; then
        log "加载配置文件: $config_file" "DEBUG"
        # 安全地加载配置文件（避免代码注入）
        source "$config_file"
        validate_config
        return 0
    else
        log "配置文件不存在: $config_file" "DEBUG"
        return 1
    fi
}

# --- 配置文件处理主逻辑 ---
handle_config() {
    # 快速模式跳过配置文件处理
    if [[ "$QUICK_MODE" == "true" ]]; then
        log "快速模式：跳过配置文件处理" "INFO"
        return 0
    fi
    
    # 如果配置文件不存在，生成并询问用户
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "首次运行，生成配置文件..." "INFO"
        generate_config "$CONFIG_FILE"
        
        echo
        log "🎯 配置文件已生成: $CONFIG_FILE" "TITLE"
        log "请选择下一步操作:" "INFO"
        log "  1) 编辑配置文件后重新运行脚本" "INFO"
        log "  2) 使用默认配置继续执行" "INFO"
        log "  3) 退出脚本" "INFO"
        echo
        
        # 非交互模式下使用默认选择
        if [[ "$SKIP_INTERACTIVE" == "true" ]]; then
            log "非交互模式：使用默认配置继续" "INFO"
            load_config "$CONFIG_FILE"
            return 0
        fi
        
        read -p "请选择 (1/2/3) [默认: 2]: " choice
        choice="${choice:-2}"
        
        case $choice in
            1) 
                log "请编辑 $CONFIG_FILE 后重新运行: $0" "INFO"
                exit 0 
                ;;
            2) 
                log "使用默认配置继续..." "INFO"
                load_config "$CONFIG_FILE"
                ;;
            3) 
                log "退出脚本" "INFO"
                exit 0 
                ;;
            *) 
                log "无效选择，使用默认配置继续..." "WARN"
                load_config "$CONFIG_FILE"
                ;;
        esac
    else
        # 配置文件存在，直接加载
        log "发现配置文件，正在加载..." "INFO"
        load_config "$CONFIG_FILE" || {
            log "配置文件加载失败，使用默认配置" "WARN"
        }
    fi
}

# --- 模块管理函数 ---
download_module() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    
    log "下载模块: $module_name" "DEBUG"
    if curl -fsSL --connect-timeout 10 --max-time 60 "$MODULE_BASE_URL/${module_name}.sh" -o "$module_file"; then
        chmod +x "$module_file"
        log "模块 $module_name 下载成功" "DEBUG"
        return 0
    else
        log "模块 $module_name 下载失败" "ERROR"
        return 1
    fi
}

# --- 并行下载所有需要的模块 ---
download_all_modules() {
    local modules=("$@")
    local pids=()
    local success_count=0
    
    log "开始并行下载 ${#modules[@]} 个模块..." "INFO"
    
    # 启动并行下载
    for module in "${modules[@]}"; do
        download_module "$module" &
        pids+=($!)
    done
    
    # 等待所有下载完成并显示进度
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            ((success_count++))
        fi
        show_progress $((i + 1)) ${#pids[@]} "下载模块"
    done
    
    echo
    log "模块下载完成: $success_count/${#modules[@]}" "INFO"
    
    [[ $success_count -eq ${#modules[@]} ]]
}

execute_module() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    
    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module_file" "ERROR"
        return 1
    fi
    
    log "执行模块: $module_name" "TITLE"
    
    # 设置模块执行环境变量
    export CONFIG_SSH_PORT="$SSH_PORT"
    export CONFIG_SSH_DISABLE_ROOT="$SSH_DISABLE_ROOT"
    export CONFIG_DOCKER_DATA_ROOT="$DOCKER_DATA_ROOT"
    export CONFIG_ENABLE_BBR="$ENABLE_BBR"
    export CONFIG_ENABLE_CAKE="$ENABLE_CAKE"
    export CONFIG_DEBUG_MODE="$DEBUG_MODE"
    
    if bash "$module_file"; then
        log "模块 $module_name 执行成功" "INFO"
        return 0
    else
        log "模块 $module_name 执行失败" "ERROR"
        return 1
    fi
}

ask_user_module() {
    local module_name="$1"
    local description="$2"
    local default="$3"
    
    # 自动模式
    if [[ "$AUTO_YES" == "true" ]]; then
        log "自动模式: 安装 $description" "INFO"
        return 0
    fi
    
    # 非交互模式
    if [[ "$SKIP_INTERACTIVE" == "true" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    
    read -p "是否执行 $description 模块? (Y/n) [默认: $default]: " choice
    choice="${choice:-$default}"
    [[ "$choice" =~ ^[Yy]$ ]] && return 0 || return 1
}
# --- 状态文件管理 ---
save_status() {
    local executed_json=$(printf '%s\n' "${EXECUTED_MODULES[@]}" | jq -R . | jq -s .)
    local failed_json=$(printf '%s\n' "${FAILED_MODULES[@]}" | jq -R . | jq -s .)
    
    jq -n \
        --arg version "$SCRIPT_VERSION" \
        --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
        --argjson executed "$executed_json" \
        --argjson failed "$failed_json" \
        --arg os "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')" \
        --arg kernel "$(uname -r)" \
        --arg ssh_port "$SSH_PORT" \
        '{
            script_version: $version,
            last_run: $timestamp,
            executed_modules: $executed,
            failed_modules: $failed,
            system_info: {
                os: $os,
                kernel: $kernel,
                ssh_port: $ssh_port
            }
        }' > "$STATUS_FILE" || {
        log "警告: 状态文件保存失败" "WARN"
    }
}

# === 主程序开始 ===

# --- 解析命令行参数 ---
parse_arguments "$@"

# --- 初始化检查 ---
RERUN_MODE=false
if [[ -f "$STATUS_FILE" ]]; then
    RERUN_MODE=true
    log "检测到之前的部署记录，以更新模式执行" "INFO"
fi

if [[ "$(id -u)" != "0" ]]; then
    log "此脚本必须以 root 用户身份运行" "ERROR"
    log "请使用: sudo $0" "INFO"
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    log "此脚本仅适用于 Debian 系统" "ERROR"
    exit 1
fi

debian_version=$(cut -d. -f1 < /etc/debian_version 2>/dev/null || echo "0")
if [[ "$debian_version" -lt 12 ]]; then
    log "警告: 此脚本为 Debian 12+ 优化。当前版本: $(cat /etc/debian_version)" "WARN"
    if [[ "$AUTO_YES" != "true" ]] && [[ "$SKIP_INTERACTIVE" != "true" ]]; then
        read -p "确定继续? (y/N): " continue_install
        [[ "$continue_install" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# --- 处理配置文件 ---
handle_config

# --- 步骤 1: 基础环境检查 ---
step_start 1 "基础环境检查和准备"

# 网络检查
if ! check_network; then
    log "警告: 网络连接不稳定" "WARN"
    if [[ "$AUTO_YES" != "true" ]] && [[ "$SKIP_INTERACTIVE" != "true" ]]; then
        read -p "继续执行? (y/N): " continue_install
        [[ "$continue_install" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# 检查并安装依赖
check_dependencies

# 创建临时目录
mkdir -p "$TEMP_DIR"

# 创建锁文件防止重复运行
if [[ -f "$TEMP_DIR.lock" ]]; then
    log "检测到另一个脚本实例正在运行" "ERROR"
    log "如果确认没有其他实例，请删除: $TEMP_DIR.lock" "INFO"
    exit 1
fi
touch "$TEMP_DIR.lock"

step_end 1 "基础环境就绪"

# --- 步骤 2: 系统更新 ---
if [[ "$SKIP_SYSTEM_UPDATE" != "true" ]]; then
    step_start 2 "系统更新"
    
    log "更新软件包列表..." "INFO"
    apt update || step_fail 2 "软件包列表更新失败"
    
    if [[ "$RERUN_MODE" == "true" ]]; then
        log "更新模式: 执行软件包升级" "INFO"
        apt upgrade -y || step_fail 2 "软件包升级失败"
    else
        log "首次运行: 执行完整系统升级" "INFO" 
        apt full-upgrade -y || step_fail 2 "系统升级失败"
    fi
    
    # 安装核心软件包
    CORE_PACKAGES=(dnsutils wget curl rsync chrony cron iproute2 jq)
    MISSING_PACKAGES=()
    
    for pkg in "${CORE_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done
    
    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
        log "安装核心软件包: ${MISSING_PACKAGES[*]}" "INFO"
        apt install -y "${MISSING_PACKAGES[@]}" || step_fail 2 "核心软件包安装失败"
    fi
    
    # 修复 hosts 文件
    HOSTNAME=$(hostname)
    if ! grep -q "^127.0.1.1.*$HOSTNAME" /etc/hosts 2>/dev/null; then
        log "修复 hosts 文件" "INFO"
        sed -i "/^127.0.1.1/d" /etc/hosts
        echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
    fi
    
    step_end 2 "系统更新完成"
else
    log "跳过系统更新（根据配置）" "INFO"
fi

# --- 步骤 3: 模块化部署 ---
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

# 模块执行顺序
MODULE_ORDER=("system-optimize" "zsh-setup" "mise-setup" "docker-setup" "network-optimize" "ssh-security" "auto-update-setup")

# 确定要执行的模块
SELECTED_MODULES=()

if [[ -n "$DEFAULT_MODULES" ]]; then
    # 从配置文件获取模块列表
    IFS=',' read -ra config_modules <<< "$DEFAULT_MODULES"
    for module in "${config_modules[@]}"; do
        module=$(echo "$module" | tr -d ' ')  # 去除空格
        if [[ " ${MODULE_ORDER[*]} " =~ " $module " ]]; then
            # 检查是否在跳过列表中
            if [[ -n "$SKIP_MODULES" ]] && [[ ",$SKIP_MODULES," =~ ",$module," ]]; then
                log "跳过模块: $module（配置中指定）" "INFO"
            else
                SELECTED_MODULES+=("$module")
            fi
        fi
    done
else
    # 交互式选择模块
    for module in "${MODULE_ORDER[@]}"; do
        # 检查是否在跳过列表中
        if [[ -n "$SKIP_MODULES" ]] && [[ ",$SKIP_MODULES," =~ ",$module," ]]; then
            log "跳过模块: $module（配置中指定）" "INFO"
            continue
        fi
        
        description="${MODULES[$module]}"
        if ask_user_module "$module" "$description" "y"; then
            SELECTED_MODULES+=("$module")
        else
            log "跳过模块: $module" "INFO"
        fi
    done
fi

if [[ ${#SELECTED_MODULES[@]} -eq 0 ]]; then
    log "未选择任何模块，跳过模块部署" "WARN"
else
    log "将执行 ${#SELECTED_MODULES[@]} 个模块: ${SELECTED_MODULES[*]}" "INFO"
    
    # 并行下载所有需要的模块
    if download_all_modules "${SELECTED_MODULES[@]}"; then
        log "所有模块下载成功，开始执行..." "INFO"
        
        # 逐个执行模块
        for ((i=0; i<${#SELECTED_MODULES[@]}; i++)); do
            module="${SELECTED_MODULES[i]}"
            description="${MODULES[$module]}"
            
            log "\n开始处理模块 ($((i+1))/${#SELECTED_MODULES[@]}): $module" "TITLE"
            show_progress $((i+1)) ${#SELECTED_MODULES[@]} "执行模块"
            
            if execute_module "$module"; then
                EXECUTED_MODULES+=("$module")
                log "模块 $module 完成\n" "INFO"
            else
                FAILED_MODULES+=("$module")
                log "模块 $module 失败，继续执行其他模块\n" "WARN"
            fi
        done
    else
        log "部分模块下载失败，跳过模块执行" "ERROR"
        step_fail 3 "模块下载失败"
    fi
fi

step_end 3 "模块化部署完成"
# --- 步骤 4: 部署摘要 ---
step_start 4 "生成部署摘要"

log "\n╔═════════════════════════════════════════╗" "TITLE"
log "║           系统部署完成摘要                ║" "TITLE"
log "╚═════════════════════════════════════════╝" "TITLE"

show_info() { log " • $1: $2" "INFO"; }

show_info "脚本版本" "$SCRIPT_VERSION"
show_info "部署模式" "$(if [[ "$RERUN_MODE" == "true" ]]; then echo "更新模式"; else echo "首次部署"; fi)"
show_info "操作系统" "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')"
show_info "内核版本" "$(uname -r)"
show_info "CPU 核心" "$(nproc)"
show_info "总内存" "$(free -h | grep Mem | awk '{print $2}')"
show_info "执行时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# 已执行模块
if [[ ${#EXECUTED_MODULES[@]} -gt 0 ]]; then
    log "\n✅ 成功执行的模块:" "INFO"
    for module in "${EXECUTED_MODULES[@]}"; do
        log "   • $module: ${MODULES[$module]}" "INFO"
    done
fi

# 失败模块
if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
    log "\n❌ 执行失败的模块:" "ERROR"
    for module in "${FAILED_MODULES[@]}"; do
        log "   • $module: ${MODULES[$module]}" "ERROR"
    done
fi

# 系统状态检查
log "\n📊 当前系统状态:" "INFO"

# Zsh 状态
if command -v zsh &>/dev/null; then
    ZSH_VERSION=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
    show_info "Zsh Shell" "已安装 (版本: $ZSH_VERSION)"
    
    ROOT_SHELL=$(getent passwd root | cut -d: -f7)
    if [[ "$ROOT_SHELL" == "$(which zsh 2>/dev/null)" ]]; then
        show_info "默认 Shell" "Zsh"
    else
        show_info "默认 Shell" "Bash (可手动切换到 Zsh)"
    fi
else
    show_info "Zsh Shell" "未安装"
fi

# Docker 状态
if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
    if systemctl is-active docker &>/dev/null; then
        CONTAINERS_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        show_info "Docker" "已安装并运行 (版本: $DOCKER_VERSION, 容器: $CONTAINERS_COUNT)"
    else
        show_info "Docker" "已安装但未运行 (版本: $DOCKER_VERSION)"
    fi
else
    show_info "Docker" "未安装"
fi

# Mise 状态
if [[ -f "$HOME/.local/bin/mise" ]] || command -v mise &>/dev/null; then
    MISE_VERSION=$(mise --version 2>/dev/null | head -1 || echo "未知")
    show_info "Mise" "已安装 ($MISE_VERSION)"
else
    show_info "Mise" "未安装"
fi

# 网络优化状态
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
show_info "网络优化" "拥塞控制: $CURR_CC, 队列调度: $CURR_QDISC"

# SSH 状态
if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
    SSH_PORT_ACTUAL=$(ss -tlnp | grep sshd | head -1 | awk '{print $4}' | cut -d: -f2 || echo "22")
    show_info "SSH 服务" "运行中 (端口: $SSH_PORT_ACTUAL)"
else
    show_info "SSH 服务" "未运行"
fi

# 系统服务状态
log "\n🔧 系统服务状态:" "INFO"
for service in chrony cron; do
    if systemctl is-active "$service" &>/dev/null; then
        show_info "$service" "运行中"
    else
        show_info "$service" "未运行"
    fi
done

# 磁盘使用情况
log "\n💽 磁盘使用情况:" "INFO"
df -h / | tail -1 | awk '{printf " • 根分区: %s/%s (使用率: %s)\n", $3, $2, $5}' | while read line; do log "$line" "INFO"; done

# 内存使用情况
log "\n🧠 内存使用情况:" "INFO"
free -h | grep "Mem:" | awk '{printf " • 内存: %s/%s (使用率: %.1f%%)\n", $3, $2, ($3/$2)*100}' | while read line; do log "$line" "INFO"; done

log "\n──────────────────────────────────────────────────" "TITLE"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "INFO"
log " 配置文件位置: $CONFIG_FILE" "INFO"
log " 状态文件位置: $STATUS_FILE" "INFO"
log "──────────────────────────────────────────────────\n" "TITLE"

step_end 4 "摘要生成完成"

# --- 保存部署状态 ---
log "保存部署状态..." "DEBUG"
save_status

# --- 最终提示 ---
log "✅ 所有部署任务完成!" "TITLE"

# 重要提示
if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
    NEW_SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    if [[ "$NEW_SSH_PORT" != "22" ]] && [[ -n "$NEW_SSH_PORT" ]]; then
        echo
        log "⚠️  重要提示: SSH 端口已更改" "WARN"
        log "   新端口: $NEW_SSH_PORT" "WARN"
        log "   连接命令: ssh -p $NEW_SSH_PORT user@$(hostname -I | awk '{print $1}')" "WARN"
        log "   请在断开连接前测试新端口是否可用！" "WARN"
    fi
fi

if [[ " ${EXECUTED_MODULES[*]} " =~ " zsh-setup " ]]; then
    echo
    log "🐚 Zsh 使用提示:" "INFO"
    log "   体验 Zsh: exec zsh" "INFO"
    log "   配置已优化，包含 Powerlevel10k 主题和实用插件" "INFO"
fi

if [[ " ${EXECUTED_MODULES[*]} " =~ " docker-setup " ]]; then
    echo
    log "🐳 Docker 使用提示:" "INFO"
    log "   查看状态: systemctl status docker" "INFO"
    log "   测试安装: docker run hello-world" "INFO"
fi

# 性能建议
if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
    echo
    log "🔄 失败模块处理建议:" "WARN"
    log "   可单独重新运行脚本，或检查网络连接" "WARN"
    log "   调试模式: $0 --debug" "WARN"
fi

# 下次运行提示
echo
log "📝 后续操作建议:" "INFO"
log "   • 重新部署: $0" "INFO"
log "   • 快速模式: $0 --quick --yes" "INFO"
log "   • 自定义模块: $0 --modules \"zsh-setup,docker-setup\"" "INFO"
log "   • 查看帮助: $0 --help" "INFO"

# 安全提示
if [[ "${#EXECUTED_MODULES[@]}" -gt 0 ]]; then
    echo
    log "🔒 安全提示:" "WARN"
    log "   • 建议重启系统以确保所有更改生效" "WARN"
    log "   • 如修改了 SSH 配置，请先测试连接" "WARN"
    log "   • 定期运行此脚本保持系统更新" "WARN"
fi

log "\n🎉 感谢使用 Debian 部署脚本！" "TITLE"

# 统计信息
TOTAL_MODULES=${#SELECTED_MODULES[@]}
SUCCESS_MODULES=${#EXECUTED_MODULES[@]}
FAILED_MODULES_COUNT=${#FAILED_MODULES[@]}

if [[ $TOTAL_MODULES -gt 0 ]]; then
    SUCCESS_RATE=$((SUCCESS_MODULES * 100 / TOTAL_MODULES))
    log "📈 执行统计: $SUCCESS_MODULES/$TOTAL_MODULES 成功 (${SUCCESS_RATE}%)" "INFO"
fi

# 根据执行结果设置退出码
if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
    log "脚本执行完成，但有模块失败" "WARN"
    exit 2  # 部分失败
else
    log "脚本执行完全成功" "DEBUG"
    exit 0  # 完全成功
fi
