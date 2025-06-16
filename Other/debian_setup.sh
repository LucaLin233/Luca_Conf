#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署脚本 (模块化版本 v2.0.0)
# 适用系统: Debian 12+
# 功能: 模块化部署 Zsh, Mise, Docker, 网络优化, SSH 加固等
# 作者: LucaLin233
# -----------------------------------------------------------------------------

SCRIPT_VERSION="2.0.0"
STATUS_FILE="/var/lib/system-deploy-status.json"
MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/modules"
TEMP_DIR="/tmp/debian_setup_modules"

# --- 基础函数 ---
log() {
    local colors=("\033[0;32m" "\033[0;33m" "\033[0;31m" "\033[0;36m" "\033[1;35m")
    local levels=("" "warn" "error" "info" "title")
    local color="\033[0;32m"
    for i in "${!levels[@]}"; do
        [[ "$2" == "${levels[$i]}" ]] && color="${colors[$i]}" && break
    done
    echo -e "${color}$1\033[0m"
}

step_start() { log "▶ 步骤 $1: $2..." "title"; }
step_end() { log "✓ 步骤 $1 完成: $2" "info"; echo; }
step_fail() { log "✗ 步骤 $1 失败: $2" "error"; exit 1; }

# --- 模块管理函数 ---
download_module() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    
    log "下载模块: $module_name" "info"
    if curl -fsSL "$MODULE_BASE_URL/${module_name}.sh" -o "$module_file"; then
        chmod +x "$module_file"
        log "模块 $module_name 下载成功" "info"
        return 0
    else
        log "模块 $module_name 下载失败" "error"
        return 1
    fi
}

execute_module() {
    local module_name="$1"
    local module_file="$TEMP_DIR/${module_name}.sh"
    
    if [ ! -f "$module_file" ]; then
        log "模块文件不存在: $module_file" "error"
        return 1
    fi
    
    log "执行模块: $module_name" "title"
    if bash "$module_file"; then
        log "模块 $module_name 执行成功" "info"
        return 0
    else
        log "模块 $module_name 执行失败" "error"
        return 1
    fi
}

ask_user_module() {
    local module_name="$1"
    local description="$2"
    local default="$3"
    
    read -p "是否执行 $description 模块? (Y/n): " choice
    choice="${choice:-$default}"
    [[ "$choice" =~ ^[Yy]$ ]] && return 0 || return 1
}

# --- 初始化检查 ---
RERUN_MODE=false
if [ -f "$STATUS_FILE" ]; then
    RERUN_MODE=true
    log "检测到之前的部署记录，以更新模式执行" "info"
fi

if [ "$(id -u)" != "0" ]; then
    log "此脚本必须以 root 用户身份运行" "error"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    log "此脚本仅适用于 Debian 系统" "error"
    exit 1
fi

debian_version=$(cut -d. -f1 < /etc/debian_version)
if [ "$debian_version" -lt 12 ]; then
    log "警告: 此脚本为 Debian 12+ 优化。当前版本 $(cat /etc/debian_version)" "warn"
    read -p "确定继续? (y/n): " continue_install
    [[ "$continue_install" != "y" ]] && exit 1
fi

# --- 步骤 1: 基础环境检查 ---
step_start 1 "基础环境检查和准备"

# 网络检查
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络连接不稳定" "warn"
    read -p "继续执行? (y/n): " continue_install
    [[ "$continue_install" != "y" ]] && exit 1
fi

# 安装基础工具
for cmd in curl wget apt git; do
    if ! command -v $cmd &>/dev/null; then
        log "安装基础工具: $cmd" "warn"
        apt-get update -qq && apt-get install -y -qq $cmd || step_fail 1 "安装基础工具失败"
    fi
done

# 创建临时目录
mkdir -p "$TEMP_DIR"

step_end 1 "基础环境就绪"

# --- 步骤 2: 系统更新 ---
step_start 2 "系统更新"

apt update
if $RERUN_MODE; then
    log "更新模式: 执行软件包升级" "info"
    apt upgrade -y
else
    log "首次运行: 执行完整系统升级" "info" 
    apt full-upgrade -y
fi

# 安装核心软件包
CORE_PACKAGES=(dnsutils wget curl rsync chrony cron tuned)
MISSING_PACKAGES=()

for pkg in "${CORE_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "安装核心软件包: ${MISSING_PACKAGES[*]}" "info"
    apt install -y "${MISSING_PACKAGES[@]}" || step_fail 2 "核心软件包安装失败"
fi

# 修复 hosts 文件
HOSTNAME=$(hostname)
if ! grep -q "^127.0.1.1.*$HOSTNAME" /etc/hosts; then
    log "修复 hosts 文件" "info"
    sed -i "/^127.0.1.1/d" /etc/hosts
    echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

step_end 2 "系统更新完成"

# --- 步骤 3: 模块化部署 ---
step_start 3 "模块化功能部署"

# 定义可用模块
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 服务管理)"
    ["zsh-setup"]="Zsh Shell 环境 (Oh-My-Zsh + 主题插件)"
    ["mise-setup"]="Mise 版本管理器 (Python 环境)"
    ["docker-setup"]="Docker 容器化平台"
    ["network-optimize"]="网络性能优化 (BBR + fq_codel)"
    ["ssh-security"]="SSH 安全配置"
    ["auto-update-setup"]="自动更新系统"
)

