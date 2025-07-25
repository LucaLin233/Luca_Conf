#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署脚本 (完整优化版本 v2.5.0)
# 适用系统: Debian 12+, 作者: LucaLin233 (Complete Enhanced Version)
# 功能: 完整模块化部署，包含并发处理、回滚机制、依赖管理等高级功能
# -----------------------------------------------------------------------------

set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="2.5.0"
readonly STATUS_FILE="/var/lib/system-deploy-status.json"
readonly CONFIG_FILE="$HOME/setup.conf"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/modules"
readonly TEMP_DIR="/tmp/debian_setup_modules"
readonly LOG_FILE="/var/log/debian_setup.log"
readonly BACKUP_DIR="/var/backups/debian_setup"
readonly GPG_KEY_URL="$MODULE_BASE_URL/signing_key.pub"

# 模块定义和依赖关系
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区)"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise 版本管理器"
    ["docker-setup"]="Docker 容器化平台"
    ["network-optimize"]="网络性能优化"
    ["ssh-security"]="SSH 安全配置"
    ["auto-update-setup"]="自动更新系统"
)

# 模块依赖关系
declare -A MODULE_DEPS=(
    ["docker-setup"]="system-optimize"
    ["mise-setup"]="zsh-setup"
    ["auto-update-setup"]="system-optimize"
)

# 执行状态跟踪
EXECUTED_MODULES=()
FAILED_MODULES=()
SKIPPED_MODULES=()
RERUN_MODE=false
BACKUP_PATH=""
CONFIG_MODE="interactive"

