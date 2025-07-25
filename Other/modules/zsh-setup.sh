#!/bin/bash
# Zsh Shell 环境配置模块 v2.1.0 (优化版)
# 功能: Zsh安装, Oh My Zsh配置, 插件管理, 主题配置
# 适配主脚本框架
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="zsh-setup"
ZSH_INSTALL_DIR="$HOME/.oh-my-zsh"
ZSH_CONFIG_FILE="$HOME/.zshrc"
P10K_CONFIG_FILE="$HOME/.p10k.zsh"
BACKUP_DIR="/var/backups/zsh-setup"
TEMP_DIR="/tmp/zsh_setup"
# 网络配置
OH_MY_ZSH_REPO="https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
P10K_REPO="https://github.com/romkatv/powerlevel10k.git"
DOWNLOAD_TIMEOUT=30
MAX_RETRIES=3
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
    local required_commands=("curl" "git" "getent" "chsh")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            return 1
        fi
        debug_log "命令检查通过: $cmd"
    done
    
    # 检查网络连接
    if ! check_network_connectivity; then
        log "网络连接检查失败，可能影响下载" "warn"
    fi
    
    # 检查磁盘空间 (至少需要100MB)
    local available_space=$(df "$HOME" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 102400 ]; then
        log "磁盘空间不足，至少需要100MB" "error"
        return 1
    fi
    
    # 创建必要目录
    mkdir -p "$BACKUP_DIR" "$TEMP_DIR"
    
    return 0
}
# 网络连接检查
check_network_connectivity() {
    debug_log "检查网络连接..."
    
    local test_urls=(
        "https://github.com"
        "https://raw.githubusercontent.com"
    )
    
    for url in "${test_urls[@]}"; do
        if timeout 10 curl -fsSL --connect-timeout 5 "$url" &>/dev/null; then
            debug_log "网络连接正常: $url"
            return 0
        fi
    done
    
    return 1
}
# 备份现有配置
backup_existing_config() {
    log "备份现有配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份相关文件和目录
    local backup_items=(
        "$HOME/.zshrc"
        "$HOME/.p10k.zsh"
        "$HOME/.oh-my-zsh"
        "$HOME/.zsh_history"
        "/etc/passwd"
    )
    
    for item in "${backup_items[@]}"; do
        if [ -e "$item" ]; then
            if [ -d "$item" ]; then
                cp -r "$item" "$backup_path/" 2>/dev/null || true
            else
                cp "$item" "$backup_path/" 2>/dev/null || true
            fi
            debug_log "已备份: $item"
        fi
    done
    
    # 记录当前Shell状态
    {
        echo "=== Zsh配置前状态 ==="
        echo "时间: $(date)"
        echo "当前Shell: $SHELL"
        echo "当前用户: $(whoami)"
        echo ""
        echo "=== 系统Shell信息 ==="
        cat /etc/shells 2>/dev/null || echo "无法读取/etc/shells"
        echo ""
        echo "=== 用户Shell配置 ==="
        getent passwd "$(whoami)" 2>/dev/null || echo "无法获取用户信息"
        echo ""
        echo "=== 现有Zsh相关文件 ==="
        ls -la "$HOME"/.zsh* 2>/dev/null || echo "无Zsh相关文件"
    } > "$backup_path/shell_status_before.txt"
    
    # 清理旧备份 (保留最近5个)
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +6 | xargs rm -rf 2>/dev/null || true
    
    debug_log "配置备份完成: $backup_path"
}
# 检查并安装Zsh
install_zsh() {
    log "检查并安装Zsh..." "info"
    
    # 检查Zsh是否已安装
    if command -v zsh &>/dev/null; then
        local zsh_version=$(zsh --version 2>/dev/null | head -n1 | awk '{print $2}')
        log "Zsh已安装 (版本: ${zsh_version:-未知})" "info"
        export ZSH_VERSION="$zsh_version"
        return 0
    fi
    
    log "安装Zsh..." "info"
    
    # 更新包列表
    if ! apt update; then
        log "包列表更新失败" "error"
        return 1
    fi
    
    # 安装Zsh和相关工具
    local packages=("zsh" "git" "curl" "wget")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii\s*$package\s"; then
            debug_log "安装包: $package"
            if ! apt install -y "$package"; then
                log "包安装失败: $package" "error"
                return 1
            fi
        fi
    done
    
    # 验证安装
    if command -v zsh &>/dev/null; then
        local zsh_version=$(zsh --version 2>/dev/null | head -n1 | awk '{print $2}')
        log "Zsh安装成功 (版本: ${zsh_version:-未知})" "success"
        export ZSH_VERSION="$zsh_version"
    else
        log "Zsh安装失败" "error"
        return 1
    fi
    
    return 0
}
# 安装Oh My Zsh
install_oh_my_zsh() {
    log "安装Oh My Zsh..." "info"
    
    # 检查是否已安装
    if [ -d "$ZSH_INSTALL_DIR" ] && [ -f "$ZSH_INSTALL_DIR/oh-my-zsh.sh" ]; then
        log "Oh My Zsh已存在" "info"
        return 0
    fi
    
    # 下载安装脚本
    local install_script="$TEMP_DIR/install_oh_my_zsh.sh"
    
    if ! download_with_retry "$OH_MY_ZSH_REPO" "$install_script"; then
        log "Oh My Zsh安装脚本下载失败" "error"
        return 1
    fi
    
    # 设置环境变量避免交互
    export RUNZSH=no
    export CHSH=no
    export KEEP_ZSHRC=yes
    
    # 执行安装
    debug_log "执行Oh My Zsh安装脚本"
    if sh "$install_script" --unattended; then
        log "Oh My Zsh安装成功" "success"
    else
        log "Oh My Zsh安装失败" "error"
        return 1
    fi
    
    # 验证安装
    if [ -d "$ZSH_INSTALL_DIR" ] && [ -f "$ZSH_INSTALL_DIR/oh-my-zsh.sh" ]; then
        debug_log "Oh My Zsh安装验证成功"
    else
        log "Oh My Zsh安装验证失败" "error"
        return 1
    fi
    
    return 0
}
# 带重试的下载函数
download_with_retry() {
    local url="$1"
    local output="$2"
    local retry_count=0
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        debug_log "下载尝试 $((retry_count + 1))/$MAX_RETRIES: $url"
        
        if timeout "$DOWNLOAD_TIMEOUT" curl -fsSL \
            --connect-timeout 10 \
            --max-time "$DOWNLOAD_TIMEOUT" \
            -H "User-Agent: zsh-setup/$MODULE_NAME" \
            "$url" -o "$output"; then
            debug_log "下载成功: $url"
            return 0
        fi
        
        ((retry_count++))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            local wait_time=$((retry_count * 2))
            debug_log "下载失败，等待 ${wait_time}s 后重试"
            sleep "$wait_time"
        fi
    done
    
    log "下载失败 ($MAX_RETRIES 次尝试): $url" "error"
    return 1
}
# 安装Powerlevel10k主题
install_powerlevel10k() {
    log "安装Powerlevel10k主题..." "info"
    
    local theme_dir="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/themes/powerlevel10k"
    
    # 检查是否已安装
    if [ -d "$theme_dir" ] && [ -f "$theme_dir/powerlevel10k.zsh-theme" ]; then
        log "Powerlevel10k主题已存在，尝试更新..." "info"
        
        # 尝试更新
        if (cd "$theme_dir" && git pull --depth=1 origin master 2>/dev/null); then
            log "Powerlevel10k主题更新成功" "success"
        else
            log "Powerlevel10k主题更新失败，继续使用现有版本" "warn"
        fi
        return 0
    fi
    
    # 创建主题目录
    mkdir -p "$(dirname "$theme_dir")"
    
    # 克隆主题仓库
    debug_log "克隆Powerlevel10k仓库到: $theme_dir"
    if git clone --depth=1 "$P10K_REPO" "$theme_dir"; then
        log "Powerlevel10k主题安装成功" "success"
    else
        log "Powerlevel10k主题安装失败" "error"
        return 1
    fi
    
    # 验证安装
    if [ -f "$theme_dir/powerlevel10k.zsh-theme" ]; then
        debug_log "Powerlevel10k主题验证成功"
    else
        log "Powerlevel10k主题验证失败" "error"
        return 1
    fi
    
    return 0
}
# 安装Zsh插件
install_zsh_plugins() {
    log "安装Zsh插件..." "info"
    
    local custom_plugins="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/plugins"
    mkdir -p "$custom_plugins"
    
    # 定义插件配置
    declare -A plugins=(
        ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions.git"
        ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
        ["zsh-completions"]="https://github.com/zsh-users/zsh-completions.git"
        ["zsh-history-substring-search"]="https://github.com/zsh-users/zsh-history-substring-search.git"
    )
    
    local failed_plugins=()
    local installed_plugins=()
    
    # 安装或更新插件
    for plugin in "${!plugins[@]}"; do
        local plugin_dir="$custom_plugins/$plugin"
        
        if [ -d "$plugin_dir" ] && [ -d "$plugin_dir/.git" ]; then
            debug_log "更新插件: $plugin"
            if (cd "$plugin_dir" && git pull origin master 2>/dev/null); then
                installed_plugins+=("$plugin")
                debug_log "插件更新成功: $plugin"
            else
                log "插件更新失败: $plugin" "warn"
                installed_plugins+=("$plugin")  # 继续使用现有版本
            fi
        else
            debug_log "安装插件: $plugin"
            if git clone --depth=1 "${plugins[$plugin]}" "$plugin_dir" 2>/dev/null; then
                installed_plugins+=("$plugin")
                debug_log "插件安装成功: $plugin"
            else
                failed_plugins+=("$plugin")
                log "插件安装失败: $plugin" "warn"
            fi
        fi
    done
    
    # 报告安装结果
    if [ ${#installed_plugins[@]} -gt 0 ]; then
        log "成功安装/更新插件: ${installed_plugins[*]}" "success"
    fi
    
    if [ ${#failed_plugins[@]} -gt 0 ]; then
        log "插件安装失败: ${failed_plugins[*]}" "warn"
    fi
    
    return 0
}
# 生成.zshrc配置
generate_zshrc_config() {
    log "生成.zshrc配置..." "info"
    
    # 备份现有配置
    if [ -f "$ZSH_CONFIG_FILE" ]; then
        local backup_file="${ZSH_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$ZSH_CONFIG_FILE" "$backup_file"
        debug_log "已备份现有.zshrc: $backup_file"
    fi
    
    # 生成新配置
    cat > "$ZSH_CONFIG_FILE" << 'EOF'
# ===============================================
# Zsh配置文件 - 由zsh-setup模块自动生成
# ===============================================
# Oh My Zsh 基础配置
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
# 更新设置
DISABLE_UPDATE_PROMPT="true"
UPDATE_ZSH_DAYS=7
DISABLE_AUTO_UPDATE="false"
# 插件配置
plugins=(
    # 核心插件
    git
    sudo
    history
    
    # 增强插件
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    zsh-history-substring-search
    
    # 工具插件
    docker
    kubectl
    web-search
    colored-man-pages
    command-not-found
    
    # 系统插件
    systemd
    rsync
)
# 加载Oh My Zsh
source $ZSH/oh-my-zsh.sh
# 自动补全配置
autoload -U compinit
compinit
# 环境变量
export PATH="$HOME/.local/bin:$PATH"
export EDITOR="nano"
export LANG="en_US.UTF-8"
# mise版本管理器支持
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi
# Docker Compose支持
if command -v docker-compose >/dev/null 2>&1; then
    alias dc="docker-compose"
    alias dcu="docker-compose up -d"
    alias dcd="docker-compose down"
    alias dcr="docker-compose restart"
fi
# 系统管理别名
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"
alias upgrade="apt update && apt full-upgrade -y"
alias update="apt update -y"
alias autoclean="apt autoremove -y && apt autoclean"
alias sysinfo="neofetch 2>/dev/null || echo 'neofetch not installed'"
# Docker管理别名
alias dps="docker ps"
alias dpsa="docker ps -a"
alias di="docker images"
alias dclean="docker system prune -af"
alias dlogs="docker logs -f"
# 网络工具别名
alias myip="curl -s ifconfig.me && echo"
alias ports="netstat -tuln"
alias ping="ping -c 5"
# 自定义函数
# 快速搜索文件
function ff() {
    find . -type f -name "*$1*" 2>/dev/null
}
# 快速创建并进入目录
function mkcd() {
    mkdir -p "$1" && cd "$1"
}
# 系统状态检查
function sysstatus() {
    echo "=== 系统状态 ==="
    echo "负载: $(uptime | cut -d',' -f3-5)"
    echo "内存: $(free -h | grep '^Mem' | awk '{print $3"/"$2}')"
    echo "磁盘: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
    echo "进程: $(ps aux | wc -l) 个"
}
# Powerlevel10k配置
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
# 历史记录配置
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_BEEP
# 自动建议配置
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666"
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
# 语法高亮配置
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)
# 自定义配置加载
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
EOF
    
    log ".zshrc配置生成成功" "success"
}
# 配置Powerlevel10k主题
configure_powerlevel10k() {
    log "配置Powerlevel10k主题..." "info"
    
    local p10k_config_dir="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/themes/powerlevel10k/config"
    local rainbow_config="$p10k_config_dir/p10k-rainbow.zsh"
    
    # 检查预设配置文件
    if [ -f "$rainbow_config" ]; then
        cp "$rainbow_config" "$P10K_CONFIG_FILE"
        log "使用Rainbow主题预设配置" "info"
    else
        # 如果预设不存在，生成基础配置
        log "生成基础Powerlevel10k配置..." "info"
        generate_p10k_config
    fi
    
    # 验证配置
    if [ -f "$P10K_CONFIG_FILE" ]; then
        log "Powerlevel10k配置完成" "success"
    else
        log "Powerlevel10k配置生成失败" "error"
        return 1
    fi
    
    return 0
}
# 生成基础P10K配置
generate_p10k_config() {
    cat > "$P10K_CONFIG_FILE" << 'EOF'
# Powerlevel10k基础配置
# 自动生成的简化配置
# 启用即时提示
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
# 配置提示符元素
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    dir
    vcs
    prompt_char
)
typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
    command_execution_time
    background_jobs
    time
)
# 基础样式配置
typeset -g POWERLEVEL9K_MODE='nerdfont-complete'
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=76
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
# 目录显示配置
typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
typeset -g POWERLEVEL9K_SHORTEN_DELIMITER='…'
# Git配置
typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=39
# 时间配置
typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M:%S}'
EOF
}
# 配置默认Shell
configure_default_shell() {
    log "配置默认Shell..." "info"
    
    local current_user=$(whoami)
    local current_shell=$(getent passwd "$current_user" | cut -d: -f7)
    local zsh_path=$(which zsh)
    
    log "当前用户: $current_user" "info"
    log "当前Shell: $current_shell" "info"
    log "Zsh路径: $zsh_path" "info"
    
    if [ "$current_shell" = "$zsh_path" ]; then
        log "Zsh已是默认Shell" "info"
        return 0
    fi
    
    # 在批处理模式下自动设置
    if [ "${BATCH_MODE:-false}" = "true" ] || [ "${AUTO_SET_DEFAULT_SHELL:-false}" = "true" ]; then
        if chsh -s "$zsh_path" "$current_user"; then
            log "Zsh已设置为默认Shell (重新登录后生效)" "success"
        else
            log "设置默认Shell失败" "error"
            return 1
        fi
    else
        # 交互模式询问用户
        echo
        read -p "是否将Zsh设置为默认Shell? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if chsh -s "$zsh_path" "$current_user"; then
                log "Zsh已设置为默认Shell (重新登录后生效)" "success"
            else
                log "设置默认Shell失败" "error"
                return 1
            fi
        else
            log "保持当前Shell设置" "info"
        fi
    fi
    
    return 0
}
# 验证安装结果
verify_installation() {
    log "验证Zsh环境安装..." "info"
    
    local verification_failed=false
    
    # 检查Zsh
    if ! command -v zsh &>/dev/null; then
        log "✗ Zsh未正确安装" "error"
        verification_failed=true
    else
        log "✓ Zsh安装正确" "success"
    fi
    
    # 检查Oh My Zsh
    if [ ! -d "$ZSH_INSTALL_DIR" ] || [ ! -f "$ZSH_INSTALL_DIR/oh-my-zsh.sh" ]; then
        log "✗ Oh My Zsh未正确安装" "error"
        verification_failed=true
    else
        log "✓ Oh My Zsh安装正确" "success"
    fi
    
    # 检查主题
    local theme_dir="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/themes/powerlevel10k"
    if [ ! -d "$theme_dir" ] || [ ! -f "$theme_dir/powerlevel10k.zsh-theme" ]; then
        log "✗ Powerlevel10k主题未正确安装" "error"
        verification_failed=true
    else
        log "✓ Powerlevel10k主题安装正确" "success"
    fi
    
    # 检查配置文件
    if [ ! -f "$ZSH_CONFIG_FILE" ]; then
        log "✗ .zshrc配置文件不存在" "error"
        verification_failed=true
    else
        log "✓ .zshrc配置文件存在" "success"
    fi
    
    # 检查插件 (至少要有基础插件)
    local plugins_dir="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/plugins"
    local essential_plugins=("zsh-autosuggestions" "zsh-syntax-highlighting")
    for plugin in "${essential_plugins[@]}"; do
        if [ ! -d "$plugins_dir/$plugin" ]; then
            log "✗ 插件未安装: $plugin" "warn"
        else
            log "✓ 插件安装正确: $plugin" "success"
        fi
    done
    
    if [ "$verification_failed" = "true" ]; then
        log "Zsh环境验证失败" "error"
        return 1
    else
        log "Zsh环境验证成功" "success"
        return 0
    fi
}
# 生成安装报告
generate_installation_report() {
    log "生成安装报告..." "info"
    
    local report_file="$BACKUP_DIR/zsh_installation_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "==============================================="
        echo "Zsh环境安装报告"
        echo "生成时间: $(date)"
        echo "==============================================="
        echo ""
        
        echo "=== 系统信息 ==="
        echo "用户: $(whoami)"
        echo "主目录: $HOME"
        echo "操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
        echo ""
        
        echo "=== 安装信息 ==="
        echo "Zsh版本: $(zsh --version 2>/dev/null || echo '未安装')"
        echo "Zsh路径: $(which zsh 2>/dev/null || echo '未找到')"
        echo "当前Shell: $SHELL"
        echo ""
        
        echo "=== 目录结构 ==="
        echo "Oh My Zsh: $ZSH_INSTALL_DIR"
        if [ -d "$ZSH_INSTALL_DIR" ]; then
            echo "  - 大小: $(du -sh "$ZSH_INSTALL_DIR" 2>/dev/null | cut -f1)"
            echo "  - 主题数量: $(find "$ZSH_INSTALL_DIR/themes" -name "*.zsh-theme" 2>/dev/null | wc -l)"
            echo "  - 插件数量: $(find "$ZSH_INSTALL_DIR/plugins" -maxdepth 1 -type d 2>/dev/null | wc -l)"
        fi
        echo ""
        
        echo "=== 自定义插件 ==="
        local custom_plugins="${ZSH_CUSTOM:-$ZSH_INSTALL_DIR/custom}/plugins"
        if [ -d "$custom_plugins" ]; then
            find "$custom_plugins" -maxdepth 1 -type d -not -path "$custom_plugins" | while read dir; do
                echo "  - $(basename "$dir")"
            done
        else
            echo "  无自定义插件"
        fi
        echo ""
        
        echo "=== 配置文件 ==="
        echo ".zshrc: $([ -f "$ZSH_CONFIG_FILE" ] && echo "存在" || echo "不存在")"
        echo ".p10k.zsh: $([ -f "$P10K_CONFIG_FILE" ] && echo "存在" || echo "不存在")"
        echo ""
        
        echo "=== 使用提示 ==="
        echo "1. 运行 'exec zsh' 立即切换到新环境"
        echo "2. 运行 'p10k configure' 重新配置主题"
        echo "3. 编辑 ~/.zshrc.local 添加个人配置"
        echo "4. 运行 'omz update' 更新Oh My Zsh"
        echo ""
        
    } > "$report_file"
    
    log "安装报告已生成: $report_file" "info"
}
# 主执行函数
main() {
    log "开始Zsh环境配置..." "info"
    
    # 检查系统要求
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 备份现有配置
    backup_existing_config
    
    # 安装Zsh
    if ! install_zsh; then
        log "Zsh安装失败" "error"
        exit 1
    fi
    
    # 安装Oh My Zsh
    if ! install_oh_my_zsh; then
        log "Oh My Zsh安装失败" "error"
        exit 1
    fi
    
    # 安装主题
    if ! install_powerlevel10k; then
        log "Powerlevel10k主题安装失败" "error"
        exit 1
    fi
    
    # 安装插件
    install_zsh_plugins  # 插件安装失败不影响整体流程
    
    # 生成配置
    if ! generate_zshrc_config; then
        log "配置文件生成失败" "error"
        exit 1
    fi
    
    # 配置主题
    if ! configure_powerlevel10k; then
        log "主题配置失败" "error"
        exit 1
    fi
    
    # 配置默认Shell
    configure_default_shell
    
    # 验证安装
    if ! verify_installation; then
        log "安装验证失败" "error"
        exit 1
    fi
    
    # 生成报告
    generate_installation_report
    
    # 清理临时文件
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    
    log "Zsh环境配置完成！" "success"
    log "建议: 运行 'exec zsh' 立即体验新环境" "info"
    
    return 0
}
# 执行主函数
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
exit 0