# 模块执行顺序
MODULE_ORDER=("system-optimize" "zsh-setup" "mise-setup" "docker-setup" "network-optimize" "ssh-security" "auto-update-setup")

EXECUTED_MODULES=()
FAILED_MODULES=()

for module in "${MODULE_ORDER[@]}"; do
    description="${MODULES[$module]}"
    
    if ask_user_module "$module" "$description" "y"; then
        log "\n开始处理模块: $module" "title"
        
        if download_module "$module"; then
            if execute_module "$module"; then
                EXECUTED_MODULES+=("$module")
                log "模块 $module 完成\n" "info"
            else
                FAILED_MODULES+=("$module")
                log "模块 $module 失败，继续执行其他模块\n" "warn"
            fi
        else
            FAILED_MODULES+=("$module")
            log "模块 $module 下载失败，跳过\n" "error"
        fi
    else
        log "跳过模块: $module\n" "info"
    fi
done

step_end 3 "模块化部署完成"

# --- 步骤 4: 部署摘要 ---
step_start 4 "生成部署摘要"

log "\n╔═════════════════════════════════════════╗" "title"
log "║           系统部署完成摘要                ║" "title"
log "╚═════════════════════════════════════════╝" "title"

show_info() { log " • $1: $2" "info"; }

show_info "脚本版本" "$SCRIPT_VERSION"
show_info "部署模式" "$(if $RERUN_MODE; then echo "更新模式"; else echo "首次部署"; fi)"
show_info "操作系统" "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')"
show_info "内核版本" "$(uname -r)"
show_info "CPU 核心" "$(nproc)"
show_info "总内存" "$(free -h | grep Mem | awk '{print $2}')"

# 已执行模块
if [ ${#EXECUTED_MODULES[@]} -gt 0 ]; then
    log "\n✅ 成功执行的模块:" "info"
    for module in "${EXECUTED_MODULES[@]}"; do
        log "   • $module: ${MODULES[$module]}" "info"
    done
fi

# 失败模块
if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    log "\n❌ 执行失败的模块:" "error"
    for module in "${FAILED_MODULES[@]}"; do
        log "   • $module: ${MODULES[$module]}" "error"
    done
fi

# 系统状态检查
log "\n📊 当前系统状态:" "info"

# Zsh 状态
if command -v zsh &>/dev/null; then
    ZSH_VERSION=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
    show_info "Zsh Shell" "已安装 (版本: $ZSH_VERSION)"
    
    ROOT_SHELL=$(getent passwd root | cut -d: -f7)
    if [ "$ROOT_SHELL" = "$(which zsh)" ]; then
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
    CONTAINERS_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo "0")
    show_info "Docker" "已安装 (版本: $DOCKER_VERSION, 运行容器: $CONTAINERS_COUNT)"
else
    show_info "Docker" "未安装"
fi

# Mise 状态
if [ -f "$HOME/.local/bin/mise" ]; then
    MISE_VERSION=$($HOME/.local/bin/mise --version 2>/dev/null || echo "未知")
    show_info "Mise" "已安装 ($MISE_VERSION)"
else
    show_info "Mise" "未安装"
fi

# 网络优化状态
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
show_info "网络优化" "拥塞控制: $CURR_CC, 队列调度: $CURR_QDISC"

# SSH 端口
SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
show_info "SSH 端口" "$SSH_PORT"

log "\n──────────────────────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "info"
log "──────────────────────────────────────────────────\n" "title"

step_end 4 "摘要生成完成"

# --- 保存部署状态 ---
cat > "$STATUS_FILE" << EOF
{
  "script_version": "$SCRIPT_VERSION",
  "last_run": "$(date '+%Y-%m-%d %H:%M:%S')",
  "executed_modules": [$(printf '"%s",' "${EXECUTED_MODULES[@]}" | sed 's/,$//')]$([ ${#EXECUTED_MODULES[@]} -eq 0 ] && echo '[]' || echo ''),
  "failed_modules": [$(printf '"%s",' "${FAILED_MODULES[@]}" | sed 's/,$//')]$([ ${#FAILED_MODULES[@]} -eq 0 ] && echo '[]' || echo ''),
  "system_info": {
    "os": "$(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')",
    "kernel": "$(uname -r)",
    "ssh_port": "$SSH_PORT"
  }
}
EOF

# --- 清理和最终提示 ---
rm -rf "$TEMP_DIR"

log "✅ 所有部署任务完成!" "title"

# 特殊提示
if [[ " ${EXECUTED_MODULES[@]} " =~ " ssh-security " ]]; then
    NEW_SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ "$NEW_SSH_PORT" != "22" ] && [ -n "$NEW_SSH_PORT" ]; then
        log "⚠️  重要: SSH 端口已更改为 $NEW_SSH_PORT" "warn"
        log "   请使用新端口连接: ssh -p $NEW_SSH_PORT user@server" "warn"
    fi
fi

if [[ " ${EXECUTED_MODULES[@]} " =~ " zsh-setup " ]]; then
    log "🐚 Zsh 使用提示:" "info"
    log "   体验 Zsh: exec zsh" "info"
    log "   配置主题: p10k configure" "info"
fi

log "🔄 可随时重新运行此脚本进行更新或维护" "info"
log "📄 部署状态已保存到: $STATUS_FILE" "info"

exit 0