# --- 颜色和进度显示 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# --- 基础日志函数 ---
log() {
    local msg="$1" level="${2:-info}" timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local -A colors=(
        [info]="$GREEN" [warn]="$YELLOW" [error]="$RED" 
        [title]="$PURPLE" [debug]="$CYAN" [progress]="$BLUE"
    )
    
    # 控制台输出
    echo -e "${colors[$level]:-$NC}$msg$NC"
    
    # 文件日志
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

die() { log "✗ 错误: $1" "error"; exit 1; }
step() { log "\n▶ $1" "title"; }
ok() { log "✓ $1" "info"; }
warn() { log "⚠ $1" "warn"; }
debug() { log "🔍 $1" "debug"; }

# 添加辅助函数
show_info() { log "  $1: $2" "info"; }

# --- 修复颜色显示的进度显示函数 ---
show_progress() {
    local current=$1 total=$2 task="${3:-处理中}"
    
    # 安全检查，避免除零和非法数值
    if [[ ! "$current" =~ ^[0-9]+$ ]] || [[ ! "$total" =~ ^[0-9]+$ ]] || (( total == 0 )); then
        log "$task..." "info"
        return 0
    fi
    
    # 安全的数学运算
    local percent=0
    local filled=0
    local bar_length=30
    
    if (( total > 0 )); then
        percent=$(( current * 100 / total ))
        filled=$(( bar_length * current / total ))
    fi
    
    # 确保 filled 不会超出范围
    if (( filled > bar_length )); then
        filled=$bar_length
    elif (( filled < 0 )); then
        filled=0
    fi
    
    # 构建进度条
    local bar=""
    local i=0
    
    # 填充部分
    while (( i < filled )); do
        bar+="█"
        ((i++))
    done
    
    # 空白部分
    while (( i < bar_length )); do
        bar+="░"
        ((i++))
    done
    
    # 修复颜色显示 - 使用 echo -e 而不是 printf
    if (( current >= total )); then
        echo -e "\r${BLUE}[${bar}] ${percent}% (${current}/${total}) ${task}${NC}"
    else
        echo -ne "\r${BLUE}[${bar}] ${percent}% (${current}/${total}) ${task}${NC}"
    fi
}

# --- 清理和信号处理 ---
cleanup() {
    local exit_code=$?
    
    debug "执行清理操作..."
    
    # 停止所有后台进程
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # 清理临时文件
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    
    # 如果异常退出且有备份，询问是否回滚
    if (( exit_code != 0 )) && [[ -n "$BACKUP_PATH" ]] && [[ -d "$BACKUP_PATH" ]]; then
        echo
        warn "脚本异常退出，检测到备份文件"
        read -p "是否回滚到执行前状态? [y/N]: " -r rollback_choice
        if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
            perform_rollback
        fi
    fi
    
    if (( exit_code != 0 )); then
        log "异常退出，退出码: $exit_code" "error"
        log "详细日志: $LOG_FILE" "info"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM
# --- 改进的配置文件处理 ---
load_config() {
    # 第一次运行，自动生成示例配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "首次运行，创建示例配置文件..." "info"
        create_sample_config
        
        echo
        log "📝 配置文件已生成: $CONFIG_FILE" "title"
        log "   你可以编辑此文件来自定义部署行为" "info"
        log "   配置格式: module_name:action (action: auto/ask/skip)" "info"
        echo
        
        # 询问用户是否要编辑配置文件
        read -p "是否现在编辑配置文件? [y/N]: " -r edit_choice
        if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
            edit_config_file
            echo
            log "配置文件编辑完成，重新加载配置..." "info"
        else
            log "使用默认配置继续，稍后可通过以下命令编辑:" "info"
            log "   nano $CONFIG_FILE" "info"
        fi
    fi
    
    # 加载配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        log "加载配置文件: $CONFIG_FILE" "debug"
        source "$CONFIG_FILE"
        
        # 验证配置文件格式并设置模式
        if [[ -n "${MODULES_CONFIG:-}" ]]; then
            CONFIG_MODE="auto"
            log "配置模式: 自动化部署 (根据配置文件)" "info"
            
            # 显示配置摘要
            show_config_summary
        else
            warn "配置文件格式异常，使用交互模式"
            CONFIG_MODE="interactive"
        fi
    else
        log "配置文件加载失败，使用交互模式" "warn"
        CONFIG_MODE="interactive"
    fi
}
create_sample_config() {
    cat > "$CONFIG_FILE" << EOF
#!/bin/bash
# =============================================================================
# Debian 系统部署配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# 模块配置 - 格式: "module_name:action"
# 可用动作:
#   auto - 自动执行，不询问用户
#   ask  - 询问用户是否执行（推荐）
#   skip - 跳过此模块
MODULES_CONFIG=(
    "system-optimize:ask"       # 系统优化 (Zram, 时区) - 推荐执行
    "zsh-setup:ask"            # Zsh Shell 环境 - 开发者推荐
    "mise-setup:ask"           # Mise 版本管理器 - 开发者推荐
    "docker-setup:ask"         # Docker 容器化平台 - 按需选择
    "network-optimize:ask"     # 网络性能优化 (BBR) - 服务器推荐
    "ssh-security:ask"         # SSH 安全配置 - 生产环境推荐
    "auto-update-setup:ask"    # 自动更新系统 - 服务器推荐
)

# =============================================================================
# 高级配置选项
# =============================================================================

# SSH 配置
CUSTOM_SSH_PORT=22             # 自定义 SSH 端口 (默认: 22)

# 网络配置
SKIP_NETWORK_CHECK=false       # 跳过网络连接检查 (默认: false)

# 安全配置
ENABLE_SIGNATURE_VERIFY=false  # 启用模块签名验证 (默认: false)

# 性能配置
PARALLEL_DOWNLOADS=true        # 并发下载模块 (默认: true)

# =============================================================================
# 预设配置模板 (取消注释使用，注释掉上面的 MODULES_CONFIG)
# =============================================================================

# 🖥️ 服务器环境预设 (生产环境)
# MODULES_CONFIG=(
#     "system-optimize:auto"
#     "zsh-setup:skip"
#     "mise-setup:skip"
#     "docker-setup:auto"
#     "network-optimize:auto"
#     "ssh-security:auto"
#     "auto-update-setup:auto"
# )
# CUSTOM_SSH_PORT=22022

# 💻 开发环境预设 (个人使用)
# MODULES_CONFIG=(
#     "system-optimize:auto"
#     "zsh-setup:auto"
#     "mise-setup:auto"
#     "docker-setup:ask"
#     "network-optimize:ask"
#     "ssh-security:ask"
#     "auto-update-setup:skip"
# )

# 🚀 最小化安装预设 (只安装必需)
# MODULES_CONFIG=(
#     "system-optimize:auto"
#     "zsh-setup:skip"
#     "mise-setup:skip"
#     "docker-setup:skip"
#     "network-optimize:auto"
#     "ssh-security:auto"
#     "auto-update-setup:auto"
# )
EOF
    
    chmod 644 "$CONFIG_FILE"
    log "示例配置文件已创建: $CONFIG_FILE" "debug"
}

# --- 系统预检查 ---
preflight_check() {
    step "系统预检查"
    
    local issues=() warnings=()
    
    # 磁盘空间检查 (至少1GB)
    local free_space_kb
    free_space_kb=$(df / | awk 'NR==2 {print $4}')
    if (( free_space_kb < 1048576 )); then
        issues+=("磁盘空间不足 (可用: $(( free_space_kb / 1024 ))MB, 需要: 1GB)")
    fi
    
    # 内存检查 (至少512MB可用)
    local free_mem_mb
    free_mem_mb=$(free -m | awk 'NR==2{print $7}')
    if (( free_mem_mb < 512 )); then
        warnings+=("可用内存较低 (${free_mem_mb}MB)")
    fi
    
    # 网络连接检查
    if [[ "${SKIP_NETWORK_CHECK:-false}" != "true" ]]; then
        if ! check_network_connectivity; then
            issues+=("网络连接异常")
        fi
    fi
    
    # 端口占用检查
    local occupied_ports=()
    for port in 2375 8080 80 443; do
        if ss -tlnp | grep -q ":$port "; then
            occupied_ports+=("$port")
        fi
    done
    if (( ${#occupied_ports[@]} > 0 )); then
        warnings+=("检测到端口占用: ${occupied_ports[*]}")
    fi
    
    # 运行中的关键服务检查
    local services=("docker" "nginx" "apache2")
    local running_services=()
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            running_services+=("$service")
        fi
    done
    if (( ${#running_services[@]} > 0 )); then
        warnings+=("检测到运行中的服务: ${running_services[*]}")
    fi
    
    # 显示检查结果
    if (( ${#issues[@]} > 0 )); then
        log "❌ 发现严重问题:" "error"
        printf '   • %s\n' "${issues[@]}"
        die "预检查失败，请解决问题后重试"
    fi
    
    if (( ${#warnings[@]} > 0 )); then
        log "⚠️ 发现警告信息:" "warn"
        printf '   • %s\n' "${warnings[@]}"
        echo
        read -p "继续执行? [y/N]: " -r continue_choice
        [[ "$continue_choice" =~ ^[Yy]$ ]] || exit 0
    fi
    
    ok "预检查通过"
}

# --- 网络连接检查 ---
check_network_connectivity() {
    local test_hosts=("8.8.8.8" "1.1.1.1" "114.114.114.114" "223.5.5.5")
    local timeout=3
    local success_count=0
    
    debug "测试网络连接..."
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W $timeout "$host" &>/dev/null; then
            ((success_count++))
            [[ $success_count -ge 2 ]] && return 0
        fi
    done
    
    return 1
}

# --- 初始化检查 ---
init_system() {
    # 创建日志文件
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"
    log "=== Debian 系统部署脚本启动 - 版本 $SCRIPT_VERSION ===" "title"
    
    # 权限检查
    (( EUID == 0 )) || die "需要 root 权限运行"
    
    # 系统检查
    [[ -f /etc/debian_version ]] || die "仅支持 Debian 系统"
    
    # 版本检查
    local debian_ver
    debian_ver=$(cut -d. -f1 < /etc/debian_version 2>/dev/null || echo "0")
    if (( debian_ver > 0 && debian_ver < 12 )); then
        warn "当前系统: Debian $debian_ver (建议使用 Debian 12+)"
        read -p "继续执行? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi
    
    # 检查重运行模式
    if [[ -f "$STATUS_FILE" ]]; then
        RERUN_MODE=true
        log "检测到部署记录，以更新模式运行" "info"
        
        if command -v jq &>/dev/null && [[ -s "$STATUS_FILE" ]]; then
            local last_run
            last_run=$(jq -r '.last_run // "未知"' "$STATUS_FILE" 2>/dev/null || echo "未知")
            log "上次运行: $last_run" "debug"
        fi
    fi
    
    # 创建工作目录
    mkdir -p "$TEMP_DIR" "$BACKUP_DIR"
    
    # 智能配置管理
    manage_configuration
    
    ok "系统初始化完成"
}
# --- 改进的依赖检查和安装 ---
install_dependencies() {
    step "检查系统依赖"
    
    local required_deps=(curl wget git jq rsync gpg)
    local missing_deps=()
    local total_deps=${#required_deps[@]}
    local current=0
    
    # 检查缺失的依赖 - 使用安全的计数方式
    for dep in "${required_deps[@]}"; do
        current=$((current + 1))
        
        # 显示进度（如果进度显示失败，使用简单日志）
        if ! show_progress "$current" "$total_deps" "检查 $dep"; then
            log "检查依赖: $dep ($current/$total_deps)" "info"
        fi
        
        # 检查命令是否存在
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
            debug "依赖 $dep 未安装"
        else
            debug "依赖 $dep 已安装"
        fi
        
        # 短暂暂停让用户看到进度
        sleep 0.1 2>/dev/null || true
    done
    
    # 确保进度条完成显示
    echo 2>/dev/null || true
    
    if (( ${#missing_deps[@]} > 0 )); then
        log "安装缺失依赖: ${missing_deps[*]}" "info"
        
        # 更安全的 apt 操作
        if ! apt-get update -qq 2>/dev/null; then
            warn "软件包列表更新失败，尝试继续..."
        fi
        
        if ! apt-get install -y "${missing_deps[@]}" 2>/dev/null; then
            die "依赖安装失败，请检查网络连接和软件源配置"
        fi
        
        # 验证安装
        local failed_deps=()
        for dep in "${missing_deps[@]}"; do
            if ! command -v "$dep" >/dev/null 2>&1; then
                failed_deps+=("$dep")
            fi
        done
        
        if (( ${#failed_deps[@]} > 0 )); then
            die "以下依赖安装失败: ${failed_deps[*]}"
        fi
    fi
    
    ok "依赖检查完成"
}

# --- 模块依赖解析 (拓扑排序) - 修复版本 ---
resolve_module_dependencies() {
    local -a selected_modules=("$@")
    local -a resolved_order=()
    local -A visited=()
    local -A visiting=()
    
    # 如果没有选择模块，直接返回
    if (( ${#selected_modules[@]} == 0 )); then
        return 0
    fi
    
    # 递归依赖解析函数
    visit_module() {
        local module="$1"
        
        # 安全检查模块名
        if [[ -z "$module" ]]; then
            return 1
        fi
        
        # 检查循环依赖
        if [[ -n "${visiting[$module]:-}" ]]; then
            log "检测到循环依赖: $module，跳过" "warn"
            return 1
        fi
        
        # 已访问过的跳过
        if [[ -n "${visited[$module]:-}" ]]; then
            return 0
        fi
        
        visiting[$module]=1
        
        # 处理依赖
        local dep="${MODULE_DEPS[$module]:-}"
        if [[ -n "$dep" ]]; then
            # 检查依赖是否在选择列表中
            if [[ " ${selected_modules[*]} " =~ " $dep " ]]; then
                visit_module "$dep" || true  # 不要因为依赖失败就退出
            else
                log "模块 $module 需要依赖 $dep，自动添加" "info"
                selected_modules+=("$dep")
                visit_module "$dep" || true
            fi
        fi
        
        unset visiting[$module]
        visited[$module]=1
        resolved_order+=("$module")
        
        return 0
    }
    
    # 解析所有选中的模块
    for module in "${selected_modules[@]}"; do
        if [[ -n "$module" ]]; then
            visit_module "$module" || {
                log "跳过有问题的模块: $module" "warn"
                continue
            }
        fi
    done
    
    # 返回解析后的顺序
    if (( ${#resolved_order[@]} > 0 )); then
        printf '%s\n' "${resolved_order[@]}"
    else
        # 如果解析失败，返回原始顺序
        printf '%s\n' "${selected_modules[@]}"
    fi
}

# --- GPG 密钥管理 (临时禁用) ---
setup_gpg_verification() {
    if [[ "${ENABLE_SIGNATURE_VERIFY:-false}" == "true" ]]; then
        step "设置 GPG 签名验证"
        
        local gpg_home="$TEMP_DIR/.gnupg"
        mkdir -p "$gpg_home" 2>/dev/null || {
            warn "无法创建 GPG 目录，禁用签名验证"
            ENABLE_SIGNATURE_VERIFY=false
            return 1
        }
        chmod 700 "$gpg_home" 2>/dev/null || true
        
        # 下载公钥
        if curl -fsSL --connect-timeout 10 "$GPG_KEY_URL" -o "$gpg_home/signing_key.pub" 2>/dev/null; then
            export GNUPGHOME="$gpg_home"
            if gpg --import "$gpg_home/signing_key.pub" 2>/dev/null; then
                ok "GPG 签名验证已启用"
                return 0
            else
                warn "GPG 公钥导入失败，禁用签名验证"
            fi
        else
            warn "无法下载 GPG 公钥（可能仓库未设置签名），禁用签名验证"
        fi
        
        ENABLE_SIGNATURE_VERIFY=false
    else
        debug "GPG 签名验证已禁用"
    fi
}

# --- 安全的模块下载 (支持并发和签名验证) ---
download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local sig_file="$TEMP_DIR/${module}.sh.sig"
    local max_retries=3
    
    for (( retry=1; retry<=max_retries; retry++ )); do
        # 下载模块文件
        if curl -fsSL --connect-timeout 10 --max-time 30 \
           "$MODULE_BASE_URL/${module}.sh" -o "$module_file"; then
            
            # 基本内容验证
            if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash"; then
                
                # GPG 签名验证 (如果启用)
                if [[ "${ENABLE_SIGNATURE_VERIFY:-false}" == "true" ]]; then
                    if curl -fsSL --connect-timeout 5 \
                       "$MODULE_BASE_URL/${module}.sh.sig" -o "$sig_file" 2>/dev/null; then
                        
                        if ! gpg --verify "$sig_file" "$module_file" 2>/dev/null; then
                            warn "模块 $module 签名验证失败"
                            rm -f "$module_file" "$sig_file"
                            continue
                        else
                            debug "模块 $module 签名验证成功"
                        fi
                    else
                        warn "模块 $module 签名文件下载失败"
                    fi
                fi
                
                chmod +x "$module_file"
                return 0
            else
                debug "模块 $module 内容格式异常"
                rm -f "$module_file"
            fi
        fi
        
        if (( retry < max_retries )); then
            debug "重试下载 $module ($retry/$max_retries)"
            sleep $((retry * 2))
        fi
    done
    
    log "模块 $module 下载失败" "error"
    return 1
}

# --- 并发下载管理 ---
download_modules_parallel() {
    local -a modules=("$@")
    local total=${#modules[@]}
    local current=0
    local -a pids=()
    local -a results=()
    
    step "并发下载模块"
    
    # 启动并发下载
    for module in "${modules[@]}"; do
        if [[ "${PARALLEL_DOWNLOADS:-true}" == "true" ]]; then
            download_module "$module" &
            pids+=($!)
        else
            ((current++))
            show_progress $current $total "下载 $module"
            download_module "$module"
            results+=($?)
        fi
    done
    
    # 等待并发下载完成
    if [[ "${PARALLEL_DOWNLOADS:-true}" == "true" ]]; then
        for i in "${!pids[@]}"; do
            local pid=${pids[$i]}
            local module=${modules[$i]}
            ((current++))
            
            show_progress $current $total "等待 $module"
            
            if wait "$pid"; then
                results+=(0)
                debug "模块 $module 下载成功"
            else
                results+=(1)
                debug "模块 $module 下载失败"
            fi
        done
    fi
    
    # 统计结果
    local success_count=0 fail_count=0
    for result in "${results[@]}"; do
        if (( result == 0 )); then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    if (( fail_count > 0 )); then
        warn "模块下载完成: 成功 $success_count, 失败 $fail_count"
    else
        ok "所有模块下载成功 ($success_count/$total)"
    fi
    
    return $(( fail_count > 0 ? 1 : 0 ))
}
# --- 修复后的系统备份机制 ---
create_system_backup() {
    step "创建系统备份"
    
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    BACKUP_PATH="$BACKUP_DIR/backup_$timestamp"
    
    # 确保备份目录存在
    if ! mkdir -p "$BACKUP_PATH"; then
        warn "无法创建备份目录: $BACKUP_PATH"
        return 1
    fi
    
    # 备份关键配置文件
    local config_files=(
        "/etc/ssh/sshd_config"
        "/etc/sysctl.conf"
        "/etc/security/limits.conf"
        "/etc/systemd/system.conf"
        "/etc/apt/sources.list"
        "/root/.bashrc"
        "/root/.profile"
    )
    
    local backup_count=0
    local total_files=${#config_files[@]}
    
    for config in "${config_files[@]}"; do
        backup_count=$((backup_count + 1))
        
        # 安全的进度显示
        show_progress "$backup_count" "$total_files" "备份 $(basename "$config")" || {
            log "备份 $(basename "$config") ($backup_count/$total_files)" "info"
        }
        
        # 安全的文件复制
        if [[ -f "$config" ]]; then
            if ! cp "$config" "$BACKUP_PATH/" 2>/dev/null; then
                debug "备份 $config 失败，但继续执行"
            else
                debug "备份 $config 成功"
            fi
        else
            debug "文件 $config 不存在，跳过备份"
        fi
    done
    
    # 备份当前用户 shell 配置
    if [[ -f "/root/.zshrc" ]]; then
        cp "/root/.zshrc" "$BACKUP_PATH/" 2>/dev/null || debug "备份 .zshrc 失败"
    fi
    
    # 记录当前系统状态 - 使用更安全的方式
    {
        echo "备份时间: $(date)"
        echo "内核版本: $(uname -r)"
        echo "系统版本: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "未知")"
        echo "当前用户Shell: $(getent passwd root 2>/dev/null | cut -d: -f7 || echo "未知")"
        echo "网络配置: $(ip route 2>/dev/null | grep default | head -1 || echo "未知")"
        echo "已安装软件包数量: $(dpkg -l 2>/dev/null | wc -l || echo "未知")"
    } > "$BACKUP_PATH/system_info.txt" 2>/dev/null || {
        warn "无法创建系统信息文件"
    }
    
    # 创建恢复脚本
    cat > "$BACKUP_PATH/restore.sh" << 'EOF'
#!/bin/bash
echo "开始系统恢复..."
BACKUP_DIR=$(dirname "$0")

# 恢复配置文件
for file in "$BACKUP_DIR"/*.conf "$BACKUP_DIR"/*config "$BACKUP_DIR"/.??*; do
    [[ -f "$file" ]] || continue
    filename=$(basename "$file")
    
    case "$filename" in
        "sshd_config") 
            if cp "$file" /etc/ssh/ 2>/dev/null; then
                echo "恢复 SSH 配置成功"
            else
                echo "恢复 SSH 配置失败"
            fi
            ;;
        "sysctl.conf") 
            if cp "$file" /etc/ 2>/dev/null; then
                echo "恢复 sysctl 配置成功"
            else
                echo "恢复 sysctl 配置失败"
            fi
            ;;
        "limits.conf") 
            if cp "$file" /etc/security/ 2>/dev/null; then
                echo "恢复 limits 配置成功"
            else
                echo "恢复 limits 配置失败"
            fi
            ;;
        "system.conf") 
            if cp "$file" /etc/systemd/ 2>/dev/null; then
                echo "恢复 systemd 配置成功"
            else
                echo "恢复 systemd 配置失败"
            fi
            ;;
        "sources.list") 
            if cp "$file" /etc/apt/ 2>/dev/null; then
                echo "恢复 APT 源配置成功"
            else
                echo "恢复 APT 源配置失败"
            fi
            ;;
        ".bashrc"|".profile"|".zshrc") 
            if cp "$file" /root/ 2>/dev/null; then
                echo "恢复用户配置 $filename 成功"
            else
                echo "恢复用户配置 $filename 失败"
            fi
            ;;
    esac
done

# 重启相关服务
echo "重新加载服务..."
if systemctl reload ssh 2>/dev/null; then
    echo "SSH 服务重新加载成功"
else
    echo "SSH 服务重新加载失败"
fi

if sysctl -p 2>/dev/null; then
    echo "sysctl 配置重新加载成功"
else
    echo "sysctl 配置重新加载失败"
fi

echo "系统恢复完成"
EOF
    
    # 设置恢复脚本权限
    if ! chmod +x "$BACKUP_PATH/restore.sh" 2>/dev/null; then
        warn "无法设置恢复脚本执行权限"
    fi
    
    ok "备份创建完成: $BACKUP_PATH"
}

# --- 回滚操作 ---
perform_rollback() {
    if [[ -z "$BACKUP_PATH" ]] || [[ ! -d "$BACKUP_PATH" ]]; then
        warn "未找到备份文件，无法回滚"
        return 1
    fi
    
    step "执行系统回滚"
    
    log "回滚到: $BACKUP_PATH" "info"
    
    # 执行恢复脚本
    if [[ -x "$BACKUP_PATH/restore.sh" ]]; then
        bash "$BACKUP_PATH/restore.sh"
        ok "系统回滚完成"
    else
        warn "恢复脚本不存在或无执行权限"
        return 1
    fi
}

# --- 清理旧备份 ---
cleanup_old_backups() {
    local max_backups=5
    local backup_count
    
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" | wc -l)
    
    if (( backup_count > max_backups )); then
        debug "清理旧备份文件 (保留 $max_backups 个)"
        find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | \
            sort -n | head -n -$max_backups | cut -d' ' -f2- | \
            xargs -r rm -rf
    fi
}
# --- 智能配置管理 ---
manage_configuration() {
    step "配置文件管理"
    
    # 如果是重运行模式且有配置文件，显示上次配置
    if $RERUN_MODE && [[ -f "$CONFIG_FILE" ]]; then
        log "检测到现有配置文件" "info"
        
        echo
        read -p "是否使用现有配置文件? [Y/n/e(编辑)]: " -r config_choice
        config_choice="${config_choice:-Y}"
        
        case "$config_choice" in
            [Ee]*)
                log "打开配置文件编辑..." "info"
                edit_config_file
                ;;
            [Nn]*)
                log "重新创建配置文件..." "info"
                backup_old_config
                load_config  # 这会创建新的配置文件
                ;;
            *)
                log "使用现有配置文件" "info"
                ;;
        esac
    fi
    
    # 加载或创建配置
    load_config
}

# --- 显示配置摘要 ---
show_config_summary() {
    if [[ "$CONFIG_MODE" == "auto" ]] && [[ -n "${MODULES_CONFIG:-}" ]]; then
        log "📋 当前配置摘要:" "title"
        
        local auto_modules=() ask_modules=() skip_modules=()
        
        for config_item in "${MODULES_CONFIG[@]}"; do
            if [[ "$config_item" =~ ^([^:]+):(.+)$ ]]; then
                local module="${BASH_REMATCH[1]}"
                local action="${BASH_REMATCH[2]}"
                
                case "$action" in
                    "auto") auto_modules+=("$module") ;;
                    "ask") ask_modules+=("$module") ;;
                    "skip") skip_modules+=("$module") ;;
                esac
            fi
        done
        
        if (( ${#auto_modules[@]} > 0 )); then
            log "   自动执行: ${auto_modules[*]}" "info"
        fi
        if (( ${#ask_modules[@]} > 0 )); then
            log "   询问执行: ${ask_modules[*]}" "info"
        fi
        if (( ${#skip_modules[@]} > 0 )); then
            log "   跳过执行: ${skip_modules[*]}" "warn"
        fi
        
        # 显示其他配置
        echo
        log "⚙️  其他配置:" "title"
        [[ -n "${CUSTOM_SSH_PORT:-}" ]] && log "   SSH端口: $CUSTOM_SSH_PORT" "info"
        [[ "${SKIP_NETWORK_CHECK:-}" == "true" ]] && log "   跳过网络检查: 是" "info"
        [[ "${ENABLE_SIGNATURE_VERIFY:-}" == "true" ]] && log "   签名验证: 启用" "info"
        [[ "${PARALLEL_DOWNLOADS:-}" == "true" ]] && log "   并发下载: 启用" "info"
        
        echo
        read -p "确认使用此配置继续? [Y/n]: " -r confirm_choice
        confirm_choice="${confirm_choice:-Y}"
        if [[ ! "$confirm_choice" =~ ^[Yy]$ ]]; then
            log "用户取消执行" "info"
            exit 0
        fi
    fi
}

# --- 编辑配置文件 ---
edit_config_file() {
    local editors=("nano" "vim" "vi")
    local editor_found=false
    
    for editor in "${editors[@]}"; do
        if command -v "$editor" >/dev/null 2>&1; then
            "$editor" "$CONFIG_FILE"
            editor_found=true
            break
        fi
    done
    
    if ! $editor_found; then
        log "未找到可用编辑器，显示配置文件内容:" "warn"
        echo "--- 配置文件内容 ---"
        cat "$CONFIG_FILE"
        echo "--- 配置文件结束 ---"
        read -p "按回车键继续..." -r
    fi
}

# --- 备份旧配置 ---
backup_old_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_config="${CONFIG_FILE}.backup.$(date +%s)"
        cp "$CONFIG_FILE" "$backup_config"
        log "旧配置已备份到: $backup_config" "info"
    fi
}
# --- 修复后的用户交互和模块选择 ---
ask_module_execution() {
    local module="$1" description="$2"
    local config_action=""
    
    # 检查配置文件中的设置
    if [[ "$CONFIG_MODE" == "auto" ]] && [[ -n "${MODULES_CONFIG:-}" ]]; then
        for config_item in "${MODULES_CONFIG[@]}"; do
            if [[ "$config_item" =~ ^${module}:(.+)$ ]]; then
                config_action="${BASH_REMATCH[1]}"
                break
            fi
        done
    fi
    
    # 根据配置决定行为
    case "$config_action" in
        "auto")
            log "自动执行: $description" "info"
            return 0
            ;;
        "skip")
            log "配置跳过: $description" "info"
            SKIPPED_MODULES+=("$module")
            return 1
            ;;
        "ask"|"")
            # 检查是否在更新模式下已经执行过
            local already_executed=false
            if $RERUN_MODE && command -v jq &>/dev/null && [[ -f "$STATUS_FILE" ]]; then
                if jq -e --arg m "$module" '.executed_modules[]? | select(. == $m)' "$STATUS_FILE" >/dev/null 2>&1; then
                    already_executed=true
                fi
            fi
            
            # 交互询问
            echo
            log "模块: $description" "title"
            
            if $already_executed; then
                log "此模块在上次运行中已执行" "info"
                read -p "是否重新执行此模块? [y/N]: " -r choice
                choice="${choice:-N}"
            else
                read -p "是否执行此模块? [Y/n]: " -r choice
                choice="${choice:-Y}"
            fi
            
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                return 0
            else
                SKIPPED_MODULES+=("$module")
                return 1
            fi
            ;;
        *)
            warn "未知配置动作: $config_action，使用交互模式"
            echo
            log "模块: $description" "title"
            read -p "是否执行此模块? [Y/n]: " -r choice
            choice="${choice:-Y}"
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                return 0
            else
                SKIPPED_MODULES+=("$module")
                return 1
            fi
            ;;
    esac
}

# --- 修复交互式输入的模块执行器 ---
execute_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local start_time end_time duration
    
    # 基本检查
    if [[ -z "$module" ]]; then
        log "模块名称为空" "error"
        return 1
    fi
    
    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module" "error"
        FAILED_MODULES+=("$module")
        return 1
    fi
    
    if [[ ! -x "$module_file" ]]; then
        log "模块文件不可执行: $module" "error"
        FAILED_MODULES+=("$module")
        return 1
    fi
    
    log "开始执行模块: $module" "info"
    start_time=$(date +%s 2>/dev/null || echo "0")
    
    # 创建模块执行环境
    local module_log="$TEMP_DIR/${module}.log"
    local module_env="$TEMP_DIR/${module}.env"
    
    # 设置模块环境变量
    {
        echo "export MODULE_NAME=\"$module\""
        echo "export TEMP_DIR=\"$TEMP_DIR\""
        echo "export LOG_FILE=\"$module_log\""
        echo "export BACKUP_PATH=\"$BACKUP_PATH\""
        echo "export SCRIPT_VERSION=\"$SCRIPT_VERSION\""
    } > "$module_env" 2>/dev/null || {
        log "无法创建模块环境文件" "error"
        FAILED_MODULES+=("$module")
        return 1
    }
    
    # 修复：保留标准输入，只记录输出到日志
    local exec_result=0
    
    # 临时禁用严格模式来执行模块
    set +e
    {
        # 保留交互能力的执行方式
        source "$module_env" 2>/dev/null || true
        bash "$module_file"
    } 2>&1 | tee -a "$module_log"
    exec_result=${PIPESTATUS[0]}  # 获取实际命令的退出状态
    set -e
    
    end_time=$(date +%s 2>/dev/null || echo "$start_time")
    duration=$((end_time - start_time))
    
    if (( exec_result == 0 )); then
        EXECUTED_MODULES+=("$module")
        ok "模块 $module 执行成功 (耗时: ${duration}s)"
        return 0
    else
        FAILED_MODULES+=("$module")
        log "模块 $module 执行失败 (耗时: ${duration}s)" "error"
        
        # 显示模块错误日志
        if [[ -f "$module_log" ]] && [[ -s "$module_log" ]]; then
            log "模块错误日志:" "error"
            tail -5 "$module_log" 2>/dev/null | sed 's/^/  /' || true
        fi
        
        return 1
    fi
}

# --- 模块部署主流程 (修复版本) ---
deploy_modules() {
    step "模块化功能部署"
    
    local selected_modules=()
    local available_modules=()
    
    # 获取所有可用模块 - 使用更安全的方式
    for module in "${!MODULES[@]}"; do
        available_modules+=("$module")
    done
    
    # 用户选择模块
    log "可用模块列表:" "info"
    for module in "${available_modules[@]}"; do
        echo "  • $module: ${MODULES[$module]}"
    done
    echo
    
    # 批量选择模式
    if [[ "$CONFIG_MODE" == "auto" ]]; then
        log "配置文件模式: 自动选择模块" "info"
        for module in "${available_modules[@]}"; do
            if ask_module_execution "$module" "${MODULES[$module]}"; then
                selected_modules+=("$module")
            fi
        done
    else
        # 交互选择模式
        for module in "${available_modules[@]}"; do
            if ask_module_execution "$module" "${MODULES[$module]}"; then
                selected_modules+=("$module")
            fi
        done
        
        # 提供一键选择选项
        if (( ${#selected_modules[@]} == 0 )); then
            echo
            read -p "未选择任何模块，是否安装推荐模块? (system-optimize, zsh-setup, network-optimize) [y/N]: " -r choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                selected_modules=("system-optimize" "zsh-setup" "network-optimize")
            fi
        fi
    fi
    
    if (( ${#selected_modules[@]} == 0 )); then
        warn "未选择任何模块，跳过部署"
        return 0
    fi
    
    # 解析模块依赖关系 - 使用更安全的方式
    log "解析模块依赖..." "info"
    local -a resolved_modules
    
    # 临时禁用严格模式来避免函数执行问题
    set +e
    readarray -t resolved_modules < <(resolve_module_dependencies "${selected_modules[@]}")
    local resolve_result=$?
    set -e
    
    if (( resolve_result != 0 )) || (( ${#resolved_modules[@]} == 0 )); then
        warn "依赖解析失败，使用原始模块顺序"
        resolved_modules=("${selected_modules[@]}")
    fi
    
    if (( ${#resolved_modules[@]} != ${#selected_modules[@]} )); then
        log "依赖解析后的执行顺序: ${resolved_modules[*]}" "info"
        echo
        read -p "继续执行? [Y/n]: " -r choice
        choice="${choice:-Y}"
        [[ "$choice" =~ ^[Yy]$ ]] || return 0
    fi
    
    # 下载模块
    if ! download_modules_parallel "${resolved_modules[@]}"; then
        warn "部分模块下载失败，继续执行已下载的模块"
    fi
    
    # 执行模块 - 修复后的版本
    local total_modules=${#resolved_modules[@]}
    local current_module=0
    
    log "开始执行 $total_modules 个模块..." "info"
    
    for module in "${resolved_modules[@]}"; do
        current_module=$((current_module + 1))
        
        # 检查模块文件是否存在
        if [[ -f "$TEMP_DIR/${module}.sh" ]]; then
            log "\n[$current_module/$total_modules] 执行模块: ${MODULES[$module]}" "title"
            
            # 安全执行模块
            if ! execute_module "$module"; then
                warn "模块 $module 执行失败，继续执行其他模块"
                # 不要因为单个模块失败就退出整个脚本
            fi
        else
            log "跳过未下载的模块: $module" "warn"
            SKIPPED_MODULES+=("$module")
        fi
        
        # 添加短暂延迟，避免过快执行
        sleep 0.5 2>/dev/null || true
    done
    
    ok "模块部署完成"
}

# --- 系统更新 ---
system_update() {
    step "系统更新"
    
    # 更新软件包列表
    log "更新软件包列表..." "info"
    apt-get update || warn "软件包列表更新失败"
    
    # 根据运行模式选择更新策略
    if $RERUN_MODE; then
        log "更新模式: 执行安全更新" "info"
        apt-get upgrade -y
    else
        log "首次部署: 执行完整系统升级" "info"
        apt-get full-upgrade -y
    fi
    
    # 安装核心软件包
    local core_packages=(
        dnsutils wget curl rsync chrony cron iproute2 
        htop nano vim unzip zip tar gzip lsof
    )
    local missing_packages=()
    
    log "检查核心软件包..." "info"
    for pkg in "${core_packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done
    
    if (( ${#missing_packages[@]} > 0 )); then
        log "安装核心软件包: ${missing_packages[*]}" "info"
        apt-get install -y "${missing_packages[@]}" || warn "部分软件包安装失败"
    fi
    
    # 修复系统配置
    fix_system_config
    
    # 清理不需要的软件包
    log "清理系统..." "info"
    apt-get autoremove -y
    apt-get autoclean
    
    ok "系统更新完成"
}

# --- 修复系统配置 ---
fix_system_config() {
    local hostname
    hostname=$(hostname)
    
    # 修复 hosts 文件
    if ! grep -q "^127.0.1.1.*$hostname" /etc/hosts; then
        log "修复 hosts 文件" "debug"
        sed -i "/^127.0.1.1/d" /etc/hosts
        echo "127.0.1.1 $hostname" >> /etc/hosts
    fi
    
    # 确保时区正确设置
    if [[ ! -f /etc/timezone ]] || [[ "$(cat /etc/timezone)" != "Asia/Shanghai" ]]; then
        log "设置时区为 Asia/Shanghai" "debug"
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    fi
    
    # 启用必要的系统服务
    local essential_services=(cron rsyslog)
    for service in "${essential_services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            systemctl enable "$service" 2>/dev/null || true
        fi
    done
}
# --- 超简化的状态保存 ---
save_deployment_status() {
    step "保存部署状态"
    
    # 计算统计数据
    local total_modules=$(( ${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + ${#SKIPPED_MODULES[@]} ))
    local success_rate=0
    if (( total_modules > 0 )); then
        success_rate=$(( ${#EXECUTED_MODULES[@]} * 100 / total_modules ))
    fi
    
    local ssh_port
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    
    # 直接写入 JSON 文件（不使用 jq）
    cat > "$STATUS_FILE" << EOF
{
  "script_version": "$SCRIPT_VERSION",
  "last_run": "$(date '+%Y-%m-%d %H:%M:%S')",
  "deployment_mode": "$(if $RERUN_MODE; then echo "update"; else echo "initial"; fi)",
  "executed_modules": ["$(printf '%s","' "${EXECUTED_MODULES[@]}" | sed 's/,$//')"],
  "failed_modules": ["$(printf '%s","' "${FAILED_MODULES[@]}" | sed 's/,$//')"],
  "skipped_modules": ["$(printf '%s","' "${SKIPPED_MODULES[@]}" | sed 's/,$//')"],
  "system_info": {
    "os": "$(lsb_release -ds 2>/dev/null || echo 'Debian')",
    "kernel": "$(uname -r)",
    "ssh_port": "$ssh_port",
    "backup_path": "$BACKUP_PATH"
  },
  "statistics": {
    "total_modules": $total_modules,
    "success_rate": $success_rate
  }
}
EOF
    
    # 验证 JSON 格式
    if command -v jq >/dev/null && jq . "$STATUS_FILE" >/dev/null 2>&1; then
        ok "状态已保存到: $STATUS_FILE"
    elif [[ -f "$STATUS_FILE" ]]; then
        ok "状态已保存到: $STATUS_FILE (未验证JSON格式)"
    else
        warn "状态保存失败"
    fi
}

# --- 详细系统状态检查 ---
get_system_status() {
    local status_lines=()
    
    # Zsh 状态
    if command -v zsh &>/dev/null; then
        local zsh_version root_shell
        zsh_version=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
        root_shell=$(getent passwd root | cut -d: -f7)
        
        if [[ "$root_shell" == "$(which zsh)" ]]; then
            status_lines+=("Zsh Shell: 已安装并设为默认 (v$zsh_version)")
        else
            status_lines+=("Zsh Shell: 已安装但未设为默认 (v$zsh_version)")
        fi
    else
        status_lines+=("Zsh Shell: 未安装")
    fi
    
    # Docker 状态
    if command -v docker &>/dev/null; then
        local docker_version containers_count images_count
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        images_count=$(docker images -q 2>/dev/null | wc -l || echo "0")
        
        status_lines+=("Docker: 已安装 (v$docker_version, 容器:$containers_count, 镜像:$images_count)")
        
        if systemctl is-active --quiet docker 2>/dev/null; then
            status_lines+=("Docker 服务: 运行中")
        else
            status_lines+=("Docker 服务: 未运行")
        fi
    else
        status_lines+=("Docker: 未安装")
    fi
    
    # Mise 状态
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        local mise_version
        mise_version=$("$HOME/.local/bin/mise" --version 2>/dev/null || echo "未知")
        status_lines+=("Mise: 已安装 ($mise_version)")
    else
        status_lines+=("Mise: 未安装")
    fi
    
    # 网络优化状态
    local curr_cc curr_qdisc
    curr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    curr_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    status_lines+=("网络优化: 拥塞控制=$curr_cc, 队列调度=$curr_qdisc")
    
    # SSH 配置
    local ssh_port ssh_root_login
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    ssh_root_login=$(grep "^PermitRootLogin " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "未知")
    status_lines+=("SSH: 端口=$ssh_port, Root登录=$ssh_root_login")
    
    # 系统资源
    local cpu_cores total_mem free_mem disk_usage
    cpu_cores=$(nproc)
    total_mem=$(free -h | grep Mem | awk '{print $2}')
    free_mem=$(free -h | grep Mem | awk '{print $7}')
    disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    status_lines+=("系统资源: CPU=${cpu_cores}核, 内存=${total_mem}(可用${free_mem}), 磁盘使用=${disk_usage}")
    
    printf '%s\n' "${status_lines[@]}"
}

# --- 综合部署摘要 ---
# --- 综合部署摘要 ---
show_deployment_summary() {
    step "部署完成摘要"
    
    echo
    log "╔══════════════════════════════════════════════════════╗" "title"
    log "║                系统部署完成摘要                        ║" "title"
    log "╚══════════════════════════════════════════════════════╝" "title"
    
    # 基本信息
    show_info "脚本版本" "$SCRIPT_VERSION"
    show_info "部署模式" "$(if $RERUN_MODE; then echo "更新模式"; else echo "首次部署"; fi)"
    show_info "操作系统" "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')"
    show_info "内核版本" "$(uname -r)"
    show_info "部署时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    # 执行统计
    local total_modules=$(( ${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + ${#SKIPPED_MODULES[@]} ))
    local success_rate=0
    if (( total_modules > 0 )); then
        success_rate=$(( ${#EXECUTED_MODULES[@]} * 100 / total_modules ))
    fi
    
    echo
    log "📊 执行统计:" "title"
    show_info "总模块数" "$total_modules"
    show_info "成功执行" "${#EXECUTED_MODULES[@]} 个"
    show_info "执行失败" "${#FAILED_MODULES[@]} 个"
    show_info "跳过执行" "${#SKIPPED_MODULES[@]} 个"
    show_info "成功率" "${success_rate}%"
    
    # 成功执行的模块
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        echo
        log "✅ 成功执行的模块:" "info"
        for module in "${EXECUTED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "info"
        done
    fi
    
    # 失败的模块
    if (( ${#FAILED_MODULES[@]} > 0 )); then
        echo
        log "❌ 执行失败的模块:" "error"
        for module in "${FAILED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "error"
        done
    fi
    
    # 跳过的模块
    if (( ${#SKIPPED_MODULES[@]} > 0 )); then
        echo
        log "⏭️ 跳过的模块:" "warn"
        for module in "${SKIPPED_MODULES[@]}"; do
            log "   • $module: ${MODULES[$module]}" "warn"
        done
    fi
    
    # 当前系统状态
    echo
    log "🖥️ 当前系统状态:" "title"
    while IFS= read -r status_line; do
        log "   • $status_line" "info"
    done < <(get_system_status)
    
    # 文件位置信息
    echo
    log "📁 重要文件位置:" "title"
    show_info "状态文件" "$STATUS_FILE"
    show_info "日志文件" "$LOG_FILE"
    show_info "配置文件" "$CONFIG_FILE"
    if [[ -n "$BACKUP_PATH" ]] && [[ -d "$BACKUP_PATH" ]]; then
        show_info "备份位置" "$BACKUP_PATH"
    fi
    
    echo
    log "════════════════════════════════════════════════════════" "title"
}

# --- 最终提示和建议 ---
show_final_recommendations() {
    echo
    log "🎉 系统部署完成！" "title"
    
    # SSH 安全提醒
    if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
        local new_ssh_port
        new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        if [[ "$new_ssh_port" != "22" ]] && [[ -n "$new_ssh_port" ]]; then
            echo
            log "⚠️  重要安全提醒:" "warn"
            log "   SSH 端口已更改为: $new_ssh_port" "warn"
            log "   新的连接命令: ssh -p $new_ssh_port user@$(hostname -I | awk '{print $1}')" "warn"
            log "   请确保防火墙规则已正确配置！" "warn"
        fi
    fi
    
    # Zsh 使用指南
    if [[ " ${EXECUTED_MODULES[*]} " =~ " zsh-setup " ]]; then
        echo
        log "🐚 Zsh 使用指南:" "info"
        log "   切换到 Zsh: exec zsh" "info"
        log "   重新配置主题: p10k configure" "info"
        log "   查看可用插件: ls ~/.oh-my-zsh/plugins/" "info"
    fi
    
    # Docker 使用提示
    if [[ " ${EXECUTED_MODULES[*]} " =~ " docker-setup " ]]; then
        echo
        log "🐳 Docker 使用提示:" "info"
        log "   检查状态: docker version" "info"
        log "   管理服务: systemctl status docker" "info"
        log "   使用指南: docker --help" "info"
    fi
    
    # 系统维护建议
    echo
    log "🔧 系统维护建议:" "info"
    log "   定期更新: apt update && apt upgrade" "info"
    log "   重新运行脚本: bash $0 (支持增量更新)" "info"
    log "   查看日志: tail -f $LOG_FILE" "info"
    log "   生成配置: bash $0 --create-config" "info"
    log "   编辑配置: nano setup.conf" "info"
    
    # 故障恢复信息
    if [[ -n "$BACKUP_PATH" ]] && [[ -d "$BACKUP_PATH" ]]; then
        echo
        log "🔄 故障恢复:" "info"
        log "   回滚命令: bash $BACKUP_PATH/restore.sh" "info"
        log "   备份位置: $BACKUP_PATH" "info"
    fi
    
    echo
    log "感谢使用 Debian 系统部署脚本！" "title"
    log "如有问题，请查看日志文件或重新运行脚本。" "info"
}
# --- 命令行参数处理 ---
handle_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --create-config)
                if [[ -f "$CONFIG_FILE" ]]; then
                    log "配置文件已存在: $CONFIG_FILE" "warn"
                    read -p "是否覆盖现有配置文件? [y/N]: " -r overwrite_choice
                    if [[ ! "$overwrite_choice" =~ ^[Yy]$ ]]; then
                        log "操作已取消" "info"
                        exit 0
                    fi
                    backup_old_config
                fi
                create_sample_config
                log "配置文件创建完成，可以编辑后重新运行脚本" "info"
                exit 0
                ;;
            --check-status)
                if [[ -f "$STATUS_FILE" ]]; then
                    echo "最近部署状态:"
                    jq . "$STATUS_FILE" 2>/dev/null || cat "$STATUS_FILE"
                else
                    echo "未找到部署状态文件"
                fi
                exit 0
                ;;
            --rollback)
                if [[ -n "${2:-}" ]] && [[ -d "$2" ]]; then
                    BACKUP_PATH="$2"
                    perform_rollback
                    exit 0
                else
                    echo "用法: $0 --rollback /path/to/backup"
                    exit 1
                fi
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "Debian 部署脚本 v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
        shift
    done
}

# --- 帮助信息 ---
show_help() {
    cat << EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法: $0 [选项]

选项:
  --create-config    创建示例配置文件
  --check-status     查看最近的部署状态
  --rollback <path>  回滚到指定备份
  --help, -h         显示此帮助信息
  --version, -v      显示版本信息

功能模块:
  • system-optimize    系统优化 (Zram, 时区设置)
  • zsh-setup         Zsh Shell 环境配置
  • mise-setup        Mise 版本管理器安装
  • docker-setup      Docker 容器化平台
  • network-optimize  网络性能优化 (BBR, cake)
  • ssh-security      SSH 安全加固
  • auto-update-setup 自动更新系统配置

特性:
  ✓ 模块化部署      ✓ 并发下载        ✓ 依赖管理
  ✓ 配置文件支持    ✓ 备份回滚        ✓ 进度显示
  ✓ 签名验证        ✓ 预检查机制      ✓ 增量更新

配置文件: $CONFIG_FILE
状态文件: $STATUS_FILE
日志文件: $LOG_FILE

示例:
  $0                     # 交互式部署
  $0 --create-config     # 创建配置文件
  $0 --check-status      # 查看部署状态
EOF
}

# --- 主程序入口 ---
main() {
    # 处理命令行参数
    handle_arguments "$@"
    
    # 系统初始化
    init_system
    
    # 预检查
    preflight_check
    
    # 安装基础依赖
    install_dependencies
    
    # 设置 GPG 验证
    setup_gpg_verification
    
    # 创建系统备份
    create_system_backup
    
    # 清理旧备份
    cleanup_old_backups
    
    # 系统更新
    system_update
    
    # 模块化部署
    deploy_modules
    
    # 保存部署状态
    save_deployment_status
    
    # 显示部署摘要
    show_deployment_summary
    
    # 最终建议
    show_final_recommendations
    
    log "🎯 所有部署任务完成！" "title"
}

# 执行主程序
main "$@"
