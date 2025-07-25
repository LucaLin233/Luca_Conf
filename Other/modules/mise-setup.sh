#!/bin/bash
# Mise 版本管理器配置模块 v2.1.0 (优化版)
# 功能: 安装Mise, 配置Python环境, Shell集成, 工具链管理
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="mise-setup"
MISE_INSTALL_DIR="$HOME/.local/bin"
MISE_PATH="$MISE_INSTALL_DIR/mise"
MISE_CONFIG_DIR="$HOME/.config/mise"
BACKUP_DIR="/var/backups/mise-setup"
# 默认工具版本配置
DEFAULT_PYTHON_VERSION="3.11"
DEFAULT_NODE_VERSION="lts"
ADDITIONAL_TOOLS=()
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
    local required_commands=("curl" "tar" "gzip")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            return 1
        fi
        debug_log "命令检查通过: $cmd"
    done
    
    # 检查网络连接
    if ! curl -s --connect-timeout 5 "https://mise.run" >/dev/null; then
        log "无法连接到Mise官网，请检查网络" "error"
        return 1
    fi
    
    # 检查系统架构
    local arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64|armv7l)
            debug_log "系统架构支持: $arch"
            ;;
        *)
            log "不支持的系统架构: $arch" "warn"
            ;;
    esac
    
    # 检查磁盘空间 (Python编译需要较多空间)
    local available_space=$(df "$HOME" | awk 'NR==2 {print $4}')
    local required_space=1048576  # 1GB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "磁盘空间可能不足: $((available_space/1024))MB (建议 >= 1GB)" "warn"
    else
        debug_log "磁盘空间充足: $((available_space/1024))MB"
    fi
    
    # 创建必要目录
    mkdir -p "$MISE_INSTALL_DIR" "$MISE_CONFIG_DIR" "$BACKUP_DIR"
    
    return 0
}
# 备份现有配置
backup_existing_config() {
    log "备份现有配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份mise相关文件
    local backup_files=(
        "$MISE_PATH"
        "$MISE_CONFIG_DIR"
        "$HOME/.bashrc"
        "$HOME/.zshrc"
        "$HOME/.mise.toml"
        "$HOME/.tool-versions"
    )
    
    for file in "${backup_files[@]}"; do
        if [ -e "$file" ]; then
            local backup_name=$(basename "$file")
            cp -r "$file" "$backup_path/$backup_name" 2>/dev/null || true
            debug_log "已备份: $file"
        fi
    done
    
    # 清理旧备份 (保留最近5个)
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +6 | xargs rm -rf 2>/dev/null || true
    
    debug_log "配置备份完成: $backup_path"
}
# 检测现有安装
detect_existing_installation() {
    log "检测现有安装..." "info"
    
    # 检查Mise是否已安装
    if [ -f "$MISE_PATH" ] && [ -x "$MISE_PATH" ]; then
        local current_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $1}' || echo "未知")
        log "检测到现有Mise安装 (版本: $current_version)" "info"
        
        # 检查是否需要更新
        local latest_version=$(get_latest_mise_version)
        if [ "$current_version" != "$latest_version" ] && [ "$latest_version" != "unknown" ]; then
            log "发现新版本: $latest_version (当前: $current_version)" "info"
            
            if [ "${BATCH_MODE:-false}" != "true" ]; then
                read -p "是否更新到最新版本? (Y/n): " update_choice
                if [[ ! "$update_choice" =~ ^[Nn]$ ]]; then
                    export FORCE_REINSTALL=true
                fi
            else
                log "批量模式: 自动更新到最新版本" "info"
                export FORCE_REINSTALL=true
            fi
        else
            log "当前版本已是最新" "info"
            export SKIP_INSTALLATION=true
        fi
    else
        log "未检测到Mise安装" "info"
        export FORCE_REINSTALL=true
    fi
    
    # 检查其他版本管理器冲突
    check_version_manager_conflicts
}
get_latest_mise_version() {
    local version
    version=$(curl -s "https://api.github.com/repos/jdx/mise/releases/latest" | \
             grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' 2>/dev/null || echo "unknown")
    echo "$version"
}
check_version_manager_conflicts() {
    local conflicts=()
    
    # 检查常见的版本管理器
    local managers=("pyenv" "nvm" "rbenv" "nodenv")
    
    for manager in "${managers[@]}"; do
        if command -v "$manager" &>/dev/null; then
            conflicts+=("$manager")
            debug_log "检测到版本管理器: $manager"
        fi
    done
    
    if [ ${#conflicts[@]} -gt 0 ]; then
        log "检测到其他版本管理器: ${conflicts[*]}" "warn"
        log "建议在使用Mise前禁用这些工具以避免冲突" "warn"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否继续安装Mise? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                log "用户取消安装" "info"
                exit 0
            fi
        fi
    fi
}
# 安装Python编译依赖
install_python_build_deps() {
    log "检查Python编译依赖..." "info"
    
    local python_deps=(
        "build-essential"
        "libssl-dev"
        "zlib1g-dev"
        "libbz2-dev"
        "libreadline-dev"
        "libsqlite3-dev"
        "libncursesw5-dev"
        "xz-utils"
        "tk-dev"
        "libxml2-dev"
        "libxmlsec1-dev"
        "libffi-dev"
        "liblzma-dev"
    )
    
    local missing_deps=()
    
    for dep in "${python_deps[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$dep"; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "安装Python编译依赖: ${missing_deps[*]}" "info"
        
        if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
            log "软件包列表更新失败" "warn"
        fi
        
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_deps[@]}"; then
            log "Python编译依赖安装完成" "success"
        else
            log "部分依赖安装失败，Python编译可能会失败" "warn"
        fi
    else
        log "Python编译依赖已满足" "info"
    fi
}
# 安全的Mise安装
install_mise_safely() {
    log "开始安装Mise..." "info"
    
    if [ "${SKIP_INSTALLATION:-false}" = "true" ]; then
        log "跳过Mise安装" "info"
        return 0
    fi
    
    # 方法1: 使用官方安装脚本
    if install_mise_official; then
        return 0
    fi
    
    # 方法2: 手动下载二进制文件
    log "官方脚本失败，尝试手动安装..." "warn"
    if install_mise_manual; then
        return 0
    fi
    
    log "Mise安装失败" "error"
    return 1
}
install_mise_official() {
    local install_script="/tmp/mise-install.sh"
    
    # 下载安装脚本
    log "下载Mise安装脚本..." "info"
    if ! curl -fsSL --connect-timeout 15 --max-time 60 \
         "https://mise.run" -o "$install_script"; then
        debug_log "Mise安装脚本下载失败"
        return 1
    fi
    
    # 验证脚本内容
    if ! grep -q "mise" "$install_script"; then
        debug_log "Mise安装脚本验证失败"
        rm -f "$install_script"
        return 1
    fi
    
    # 设置安装环境变量
    export MISE_INSTALL_PATH="$MISE_PATH"
    
    # 执行安装
    log "执行Mise安装..." "info"
    if bash "$install_script" 2>/dev/null; then
        rm -f "$install_script"
        
        if [ -f "$MISE_PATH" ] && [ -x "$MISE_PATH" ]; then
            local installed_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $1}' || echo "未知")
            log "Mise安装成功 (版本: $installed_version)" "success"
            return 0
        fi
    fi
    
    rm -f "$install_script"
    return 1
}
install_mise_manual() {
    local arch=$(uname -m)
    local mise_arch=""
    
    case "$arch" in
        x86_64) mise_arch="x86_64" ;;
        aarch64) mise_arch="arm64" ;;
        armv7l) mise_arch="armv7" ;;
        *)
            log "不支持的架构进行手动安装: $arch" "error"
            return 1
            ;;
    esac
    
    local latest_version=$(get_latest_mise_version)
    if [ "$latest_version" = "unknown" ]; then
        latest_version="v2024.1.0"  # 备用版本
    fi
    
    local download_url="https://github.com/jdx/mise/releases/download/v${latest_version}/mise-v${latest_version}-linux-${mise_arch}.tar.gz"
    local temp_archive="/tmp/mise.tar.gz"
    local temp_dir="/tmp/mise-extract"
    
    log "下载Mise二进制文件 (v${latest_version})..." "info"
    if curl -fsSL --connect-timeout 15 --max-time 120 \
            "$download_url" -o "$temp_archive"; then
        
        # 解压缩
        mkdir -p "$temp_dir"
        if tar -xzf "$temp_archive" -C "$temp_dir" 2>/dev/null; then
            
            # 查找mise可执行文件
            local mise_binary=$(find "$temp_dir" -name "mise" -type f -executable | head -1)
            
            if [ -n "$mise_binary" ] && [ -x "$mise_binary" ]; then
                cp "$mise_binary" "$MISE_PATH"
                chmod +x "$MISE_PATH"
                
                if [ -f "$MISE_PATH" ] && [ -x "$MISE_PATH" ]; then
                    log "Mise手动安装成功" "success"
                    rm -rf "$temp_archive" "$temp_dir"
                    return 0
                fi
            fi
        fi
    fi
    
    rm -rf "$temp_archive" "$temp_dir" 2>/dev/null || true
    return 1
}
# --- Python环境配置优化 ---
configure_python_environment() {
    log "配置Python环境..." "info"
    
    # 检查是否需要安装Python
    local python_version="${DEFAULT_PYTHON_VERSION}"
    
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "可用的Python版本:" "info"
        log "  • 3.8  - 稳定版本" "info"
        log "  • 3.9  - 稳定版本" "info"
        log "  • 3.10 - 推荐版本" "info"
        log "  • 3.11 - 最新稳定版 (默认)" "info"
        log "  • 3.12 - 最新版本" "info"
        
        read -p "请选择Python版本 (直接回车使用 ${DEFAULT_PYTHON_VERSION}): " user_python_version
        if [ -n "$user_python_version" ]; then
            python_version="$user_python_version"
        fi
    fi
    
    log "准备安装Python $python_version..." "info"
    
    # 检查Python是否已通过mise安装
    if check_python_installed "$python_version"; then
        log "Python $python_version 已通过Mise安装" "info"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否重新安装? (y/N): " reinstall_choice
            if [[ ! "$reinstall_choice" =~ ^[Yy]$ ]]; then
                log "保持现有Python安装" "info"
                return 0
            fi
        else
            log "批量模式: 保持现有安装" "info"
            return 0
        fi
    fi
    
    # 安装Python
    if install_python_with_mise "$python_version"; then
        log "Python $python_version 安装成功" "success"
    else
        log "Python $python_version 安装失败" "error"
        return 1
    fi
    
    # 配置全局Python
    configure_global_python "$python_version"
    
    # 安装常用Python包
    install_common_python_packages "$python_version"
    
    return 0
}
check_python_installed() {
    local version="$1"
    
    if ! "$MISE_PATH" list python 2>/dev/null | grep -q "$version"; then
        return 1
    fi
    
    # 检查Python是否可执行
    if "$MISE_PATH" which python 2>/dev/null | grep -q "$version"; then
        return 0
    fi
    
    return 1
}
install_python_with_mise() {
    local version="$1"
    local max_retries=2
    local retry_count=0
    
    # 设置编译环境变量
    export CONFIGURE_OPTS="--enable-optimizations --with-lto"
    export CPPFLAGS="-I/usr/include/openssl"
    export LDFLAGS="-L/usr/lib/x86_64-linux-gnu"
    
    while [ $retry_count -lt $max_retries ]; do
        log "安装Python $version (尝试 $((retry_count + 1))/$max_retries)..." "info"
        
        # 显示安装进度提示
        {
            echo "正在编译Python $version，这可能需要几分钟..."
            echo "如果安装时间过长，可以按 Ctrl+C 取消"
        } | while IFS= read -r line; do
            log "$line" "info"
        done
        
        # 执行安装 (后台运行，显示进度)
        local install_log="/tmp/mise-python-install.log"
        local install_pid=""
        
        # 启动安装进程
        ("$MISE_PATH" use -g "python@$version" 2>&1 | tee "$install_log") &
        install_pid=$!
        
        # 显示进度
        show_python_install_progress "$install_pid" "$install_log" &
        local progress_pid=$!
        
        # 等待安装完成
        if wait "$install_pid"; then
            kill "$progress_pid" 2>/dev/null || true
            
            # 验证安装
            if verify_python_installation "$version"; then
                log "Python $version 安装并验证成功" "success"
                rm -f "$install_log"
                return 0
            else
                log "Python $version 安装验证失败" "warn"
            fi
        else
            kill "$progress_pid" 2>/dev/null || true
            log "Python $version 安装失败" "warn"
            
            # 显示错误日志摘要
            if [ -f "$install_log" ]; then
                log "安装错误摘要:" "error"
                tail -n 10 "$install_log" | while IFS= read -r line; do
                    log "  $line" "error"
                done
            fi
        fi
        
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            log "等待 10 秒后重试..." "info"
            sleep 10
        fi
    done
    
    rm -f "$install_log"
    return 1
}
show_python_install_progress() {
    local install_pid="$1"
    local log_file="$2"
    local dots=""
    
    while kill -0 "$install_pid" 2>/dev/null; do
        # 检查日志文件中的关键进度信息
        if [ -f "$log_file" ]; then
            local last_line=$(tail -n 1 "$log_file" 2>/dev/null || echo "")
            
            if echo "$last_line" | grep -q "Downloading"; then
                printf "\r下载中%s" "$dots"
            elif echo "$last_line" | grep -q "Extracting\|Building"; then
                printf "\r编译中%s" "$dots"
            elif echo "$last_line" | grep -q "Installing"; then
                printf "\r安装中%s" "$dots"
            else
                printf "\r处理中%s" "$dots"
            fi
        else
            printf "\r准备中%s" "$dots"
        fi
        
        # 更新进度点
        dots="${dots}."
        if [ ${#dots} -gt 3 ]; then
            dots=""
        fi
        
        sleep 2
    done
    
    printf "\r                    \r"  # 清理进度显示
}
verify_python_installation() {
    local version="$1"
    
    # 检查mise是否识别Python
    if ! "$MISE_PATH" which python &>/dev/null; then
        debug_log "mise无法找到python命令"
        return 1
    fi
    
    # 检查Python版本
    local installed_version
    installed_version=$("$MISE_PATH" exec python -- python --version 2>&1 | awk '{print $2}' || echo "")
    
    if [[ "$installed_version" == "$version"* ]]; then
        debug_log "Python版本验证通过: $installed_version"
        return 0
    else
        debug_log "Python版本验证失败: 期望 $version, 实际 $installed_version"
        return 1
    fi
}
configure_global_python() {
    local version="$1"
    
    log "配置全局Python环境..." "info"
    
    # 设置全局Python版本
    if "$MISE_PATH" use -g "python@$version" 2>/dev/null; then
        log "已设置全局Python版本: $version" "info"
    else
        log "设置全局Python版本失败" "warn"
        return 1
    fi
    
    # 创建系统级Python链接 (可选)
    if [ "${CREATE_SYSTEM_LINKS:-true}" = "true" ]; then
        create_python_system_links "$version"
    fi
    
    return 0
}
create_python_system_links() {
    local version="$1"
    
    log "创建系统级Python链接..." "info"
    
    # 获取mise管理的Python路径
    local mise_python_path
    mise_python_path=$("$MISE_PATH" which python 2>/dev/null)
    
    if [ -z "$mise_python_path" ] || [ ! -x "$mise_python_path" ]; then
        log "无法获取mise Python路径" "warn"
        return 1
    fi
    
    # 获取实际Python可执行文件路径
    local real_python_path
    real_python_path=$("$mise_python_path" -c 'import sys; print(sys.executable)' 2>/dev/null)
    
    if [ -z "$real_python_path" ] || [ ! -x "$real_python_path" ]; then
        log "无法获取实际Python路径" "warn"
        return 1
    fi
    
    # 备份现有链接
    for link in "/usr/bin/python" "/usr/bin/python3"; do
        if [ -L "$link" ]; then
            local backup_link="${link}.backup.$(date +%Y%m%d_%H%M%S)"
            cp -P "$link" "$backup_link" 2>/dev/null || true
            debug_log "已备份: $link -> $backup_link"
        fi
    done
    
    # 创建新链接
    log "创建链接: /usr/bin/python -> $real_python_path" "info"
    ln -sf "$real_python_path" "/usr/bin/python"
    
    log "创建链接: /usr/bin/python3 -> $real_python_path" "info"
    ln -sf "$real_python_path" "/usr/bin/python3"
    
    # 验证链接
    if /usr/bin/python --version &>/dev/null && /usr/bin/python3 --version &>/dev/null; then
        log "系统Python链接创建成功" "success"
        return 0
    else
        log "系统Python链接验证失败" "error"
        return 1
    fi
}
install_common_python_packages() {
    local version="$1"
    
    log "安装常用Python包..." "info"
    
    # 常用包列表
    local common_packages=(
        "pip"           # 包管理器
        "setuptools"    # 安装工具
        "wheel"         # 构建工具
        "virtualenv"    # 虚拟环境
        "requests"      # HTTP库
        "urllib3"       # HTTP库依赖
        "certifi"       # SSL证书
    )
    
    # 开发工具包 (可选)
    local dev_packages=(
        "black"         # 代码格式化
        "flake8"        # 代码检查
        "pytest"        # 测试框架
        "ipython"       # 交互式Python
    )
    
    # 升级pip
    log "升级pip..." "info"
    if "$MISE_PATH" exec python -- python -m pip install --upgrade pip --quiet; then
        debug_log "pip升级成功"
    else
        log "pip升级失败" "warn"
    fi
    
    # 安装基础包
    log "安装基础包..." "info"
    for package in "${common_packages[@]}"; do
        if install_python_package "$package"; then
            debug_log "已安装: $package"
        else
            log "安装失败: $package" "warn"
        fi
    done
    
    # 询问是否安装开发工具
    local install_dev_tools=false
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        read -p "是否安装Python开发工具? (包括black, flake8, pytest等) (y/N): " dev_choice
        if [[ "$dev_choice" =~ ^[Yy]$ ]]; then
            install_dev_tools=true
        fi
    elif [ "${INSTALL_DEV_TOOLS:-false}" = "true" ]; then
        install_dev_tools=true
    fi
    
    if [ "$install_dev_tools" = "true" ]; then
        log "安装开发工具包..." "info"
        for package in "${dev_packages[@]}"; do
            if install_python_package "$package"; then
                debug_log "已安装开发工具: $package"
            else
                log "开发工具安装失败: $package" "warn"
            fi
        done
    fi
    
    log "Python包安装完成" "success"
}
install_python_package() {
    local package="$1"
    local max_retries=2
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if "$MISE_PATH" exec python -- python -m pip install "$package" --quiet --disable-pip-version-check; then
            return 0
        fi
        
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            sleep 2
        fi
    done
    
    return 1
}
# --- 额外工具安装 ---
install_additional_tools() {
    log "配置额外开发工具..." "info"
    
    # 询问是否安装Node.js
    local install_nodejs=false
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        read -p "是否安装Node.js? (y/N): " nodejs_choice
        if [[ "$nodejs_choice" =~ ^[Yy]$ ]]; then
            install_nodejs=true
        fi
    elif [ "${INSTALL_NODEJS:-false}" = "true" ]; then
        install_nodejs=true
    fi
    
    if [ "$install_nodejs" = "true" ]; then
        install_nodejs_with_mise
    fi
    
    # 询问是否安装其他工具
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "其他可用工具:" "info"
        log "  • golang - Go语言" "info"
        log "  • rust - Rust语言" "info"
        log "  • java - Java JDK" "info"
        log "  • terraform - 基础设施即代码" "info"
        
        read -p "请输入要安装的工具 (空格分隔，回车跳过): " additional_tools
        if [ -n "$additional_tools" ]; then
            ADDITIONAL_TOOLS=($additional_tools)
        fi
    fi
    
    # 安装额外工具
    for tool in "${ADDITIONAL_TOOLS[@]}"; do
        install_tool_with_mise "$tool"
    done
}
install_nodejs_with_mise() {
    local nodejs_version="${DEFAULT_NODE_VERSION}"
    
    log "安装Node.js..." "info"
    
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        read -p "Node.js版本 (lts/18/20/latest，默认lts): " user_node_version
        if [ -n "$user_node_version" ]; then
            nodejs_version="$user_node_version"
        fi
    fi
    
    log "安装Node.js $nodejs_version..." "info"
    if "$MISE_PATH" use -g "node@$nodejs_version" 2>/dev/null; then
        log "Node.js $nodejs_version 安装成功" "success"
        
        # 验证安装
        local node_version
        node_version=$("$MISE_PATH" exec node -- node --version 2>/dev/null || echo "")
        if [ -n "$node_version" ]; then
            log "Node.js版本: $node_version" "info"
            
            # 安装常用npm包
            log "安装常用npm全局包..." "info"
            local npm_packages=("yarn" "pnpm" "typescript" "nodemon")
            for pkg in "${npm_packages[@]}"; do
                if "$MISE_PATH" exec node -- npm install -g "$pkg" --silent 2>/dev/null; then
                    debug_log "已安装npm包: $pkg"
                fi
            done
        fi
    else
        log "Node.js安装失败" "error"
    fi
}
install_tool_with_mise() {
    local tool="$1"
    
    log "安装 $tool..." "info"
    
    case "$tool" in
        "golang"|"go")
            "$MISE_PATH" use -g "go@latest" 2>/dev/null && log "Go安装成功" "success" || log "Go安装失败" "error"
            ;;
        "rust")
            "$MISE_PATH" use -g "rust@latest" 2>/dev/null && log "Rust安装成功" "success" || log "Rust安装失败" "error"
            ;;
        "java")
            "$MISE_PATH" use -g "java@openjdk-21" 2>/dev/null && log "Java安装成功" "success" || log "Java安装失败" "error"
            ;;
        "terraform")
            "$MISE_PATH" use -g "terraform@latest" 2>/dev/null && log "Terraform安装成功" "success" || log "Terraform安装失败" "error"
            ;;
        *)
            log "尝试安装未知工具: $tool" "warn"
            "$MISE_PATH" use -g "$tool@latest" 2>/dev/null && log "$tool安装成功" "success" || log "$tool安装失败" "error"
            ;;
    esac
}
# --- Shell集成配置优化 ---
configure_shell_integration() {
    log "配置Shell集成..." "info"
    
    # 检测可用的Shell
    local available_shells=()
    local current_shell=$(basename "$SHELL")
    
    # 检查各种Shell
    if [ -f "$HOME/.bashrc" ] || command -v bash &>/dev/null; then
        available_shells+=("bash")
    fi
    
    if [ -f "$HOME/.zshrc" ] || command -v zsh &>/dev/null; then
        available_shells+=("zsh")
    fi
    
    if [ -f "$HOME/.config/fish/config.fish" ] || command -v fish &>/dev/null; then
        available_shells+=("fish")
    fi
    
    log "检测到的Shell: ${available_shells[*]}" "info"
    log "当前Shell: $current_shell" "info"
    
    # 配置各个Shell
    for shell in "${available_shells[@]}"; do
        configure_shell_specific "$shell"
    done
    
    # 配置环境变量
    configure_environment_variables
    
    log "Shell集成配置完成" "success"
}
configure_shell_specific() {
    local shell="$1"
    
    case "$shell" in
        "bash")
            configure_bash_integration
            ;;
        "zsh")
            configure_zsh_integration
            ;;
        "fish")
            configure_fish_integration
            ;;
        *)
            debug_log "未知Shell类型: $shell"
            ;;
    esac
}
configure_bash_integration() {
    log "配置Bash集成..." "info"
    
    local bashrc="$HOME/.bashrc"
    local bash_profile="$HOME/.bash_profile"
    
    # 确保.bashrc存在
    [ ! -f "$bashrc" ] && touch "$bashrc"
    
    # 检查是否已配置
    if grep -q "mise activate bash" "$bashrc" 2>/dev/null; then
        log "Bash已配置mise支持" "info"
    else
        log "添加mise到.bashrc..." "info"
        
        # 添加mise配置
        cat >> "$bashrc" << 'EOF'
# Mise version manager
if [ -f "$HOME/.local/bin/mise" ]; then
    eval "$($HOME/.local/bin/mise activate bash)"
    # 添加mise管理的工具到PATH
    export PATH="$HOME/.local/share/mise/shims:$PATH"
fi
EOF
        log "mise已添加到.bashrc" "success"
    fi
    
    # 配置.bash_profile (如果存在)
    if [ -f "$bash_profile" ] && ! grep -q "source.*bashrc" "$bash_profile"; then
        echo '[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"' >> "$bash_profile"
        debug_log "已配置.bash_profile加载.bashrc"
    fi
}
configure_zsh_integration() {
    log "配置Zsh集成..." "info"
    
    local zshrc="$HOME/.zshrc"
    
    # 确保.zshrc存在
    [ ! -f "$zshrc" ] && touch "$zshrc"
    
    # 检查是否已配置
    if grep -q "mise activate zsh" "$zshrc" 2>/dev/null; then
        log "Zsh已配置mise支持" "info"
    else
        log "添加mise到.zshrc..." "info"
        
        # 查找合适的插入位置 (在oh-my-zsh配置之后)
        if grep -q "source.*oh-my-zsh" "$zshrc"; then
            # 在oh-my-zsh之后插入
            sed -i '/source.*oh-my-zsh/a\\n# Mise version manager\nif [ -f "$HOME/.local/bin/mise" ]; then\n    eval "$($HOME/.local/bin/mise activate zsh)"\n    export PATH="$HOME/.local/share/mise/shims:$PATH"\nfi' "$zshrc"
        else
            # 直接添加到末尾
            cat >> "$zshrc" << 'EOF'
# Mise version manager
if [ -f "$HOME/.local/bin/mise" ]; then
    eval "$($HOME/.local/bin/mise activate zsh)"
    export PATH="$HOME/.local/share/mise/shims:$PATH"
fi
EOF
        fi
        
        log "mise已添加到.zshrc" "success"
    fi
}
configure_fish_integration() {
    log "配置Fish集成..." "info"
    
    local fish_config="$HOME/.config/fish/config.fish"
    
    # 确保目录和文件存在
    mkdir -p "$(dirname "$fish_config")"
    [ ! -f "$fish_config" ] && touch "$fish_config"
    
    # 检查是否已配置
    if grep -q "mise activate fish" "$fish_config" 2>/dev/null; then
        log "Fish已配置mise支持" "info"
    else
        log "添加mise到Fish配置..." "info"
        
        cat >> "$fish_config" << 'EOF'
# Mise version manager
if test -f "$HOME/.local/bin/mise"
    eval "$HOME/.local/bin/mise activate fish"
    set -gx PATH "$HOME/.local/share/mise/shims" $PATH
end
EOF
        log "mise已添加到Fish配置" "success"
    fi
}
configure_environment_variables() {
    log "配置环境变量..." "info"
    
    # 创建mise环境配置文件
    local mise_env_file="$HOME/.mise.env"
    
    cat > "$mise_env_file" << 'EOF'
# Mise环境变量配置
export MISE_CONFIG_DIR="$HOME/.config/mise"
export MISE_DATA_DIR="$HOME/.local/share/mise"
export MISE_CACHE_DIR="$HOME/.cache/mise"
# Python优化
export PYTHONPATH="$HOME/.local/lib/python/site-packages:$PYTHONPATH"
export PIP_USER=1
# Node.js优化 (如果安装了)
export NPM_CONFIG_PREFIX="$HOME/.local"
# 编译优化
export MAKEFLAGS="-j$(nproc)"
EOF
    
    # 添加到shell配置文件
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rcfile" ] && ! grep -q "mise.env" "$rcfile"; then
            echo '[ -f "$HOME/.mise.env" ] && source "$HOME/.mise.env"' >> "$rcfile"
            debug_log "已添加环境变量配置到 $(basename "$rcfile")"
        fi
    done
    
    debug_log "环境变量配置完成"
}
# --- Mise配置文件优化 ---
create_mise_config() {
    log "创建mise配置文件..." "info"
    
    local mise_config="$HOME/.config/mise/config.toml"
    mkdir -p "$(dirname "$mise_config")"
    
    # 创建优化的mise配置
    cat > "$mise_config" << 'EOF'
# Mise配置文件
[settings]
# 启用实验性功能
experimental = true
# 自动安装缺失的工具
auto_install = true
# 并行任务数
jobs = 4
# 禁用匿名遥测
disable_telemetry = true
# 插件更新频率 (天)
plugin_autoupdate_last_check_duration = "7 days"
# 工具缓存策略
cache_prune_age = "30 days"
[aliases]
# Python别名
python = "python3"
pip = "pip3"
# Node.js别名
nodejs = "node"
[env]
# 全局环境变量
EDITOR = "nano"
PAGER = "less"
[tools]
# 工具版本约束
python = ">=3.8"
EOF
    
    log "mise配置文件已创建: $mise_config" "success"
    
    # 创建全局工具版本文件
    create_global_tool_versions
}
create_global_tool_versions() {
    local tool_versions="$HOME/.tool-versions"
    
    log "创建全局工具版本文件..." "info"
    
    # 获取已安装的工具版本
    local installed_tools=()
    
    # 检查Python
    if "$MISE_PATH" which python &>/dev/null; then
        local python_version
        python_version=$("$MISE_PATH" current python 2>/dev/null | awk '{print $2}' || echo "")
        if [ -n "$python_version" ]; then
            installed_tools+=("python $python_version")
        fi
    fi
    
    # 检查Node.js
    if "$MISE_PATH" which node &>/dev/null; then
        local node_version
        node_version=$("$MISE_PATH" current node 2>/dev/null | awk '{print $2}' || echo "")
        if [ -n "$node_version" ]; then
            installed_tools+=("node $node_version")
        fi
    fi
    
    # 写入.tool-versions
    if [ ${#installed_tools[@]} -gt 0 ]; then
        printf '%s\n' "${installed_tools[@]}" > "$tool_versions"
        log "全局工具版本已设置:" "info"
        for tool in "${installed_tools[@]}"; do
            log "  • $tool" "info"
        done
    fi
}
# --- 系统集成和验证 ---
verify_mise_installation() {
    log "验证mise安装..." "info"
    
    local verification_passed=true
    
    # 检查mise可执行文件
    if [ ! -f "$MISE_PATH" ] || [ ! -x "$MISE_PATH" ]; then
        log "mise可执行文件不存在或不可执行" "error"
        verification_passed=false
    else
        local mise_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $1}' || echo "未知")
        log "mise版本: $mise_version" "info"
    fi
    
    # 检查mise命令功能
    if ! "$MISE_PATH" list &>/dev/null; then
        log "mise命令执行失败" "error"
        verification_passed=false
    else
        debug_log "mise命令功能正常"
    fi
    
    # 检查Python安装
    if "$MISE_PATH" which python &>/dev/null; then
        local python_version
        python_version=$("$MISE_PATH" exec python -- python --version 2>&1 | awk '{print $2}' || echo "未知")
        log "Python版本: $python_version" "info"
    else
        log "Python未通过mise安装" "warn"
    fi
    
    # 检查Shell集成
    local shell_integration_ok=false
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rcfile" ] && grep -q "mise activate" "$rcfile"; then
            shell_integration_ok=true
            debug_log "Shell集成检查通过: $(basename "$rcfile")"
            break
        fi
    done
    
    if [ "$shell_integration_ok" = false ]; then
        log "Shell集成配置可能有问题" "warn"
    fi
    
    if [ "$verification_passed" = true ]; then
        log "mise安装验证通过" "success"
        return 0
    else
        log "mise安装验证失败" "error"
        return 1
    fi
}
# --- 生成mise状态报告 ---
generate_mise_report() {
    log "生成mise状态报告..." "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    log "🔧 Mise 版本管理器状态报告" "success"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    # 基本信息
    if [ -f "$MISE_PATH" ] && [ -x "$MISE_PATH" ]; then
        local mise_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $1}' || echo "未知")
        log "📋 基本信息:" "info"
        log "  • Mise版本: $mise_version" "info"
        log "  • 安装路径: $MISE_PATH" "info"
        log "  • 配置目录: $MISE_CONFIG_DIR" "info"
        
        # 已安装工具
        log "🛠️  已安装工具:" "info"
        local tools_list
        tools_list=$("$MISE_PATH" list 2>/dev/null || echo "")
        
        if [ -n "$tools_list" ]; then
            echo "$tools_list" | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    log "  • $line" "info"
                fi
            done
        else
            log "  • (无已安装工具)" "warn"
        fi
        
        # 当前活动版本
        log "⚡ 当前活动版本:" "info"
        local current_versions
        current_versions=$("$MISE_PATH" current 2>/dev/null || echo "")
        
        if [ -n "$current_versions" ]; then
            echo "$current_versions" | while IFS= read -r line; do
                if [ -n "$line" ]; then
                    log "  • $line" "info"
                fi
            done
        else
            log "  • (无活动工具)" "warn"
        fi
        
        # Python特殊检查
        if "$MISE_PATH" which python &>/dev/null; then
            local python_path
            python_path=$("$MISE_PATH" which python 2>/dev/null)
            local python_version
            python_version=$("$MISE_PATH" exec python -- python --version 2>&1 | awk '{print $2}' || echo "未知")
            
            log "🐍 Python信息:" "info"
            log "  • 版本: $python_version" "info"
            log "  • 路径: $python_path" "info"
            
            # 检查pip包
            local pip_packages
            pip_packages=$("$MISE_PATH" exec python -- python -m pip list --format=freeze 2>/dev/null | wc -l || echo "0")
            log "  • 已安装包数: $pip_packages" "info"
        fi
        
        # Shell集成状态
        log "🐚 Shell集成状态:" "info"
        local integrated_shells=()
        
        if [ -f "$HOME/.bashrc" ] && grep -q "mise activate bash" "$HOME/.bashrc"; then
            integrated_shells+=("bash")
        fi
        
        if [ -f "$HOME/.zshrc" ] && grep -q "mise activate zsh" "$HOME/.zshrc"; then
            integrated_shells+=("zsh")
        fi
        
        if [ -f "$HOME/.config/fish/config.fish" ] && grep -q "mise activate fish" "$HOME/.config/fish/config.fish"; then
            integrated_shells+=("fish")
        fi
        
        if [ ${#integrated_shells[@]} -gt 0 ]; then
            log "  • 已集成: ${integrated_shells[*]}" "success"
        else
            log "  • 未检测到Shell集成" "warn"
        fi
        
    else
        log "❌ Mise 未正确安装" "error"
    fi
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
}
# --- 主函数 ---
main() {
    log "开始配置Mise版本管理器..." "info"
    
    # 1. 系统要求检查
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 2. 备份现有配置
    backup_existing_config
    
    # 3. 检测现有安装
    detect_existing_installation
    
    # 4. 安装Python编译依赖
    install_python_build_deps
    
    # 5. 安装Mise
    if ! install_mise_safely; then
        log "Mise安装失败" "error"
        exit 1
    fi
    
    # 6. 配置Python环境
    if ! configure_python_environment; then
        log "Python环境配置失败，但继续执行" "warn"
    fi
    
    # 7. 安装额外工具
    install_additional_tools
    
    # 8. 配置Shell集成
    configure_shell_integration
    
    # 9. 创建mise配置
    create_mise_config
    
    # 10. 验证安装
    if ! verify_mise_installation; then
        log "安装验证失败" "warn"
    fi
    
    # 11. 生成状态报告
    generate_mise_report
    
    log "🎉 Mise版本管理器配置完成!" "success"
    
    # 使用提示
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "💡 使用提示:" "info"
        log "  • 重新加载Shell: source ~/.bashrc 或 exec \$SHELL" "info"
        log "  • 查看已安装工具: mise list" "info"
        log "  • 安装新工具: mise use -g <tool>@<version>" "info"
        log "  • 查看当前版本: mise current" "info"
        log "  • 获取帮助: mise help" "info"
        
        if "$MISE_PATH" which python &>/dev/null; then
            log "  • Python可用: python --version" "info"
            log "  • 安装包: python -m pip install <package>" "info"
        fi
    fi
    
    exit 0
}
# 执行主函数
main "$@"
