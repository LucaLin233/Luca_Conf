#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署与优化脚本 (集成Zsh + Mise版本)
# 版本: 1.9.0 (集成Zsh Shell环境 + Mise版本管理器)
# 适用系统: Debian 12
# 功能概述: 包含 Zsh+Oh-My-Zsh, Mise版本管理器, Docker, Zram, 网络优化, SSH 加固, 自动更新等功能。
# 脚本特性: 幂等可重复执行，确保 Cron 定时任务唯一性。
#
# 作者: LucaLin233
# 贡献者/优化: Linux AI Buddy
# -----------------------------------------------------------------------------

# --- 脚本版本 ---
SCRIPT_VERSION="1.9.0"

# --- 文件路径 ---
STATUS_FILE="/var/lib/system-deploy-status.json" # 存储部署状态的文件
CONTAINER_DIRS=(/root /root/proxy /root/vmagent) # 包含 docker-compose 文件的目录
MISE_PATH="$HOME/.local/bin/mise" # Mise安装路径

# --- 日志函数 ---
# log <消息> [级别] - 打印带颜色日志
log() {
    local color="\033[0;32m"
    case "$2" in
        "warn")  color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info")  color="\033[0;36m" ;;
        "title") color="\033[1;35m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# step_start <编号> <描述> - 步骤开始
step_start() { log "▶ 步骤 $1: $2..." "title"; }
# step_end <编号> <描述> - 步骤完成
step_end() { log "✓ 步骤 $1 完成: $2" "info"; echo; }
# step_fail <编号> <描述> - 步骤失败并退出
step_fail() { log "✗ 步骤 $1 失败: $2" "error"; exit 1; }

# check_and_start_service <服务> - 检查并启动 Systemd 服务 (非致命)
check_and_start_service() {
    local service_name="$1"
    # 检查服务文件是否存在
    if ! systemctl list-unit-files --type=service | grep -q "^${service_name}\s"; then
        log "$service_name 服务文件不存在，跳过检查和启动." "info"
        return 0
    fi

    log "检查并确保服务运行: $service_name" "info"
    if systemctl is-active "$service_name" &>/dev/null; then
        log "$service_name 服务已运行." "info"
        return 0
    fi

    if systemctl is-enabled "$service_name" &>/dev/null; then
        log "$service_name 服务未运行，但已启用。尝试启动..." "warn"
        systemctl start "$service_name" && log "$service_name 启动成功." "info" && return 0 || log "$service_name 启动失败." "error" && return 1
    else
        log "$service_name 服务未启用。尝试启用并启动..." "warn"
        systemctl enable --now "$service_name" && log "$service_name 已启用并启动成功." "info" && return 0 || log "$service_name 启用并启动失败." "error" && return 1
    fi
}

# run_cmd <命令> [参数...] - 执行命令并检查退出状态 (非致命 except step 步骤 1 tools)
run_cmd() {
    "$@"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        # 特殊处理 apt upgrade 的退出码 100 (部分升级失败)
        if [ "$1" = "apt" ] && ([ "$2" = "upgrade" ] || [ "$2" = "full-upgrade" ]) && [ "$exit_status" -eq 100 ]; then
             log "命令 '$*' 返回退出码 100，继续执行." "warn"
             return 0
        fi
        # 对于其他非 sysctl 命令失败，记录错误但不中断
        if [ "$1" != "sysctl" ]; then
            log "执行命令失败: '$*'. 退出状态: $exit_status" "error"
            return 1
        fi
    fi
    return 0
}

# --- 脚本初始化 ---
RERUN_MODE=false
if [ -f "$STATUS_FILE" ]; then
    RERUN_MODE=true
    log "检测到之前的部署记录 ($STATUS_FILE)。以更新/重运行模式执行." "info"
fi

if [ "$(id -u)" != "0" ]; then
    log "此脚本必须以 root 用户身份运行." "error"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    log "此脚本仅适用于 Debian 系统." "error"
    exit 1
fi

debian_version=$(cut -d. -f1 < /etc/debian_version)
if [ "$debian_version" -lt 12 ]; then
    log "警告: 此脚本为 Debian 12 优化。当前版本 $(cat /etc/debian_version)." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi

# --- 步骤 1: 网络与基础工具检查 ---
step_start 1 "网络与基础工具检查"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络不稳定，可能影响安装." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi
# 确保必要工具可用 (包括zsh需要的git)
for cmd in curl wget apt git; do
    if ! command -v $cmd &>/dev/null; then
        log "安装必要工具: $cmd" "warn"
        apt-get update -qq && apt-get install -y -qq $cmd || step_fail 1 "安装基础工具 $cmd 失败."
    fi
done
step_end 1 "网络与基础工具可用"

# --- 步骤 2: 系统更新与核心软件包安装 ---
step_start 2 "执行系统更新并安装核心软件包"
run_cmd apt update
if $RERUN_MODE; then
    log "更新模式: 执行软件包升级." "info"
    run_cmd apt upgrade -y
else
    log "首次运行: 执行完整的系统升级." "info"
    run_cmd apt full-upgrade -y
fi
PKGS_TO_INSTALL=()
# 核心软件包列表 (包含zsh需要的工具)
for pkg in dnsutils wget curl rsync chrony cron tuned zsh git; do
    if ! dpkg -s "$pkg" &>/dev/null; then
         PKGS_TO_INSTALL+=($pkg)
    fi
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的核心软件包: ${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}"
    if [ $? -ne 0 ]; then
         step_fail 2 "核心软件包安装失败."
    fi
else
    log "所有核心软件包已安装!" "info"
fi
HNAME=$(hostname)
# 确保主机名正确映射到 127.0.1.1
if grep -q "^127.0.1.1" /etc/hosts; then
    if ! grep "^127.0.1.1" /etc/hosts | grep -wq "$HNAME"; then
        cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d)
        sed -i "/^127.0.1.1/ s/\$/ $HNAME/" /etc/hosts
        log "已将主机名 $HNAME 添加到 127.0.1.1 行." "warn"
    fi
else
    echo "127.0.1.1 $HNAME" >> /etc/hosts
    log "已将 127.0.1.1 和主机名 $HNAME 追加到 /etc/hosts." "warn"
fi
step_end 2 "系统更新与核心软件包就绪"

# --- 步骤 3: 配置并启用 Zram Swap ---
step_start 3 "配置并启用 Zram Swap"
ZRAM_SWAP_STATUS="未配置"
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "未检测到 zram-tools。正在安装..." "warn"
    if run_cmd apt update; then
        if run_cmd apt install -y zram-tools; then
            log "zram-tools 安装成功." "info"
            check_and_start_service zramswap.service || log "警告: zramswap.service 检查失败，请手动验证." "warn"
            ZRAM_SWAP_STATUS="已启用且活跃"
        else
            log "错误: zram-tools 安装失败." "error"
            ZRAM_SWAP_STATUS="安装失败"
        fi
    else
        log "apt update 失败，跳过 zram-tools 安装." "error"
        ZRAM_SWAP_STATUS="apt update 失败，安装跳过"
    fi
else
    log "zram-tools 已安装." "info"
    if swapon --show | grep -q "/dev/zram"; then
        log "Zram Swap 已活跃." "info"
        ZRAM_SWAP_STATUS="已启用且活跃 ($(swapon --show | grep "/dev/zram" | awk '{print $3 "/" $4}'))"
    else
        log "zram-tools 已安装，但 Zram Swap 不活跃。尝试启动服务..." "warn"
        check_and_start_service zramswap.service || log "警告: zramswap.service 启动失败。Zram Swap 可能不活跃." "warn"
        ZRAM_SWAP_STATUS="已安装但服务不活跃/失败"
    fi
fi
log "注意: 此脚本不自动处理旧 Swap 文件/分区，请手动管理." "info"
step_end 3 "Zram Swap 配置完成"

# --- 步骤 4: 安装和配置 Zsh Shell 环境 ---
step_start 4 "安装和配置 Zsh Shell 环境"
ZSH_INSTALL_STATUS="未安装或检查失败"

# 检查 Zsh 是否已安装
if command -v zsh &>/dev/null; then
    ZSH_VERSION=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
    log "Zsh 已安装 (版本: $ZSH_VERSION)." "info"
    ZSH_INSTALL_STATUS="已安装"
    
    if $RERUN_MODE; then
        read -p "是否重新配置 Zsh 环境? (y/n): " reconfig_zsh
        RECONFIG_ZSH=$reconfig_zsh
    else
        RECONFIG_ZSH="y"
    fi
else
    log "未检测到 Zsh。正在安装..." "warn"
    if run_cmd apt install -y zsh; then
        log "Zsh 安装成功." "info"
        ZSH_INSTALL_STATUS="已安装"
        RECONFIG_ZSH="y"
    else
        log "错误: Zsh 安装失败." "error"
        ZSH_INSTALL_STATUS="安装失败"
        RECONFIG_ZSH="n"
    fi
fi

# 配置 Zsh 环境 (如果安装成功或需要重新配置)
if [ "$RECONFIG_ZSH" = "y" ] && command -v zsh &>/dev/null; then
    # 4.1: 安装 Oh My Zsh
    log "安装 Oh My Zsh 框架..." "info"
    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "Oh My Zsh 已存在." "info"
        
        if $RERUN_MODE; then
            read -p "是否重新安装 Oh My Zsh? (y/n): " reinstall_omz
            if [ "$reinstall_omz" = "y" ]; then
                log "备份并重新安装 Oh My Zsh..." "warn"
                mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            else
                log "跳过 Oh My Zsh 重新安装." "info"
            fi
        fi
    fi
    
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        # 使用非交互模式安装 Oh My Zsh
        log "下载并安装 Oh My Zsh..." "warn"
        if run_cmd bash -c 'RUNZSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'; then
            log "Oh My Zsh 安装成功." "info"
        else
            log "警告: Oh My Zsh 安装失败，将使用基础 Zsh 配置." "warn"
        fi
    fi
    
    # 4.2: 安装 Powerlevel10k 主题
    log "安装 Powerlevel10k 主题..." "info"
    THEME_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [ -d "$THEME_DIR" ]; then
        log "Powerlevel10k 主题已存在." "info"
        
        if $RERUN_MODE; then
            read -p "是否更新 Powerlevel10k 主题? (y/n): " update_p10k
            if [ "$update_p10k" = "y" ]; then
                log "更新 Powerlevel10k 主题..." "warn"
                if cd "$THEME_DIR" && run_cmd git pull; then
                    log "Powerlevel10k 主题更新成功." "info"
                else
                    log "警告: Powerlevel10k 主题更新失败." "warn"
                fi
                cd - >/dev/null
            fi
        fi
    else
        log "下载 Powerlevel10k 主题..." "warn"
        if run_cmd git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR"; then
            log "Powerlevel10k 主题安装成功." "info"
        else
            log "警告: Powerlevel10k 主题安装失败." "warn"
        fi
    fi
    
    # 4.3: 安装推荐插件
    log "安装推荐 Zsh 插件..." "info"
    CUSTOM_PLUGINS="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$CUSTOM_PLUGINS"
    
    # 安装 zsh-autosuggestions
    if [ ! -d "$CUSTOM_PLUGINS/zsh-autosuggestions" ]; then
        log "安装 zsh-autosuggestions 插件..." "info"
        if run_cmd git clone https://github.com/zsh-users/zsh-autosuggestions "$CUSTOM_PLUGINS/zsh-autosuggestions"; then
            log "zsh-autosuggestions 插件安装成功." "info"
        else
            log "警告: zsh-autosuggestions 插件安装失败." "warn"
        fi
    fi
    
    # 安装 zsh-syntax-highlighting
    if [ ! -d "$CUSTOM_PLUGINS/zsh-syntax-highlighting" ]; then
        log "安装 zsh-syntax-highlighting 插件..." "info"
        if run_cmd git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$CUSTOM_PLUGINS/zsh-syntax-highlighting"; then
            log "zsh-syntax-highlighting 插件安装成功." "info"
        else
            log "警告: zsh-syntax-highlighting 插件安装失败." "warn"
        fi
    fi
    
    # 安装 zsh-completions
    if [ ! -d "$CUSTOM_PLUGINS/zsh-completions" ]; then
        log "安装 zsh-completions 插件..." "info"
        if run_cmd git clone https://github.com/zsh-users/zsh-completions "$CUSTOM_PLUGINS/zsh-completions"; then
            log "zsh-completions 插件安装成功." "info"
        else
            log "警告: zsh-completions 插件安装失败." "warn"
        fi
    fi
    
    # 4.4: 配置 .zshrc
    log "配置 .zshrc 文件..." "info"
    
    # 备份现有配置
    if [ -f "$HOME/.zshrc" ]; then
        if [ ! -f "$HOME/.zshrc.bak.orig" ]; then
            cp "$HOME/.zshrc" "$HOME/.zshrc.bak.orig"
            log "已备份原始 .zshrc 配置." "info"
        fi
        cp "$HOME/.zshrc" "$HOME/.zshrc.bak.$(date +%Y%m%d%H%M%S)"
        log "已备份当前 .zshrc 配置." "info"
    fi
    
    # 创建新的 .zshrc 配置
    cat > "$HOME/.zshrc" << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"

# 设置主题为 Powerlevel10k
ZSH_THEME="powerlevel10k/powerlevel10k"

# 插件配置
plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    sudo
    docker
    kubectl
    web-search
    history
    colored-man-pages
    command-not-found
)

# 加载 Oh My Zsh
source $ZSH/oh-my-zsh.sh

# 启用补全
autoload -U compinit && compinit

# 添加 ~/.local/bin 到 PATH
export PATH="$HOME/.local/bin:$PATH"

# mise 版本管理器配置 (如果存在)
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

# Powerlevel10k 配置 (如果存在配置文件)
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 一些有用的别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Docker 相关别名
alias dps='docker ps'
alias dpa='docker ps -a'
alias di='docker images'
alias dsp='docker system prune'

# 系统相关别名
alias ..='cd ..'
alias ...='cd ../..'
alias h='history'
alias c='clear'
alias df='df -h'
alias du='du -h'
alias free='free -h'
EOF
    
    log ".zshrc 配置文件创建成功." "info"
    
    # 4.5: 询问是否设置为默认 Shell
    CURRENT_SHELL=$(getent passwd root | cut -d: -f7)
    ZSH_PATH=$(which zsh)
    
    if [ "$CURRENT_SHELL" = "$ZSH_PATH" ]; then
        log "Zsh 已经是 root 用户的默认 Shell." "info"
    else
        log "当前默认 Shell: $CURRENT_SHELL" "info"
        log "Zsh 路径: $ZSH_PATH" "info"
        
        read -p "是否将 Zsh 设置为 root 用户的默认 Shell? (y/n): " set_default_shell
        if [ "$set_default_shell" = "y" ]; then
            log "设置 Zsh 为默认 Shell..." "warn"
            if chsh -s "$ZSH_PATH" root; then
                log "Zsh 已设置为默认 Shell（需要重新登录生效）." "info"
                ZSH_INSTALL_STATUS="已安装并设为默认Shell"
            else
                log "警告: 设置默认 Shell 失败." "warn"
                ZSH_INSTALL_STATUS="已安装但未设为默认"
            fi
        else
            log "保持当前默认 Shell." "info"
            ZSH_INSTALL_STATUS="已安装但未设为默认"
        fi
    fi
    
    # 4.6: 提供 Powerlevel10k 配置提示
    log "Powerlevel10k 配置提示:" "info"
    log "重新登录后可运行 'p10k configure' 来配置提示符主题." "info"
    log "或者直接启动 zsh: 'zsh' 来体验新环境." "info"
    
else
    log "跳过 Zsh 环境配置." "warn"
fi

step_end 4 "Zsh Shell 环境配置完成 (状态: $ZSH_INSTALL_STATUS)"

# --- 步骤 5: 安装和配置 Mise 版本管理器 ---
step_start 5 "安装和配置 Mise 版本管理器"
MISE_INSTALL_STATUS="未安装或检查失败"

# 确保 .local/bin 目录存在
mkdir -p "$HOME/.local/bin"

if [ -f "$MISE_PATH" ]; then
    log "Mise 已安装，检查版本..." "info"
    MISE_VERSION_OUTPUT=$($MISE_PATH --version 2>/dev/null || echo "无法获取版本")
    log "当前 Mise 版本: $MISE_VERSION_OUTPUT" "info"
    MISE_INSTALL_STATUS="已安装"
    
    if $RERUN_MODE; then
        read -p "是否更新 Mise 到最新版本? (y/n): " update_mise
        if [ "$update_mise" = "y" ]; then
            log "更新 Mise..." "warn"
            if run_cmd curl https://mise.run | sh; then
                log "Mise 更新成功." "info"
                MISE_INSTALL_STATUS="已更新"
            else
                log "警告: Mise 更新失败，继续使用当前版本." "warn"
            fi
        fi
    fi
else
    log "未检测到 Mise。正在安装..." "warn"
    if run_cmd bash -c "$(curl -fsSL https://mise.run)"; then
        log "Mise 安装成功." "info"
        MISE_INSTALL_STATUS="已安装"
    else
        log "错误: Mise 安装失败." "error"
        MISE_INSTALL_STATUS="安装失败"
    fi
fi

# 配置 Python 3.10 (如果 Mise 安装成功)
if [ -f "$MISE_PATH" ]; then
    log "配置 Python 3.10 通过 Mise..." "info"
    
    # 检查是否已有 Python 配置
    if $MISE_PATH list python 2>/dev/null | grep -q "3.10"; then
        log "Python 3.10 已通过 Mise 配置." "info"
        
        if $RERUN_MODE; then
            read -p "是否重新安装/更新 Python 3.10? (y/n): " update_python
            if [ "$update_python" = "y" ]; then
                log "重新安装 Python 3.10..." "warn"
                if $MISE_PATH use -g python@3.10; then
                    log "Python 3.10 重新配置成功." "info"
                else
                    log "警告: Python 3.10 重新配置失败." "warn"
                fi
            fi
        fi
    else
        log "安装 Python 3.10..." "warn"
        if $MISE_PATH use -g python@3.10; then
            log "Python 3.10 安装配置成功." "info"
        else
            log "警告: Python 3.10 安装失败." "warn"
        fi
    fi
    
    # 配置 Mise 到 .bashrc (为了兼容性)
    BASHRC_FILE="$HOME/.bashrc"
    MISE_ACTIVATE_LINE='eval "$($HOME/.local/bin/mise activate bash)"'
    
    if [ ! -f "$BASHRC_FILE" ]; then
        log "创建 .bashrc 文件..." "warn"
        touch "$BASHRC_FILE"
    fi
    
    if ! grep -q "mise activate bash" "$BASHRC_FILE"; then
        log "添加 Mise 自动激活到 .bashrc..." "info"
        echo "" >> "$BASHRC_FILE"
        echo "# Mise version manager" >> "$BASHRC_FILE"
        echo "$MISE_ACTIVATE_LINE" >> "$BASHRC_FILE"
        log "Mise 自动激活已添加到 .bashrc." "info"
    else
        log "Mise 自动激活已存在于 .bashrc." "info"
    fi
    
    # 配置 Mise 到 .zshrc (如果 zsh 已安装配置)
    if command -v zsh &>/dev/null && [ -f "$HOME/.zshrc" ]; then
        if grep -q "mise activate zsh" "$HOME/.zshrc"; then
            log "Mise 已配置到 .zshrc." "info"
        else
            log "确保 Mise 配置到 .zshrc..." "info"
            # .zshrc 已经包含了 mise 配置，无需额外添加
        fi
    fi
else
    log "Mise 未正确安装，跳过 Python 配置." "warn"
fi

step_end 5 "Mise 版本管理器配置完成 (状态: $MISE_INSTALL_STATUS)"

# --- 步骤 6: 安装 Docker 和 NextTrace ---
step_start 6 "安装 Docker 和 NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
# 使用 get.docker.com 脚本安装 Docker
if ! command -v docker &>/dev/null; then
    log "未检测到 Docker。使用 get.docker.com 安装..." "warn"
    if run_cmd bash -c "$(run_cmd curl -fsSL https://get.docker.com)"; then
        log "Docker 安装成功." "info"
        check_and_start_service docker.service || log "警告: 启用/启动 Docker 服务失败." "warn"
    else
        log "错误: Docker 安装失败." "error"
    fi
else
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)
    log "Docker 已安装 (版本: ${docker_version:-未知})." "info"
    check_and_start_service docker.service || log "Docker 服务检查/启动失败." "error"
fi
# 低内存环境优化 Docker 日志
if [ "$MEM_TOTAL" -lt 1024 ]; then
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        log "低内存环境. 优化 Docker 日志配置..." "warn"
        mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
        log "重启 Docker 应用日志优化..." "warn"
        systemctl restart docker || log "警告: 重启 Docker 服务失败." "warn"
    else
        log "Docker 日志优化配置已存在." "info"
    fi
fi
# 安装 NextTrace
if command -v nexttrace &>/dev/null; then
    log "NextTrace 已安装." "info"
else
    log "未检测到 NextTrace。正在部署..." "warn"
    if run_cmd bash -c "$(run_cmd curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"; then
        log "NextTrace 安装成功." "info"
    else
        log "警告: NextTrace 安装失败." "error"
    fi
fi
step_end 6 "Docker 和 NextTrace 部署完成"

# --- 步骤 7: 检查并启动 Docker Compose 容器 ---
step_start 7 "检查并启动 Docker Compose 定义的容器"
SUCCESSFUL_RUNNING_CONTAINERS=0
FAILED_DIRS=""
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi

if [ -z "$COMPOSE_CMD" ]; then
    log "未检测到 Docker Compose。跳过容器启动." "warn"
else
    log "使用 Docker Compose 命令: '$COMPOSE_CMD'" "info"
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            log "目录 '$dir' 不存在。跳过." "warn"
            continue
        fi
        COMPOSE_FILE=""
        for file in compose.yaml docker-compose.yml; do
            if [ -f "$dir/$file" ]; then
                COMPOSE_FILE="$file"
                break
            fi
        done
        if [ -n "$COMPOSE_FILE" ]; then
            log "进入目录 '$dir' 检查 Compose 文件 '$COMPOSE_FILE'." "info"
            if cd "$dir"; then
                EXPECTED_SERVICES=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services 2>/dev/null | wc -l)
                if [ "$EXPECTED_SERVICES" -eq 0 ]; then
                    log "目录 '$dir': Compose 文件 '$COMPOSE_FILE' 未定义服务。跳过." "warn"
                    cd - >/dev/null
                    continue
                fi
                CURRENT_RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                if [ "$CURRENT_RUNNING_COUNT" -ge "$EXPECTED_SERVICES" ]; then
                     log "目录 '$dir': 已检测到至少 $EXPECTED_SERVICES 个容器运行中。跳过启动." "info"
                     SUCCESSFUL_RUNNING_CONTAINERS=$((SUCCESSFUL_RUNNING_CONTAINERS + CURRENT_RUNNING_COUNT))
                else
                    log "目录 '$dir': $CURRENT_RUNNING_COUNT 个容器运行中 (预期至少 $EXPECTED_SERVICES)。尝试启动/重创..." "warn"
                    if $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate; then
                        sleep 5
                        NEW_RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                        log "目录 '$dir' 启动/重创尝试成功. $NEW_RUNNING_COUNT 个容器正在运行." "info"
                        SUCCESSFUL_RUNNING_CONTAINERS=$((SUCCESSFUL_RUNNING_CONTAINERS + NEW_RUNNING_COUNT))
                    else
                        log "错误: Compose 启动失败目录: '$dir'." "error"
                        FAILED_DIRS+=" $dir"
                    fi
                fi
                cd - >/dev/null
            else
                log "错误: 无法进入目录 '$dir'。跳过." "error"
                FAILED_DIRS+=" $dir"
            fi
        else
            log "目录 '$dir': 未找到 Compose 文件。跳过." "warn"
        fi
    done
    ACTUAL_TOTAL_RUNNING=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    log "容器检查汇总: 系统上实际运行容器总数: $ACTUAL_TOTAL_RUNNING." "info"
    if [ -n "$FAILED_DIRS" ]; then
        log "警告: 以下目录的 Compose 启动可能失败: $FAILED_DIRS" "error"
    fi
fi
step_end 7 "Docker Compose 容器检查完成"

# --- 步骤 8: 系统服务与性能优化 ---
step_start 8 "系统服务与性能优化 (时区, Tuned, Timesync)"
# 确保 tuned 已启用并启动 (非致命)
if systemctl list-unit-files --type=service | grep -q tuned.service; then
    check_and_start_service tuned.service || log "警告: tuned 服务启动失败." "warn"
else
    log "未检测到 tuned 服务. 跳过调优配置." "warn"
fi
# 设置系统时区为亚洲/上海 (非致命)
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        log "设置时区为亚洲/上海..." "warn"
        timedatectl set-timezone Asia/Shanghai && log "时区成功设置为亚洲/上海." "info" || log "timedatectl 设置时区失败." "error"
    else
        log "时区已是亚洲/上海." "info"
    fi
else
    log "未检测到 timedatectl 命令。跳过时区设置." "warn"
fi
# 确保 systemd-timesyncd 已启动 (如果存在) (非致命)
check_and_start_service systemd-timesyncd.service || log "systemd-timesyncd 服务检查失败或不存在." "info"

step_end 8 "系统服务与性能优化完成"

# --- 步骤 9: 配置 TCP 性能 (BBR) 和 Qdisc (fq_codel) ---
step_start 9 "配置 TCP 性能 (BBR) 和 Qdisc (fq_codel)"
QDISC_TYPE="fq_codel"
read -p "启用 BBR + $QDISC_TYPE 网络拥塞控制? (Y/n): " bbr_choice
bbr_choice="${bbr_choice:-y}"

if [[ ! "$bbr_choice" =~ ^[nN]$ ]]; then
    log "用户选择启用 BBR + $QDISC_TYPE." "info"
    SKIP_SYSCTL_CONFIG=false
    # 检查并加载 tcp_bbr 模块
    if ! /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1 || ! run_cmd /sbin/modprobe tcp_bbr; then
        log "警告: 未找到或无法加载 'tcp_bbr' 模块." "warn"
        if [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m); then
             log "'tcp_bbr' 模块已编译或可用." "info"
        else
             log "严重警告: 内核可能不支持 BBR. 无法启用." "error"
             SKIP_SYSCTL_CONFIG=true
        fi
    fi

    if [ "$SKIP_SYSCTL_CONFIG" != true ]; then
        [ ! -f /etc/sysctl.conf.bak.orig ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.orig && log "已备份 /etc/sysctl.conf." "info"
        log "配置 sysctl 参数 for BBR and $QDISC_TYPE..." "info"

        # 幂等删除旧配置并行，使用 '|' 分隔符，然后追加
        sed -i '\| *#\? *net\.ipv4\.tcp_congestion_control=|d' /etc/sysctl.conf && log "已移除旧的 tcp_congestion_control 行." "info" || true
        echo "net.ipv4.tcp_congestion_control=bbr" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.ipv4.tcp_congestion_control=bbr." "info" || log "追加 tcp_congestion_control 失败." "error"

        sed -i '\| *#\? *net\.core\.default_qdisc=|d' /etc/sysctl.conf && log "已移除旧的 default_qdisc 行." "info" || true
        echo "net.core.default_qdisc=fq_codel" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.core.default_qdisc=fq_codel." "info" || log "追加 default_qdisc 失败." "error"

        log "应用 sysctl 配置..." "warn"
        run_cmd sysctl -p || log "警告: 'sysctl -p' 失败. 检查配置语法." "warn"

        # 验证当前设置
        CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败/未设置")
        CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败/未设置")
        log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
        if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
            log "BBR 和 $QDISC_TYPE 参数已生效." "info"
        else
            log "警告: 网络参数验证可能不匹配." "warn"
        fi
    else
        log "因 BBR 模块问题，跳过 sysctl 配置." "warn"
    fi
else
    log "跳过 BBR + $QDISC_TYPE 配置." "warn"
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败/未设置")
    CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败/未设置")
    log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
fi
step_end 9 "网络性能参数配置完成"

# --- 步骤 10: 管理 SSH 安全端口 ---
step_start 10 "管理 SSH 服务端口"
[ ! -f /etc/ssh/sshd_config.bak.orig ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.orig && log "已备份 /etc/ssh/sshd_config." "info"
# 查找当前 SSH 端口
CURRENT_SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT="22" && log "未找到 Port 配置，假定默认 22." "info" || log "当前配置 SSH 端口为 $CURRENT_SSH_PORT." "info"

# 提示用户修改端口
if $RERUN_MODE; then
    read -p "当前 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input
else
    read -p "当前 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input
fi

NEW_SSH_PORT_SET="$CURRENT_SSH_PORT"
CHANGE_PORT_REQUESTED=false

if [ -n "$new_port_input" ]; then
    CHANGE_PORT_REQUESTED=true
    if ! [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
        log "输入无效，端口未更改." "error"
    elif [ "$new_port_input" -lt 1024 ] || [ "$new_port_input" -gt 65535 ]; then
        log "端口号无效，端口未更改." "error"
    elif ss -tuln | grep -q ":$new_port_input\b"; then
        log "警告: 端口 $new_port_input 已被占用. 端口未更改." "warn"
    else
        log "正在更改 SSH 端口为 $new_port_input..." "warn"
        # 移除旧的 Port 行并添加新行
        sed -i '\| *#\? *Port |d' /etc/ssh/sshd_config && log "已移除旧的 Port 行." "info" || true
        echo "Port $new_port_input" >> /etc/ssh/sshd_config && log "已添加 Port $new_port_input 到 sshd_config." "info" || log "添加 Port 行失败." "error"

        log "重启 SSH 服务应用新端口..." "warn"
        if systemctl restart sshd; then
            log "SSH 服务重启成功. 新端口 $new_port_input 已生效." "info"
            NEW_SSH_PORT_SET="$new_port_input"
        else
            log "错误: SSH 服务重启失败! 新端口可能未生效." "error"
            NEW_SSH_PORT_SET="Failed to restart/$new_port_input"
        fi
    fi
fi
step_end 10 "SSH 端口管理完成"

# --- 步骤 11: 部署自动更新脚本和 Cron 任务 ---
step_start 11 "部署自动更新脚本和 Crontab 任务"
UPDATE_SCRIPT="/root/auto-update.sh"
# 写入自动更新脚本内容
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
# -----------------------------------------------------------------------------
# 自动化系统更新与内核重启脚本 (修复版 v1.6 - 日志覆盖 + pseudo-TTY)
# 更新软件包，检查新内核，必要时重启。每次运行时覆盖旧日志。
# 使用 apt-get dist-upgrade. 通过 `script` 命令模拟 TTY 环境运行 apt-get.
# -----------------------------------------------------------------------------

# --- 配置 ---
LOGFILE="/var/log/auto-update.log"
# 为 apt-get dist-upgrade 准备选项
APT_GET_OPTIONS="-y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" -o APT::ListChanges::Frontend=none"
# script 命令需要一个文件来记录输出
SCRIPT_OUTPUT_DUMMY="/tmp/auto_update_script_cmd_output.log"

# --- 自动更新脚本内部日志函数 ---
log_update() {
    # 注意：确保日志函数使用追加模式 '>>'
    echo "[$(date '+%Y-%m-%d %H:%M:%S (%Z)')] $1" >>"$LOGFILE"
}

# --- 主逻辑 ---

# --- 关键修改：覆盖旧日志 ---
# 在记录第一条日志前，清空日志文件
> "$LOGFILE"

log_update "启动自动化系统更新 (修复版 v1.6 - 日志覆盖 + pseudo-TTY)."

log_update "运行 /usr/bin/apt-get update..."
/usr/bin/apt-get update -o APT::ListChanges::Frontend=none >>"$LOGFILE" 2>&1
UPDATE_EXIT_STATUS=$?
if [ $UPDATE_EXIT_STATUS -ne 0 ]; then
    log_update "警告: /usr/bin/apt-get update 失败， exits $UPDATE_EXIT_STATUS."
fi

# 运行前清理旧的 script 输出文件
/bin/rm -f "$SCRIPT_OUTPUT_DUMMY"

log_update "运行 /usr/bin/apt-get dist-upgrade (尝试通过 'script' 命令模拟 TTY)..."
COMMAND_TO_RUN="DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get dist-upgrade $APT_GET_OPTIONS"
/usr/bin/script -q -c "$COMMAND_TO_RUN" "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE" 2>&1
UPGRADE_EXIT_STATUS=$?

if [ -f "$SCRIPT_OUTPUT_DUMMY" ]; then
    log_update "--- Output captured by 'script' command (from $SCRIPT_OUTPUT_DUMMY) ---"
    /bin/cat "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE"
    log_update "--- End of 'script' command output ---"
else
    log_update "警告: 未找到 'script' 命令的输出文件 $SCRIPT_OUTPUT_DUMMY"
fi

if [ $UPGRADE_EXIT_STATUS -eq 0 ]; then
    log_update "apt-get dist-upgrade (via script) 命令执行完成 (script 命令退出码 0)."

    RUNNING_KERNEL="$(/bin/uname -r)"
    log_update "当前运行内核: $RUNNING_KERNEL"

    LATEST_INSTALLED_KERNEL_PKG=$(/usr/bin/dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image-[0-9]*' 2>/dev/null | /usr/bin/sort -k2 -V | /usr/bin/tail -n1 | /usr/bin/awk '{print $1}' || true)

    if [ -z "$LATEST_INSTALLED_KERNEL_PKG" ]; then
        log_update "未找到已安装的特定版本内核包。无法比较。"
        INSTALLED_KERNEL_VERSION=""
    else
        log_update "检测到的最新安装内核包: $LATEST_INSTALLED_KERNEL_PKG"
        INSTALLED_KERNEL_VERSION="$(echo "$LATEST_INSTALLED_KERNEL_PKG" | /bin/sed 's/^linux-image-//')"
        log_update "提取到的最新内核版本: $INSTALLED_KERNEL_VERSION"
    fi

    if [ -n "$INSTALLED_KERNEL_VERSION" ] && [ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL_VERSION" ]; then
        log_update "检测到新内核版本 ($INSTALLED_KERNEL_VERSION) 与运行内核 ($RUNNING_KERNEL) 不同。"

        if ! /bin/systemctl is-active sshd >/dev/null 2>&1; then
             log_update "SSHD 服务未运行，尝试启动..."
             /bin/systemctl restart sshd >>"$LOGFILE" 2>&1 || log_update "警告: SSHD 启动失败! 重启可能导致无法连接。"
        fi

        log_update "因新内核需要重启系统..."
        log_update "执行 /sbin/reboot ..."
        /sbin/reboot >>"$LOGFILE" 2>&1
        /bin/sleep 15
        log_update "警告: 重启命令已发出，但脚本仍在运行？"

    else
        log_update "内核已是最新 ($RUNNING_KERNEL) 或无法确定新内核，无需重启。"
    fi

else
    log_update "错误: apt-get dist-upgrade (via script) 未成功完成 (script 命令退出码: $UPGRADE_EXIT_STATUS). 跳过内核检查和重启。"
    log_update "请检查上面由 'script' 命令捕获的具体输出，以了解内部错误。"
fi

log_update "自动更新脚本执行完毕."
exit 0
EOF

chmod +x "$UPDATE_SCRIPT" && log "自动更新脚本已创建并可执行." "info" || log "设置脚本可执行失败." "error"

CRON_CMD="5 0 * * 0 $UPDATE_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "auto-update.log"; echo "$CRON_CMD") | sort -u | crontab -
log "Crontab 已配置每周日 00:05 执行，并确保唯一性." "info"

step_end 11 "自动更新脚本与 Crontab 任务部署完成"

# --- 步骤 12: 系统部署信息摘要 ---
step_start 12 "系统部署信息摘要"
log "\n╔═════════════════════════════════════════╗" "title"
log "║           系统部署完成摘要                ║" "title"
log "╚═════════════════════════════════════════╝" "title"

show_info() { log " • $1: $2" "info"; }

show_info "部署模式" "$(if $RERUN_MODE; then echo "重运行 / 更新"; else echo "首次部署"; fi)"
show_info "脚本版本" "$SCRIPT_VERSION"

OS_PRETTY_NAME="未知 Debian 版本"
[ -f /etc/os-release ] && OS_PRETTY_NAME=$(grep 'PRETTY_NAME' /etc/os-release |cut -d= -f2 | tr -d '"' || echo '未知 Debian 版本')
show_info "操作系统" "$OS_PRETTY_NAME"

show_info "当前运行内核" "$(uname -r)"
show_info "CPU 核心数" "$(nproc)"

MEM_USAGE=$(free -h | grep Mem | awk '{print $2}' || echo '未知')
show_info "总内存大小" "$MEM_USAGE"

DISK_USAGE_ROOT="未知"
df -h / >/dev/null 2>&1 && DISK_USAGE_ROOT=$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" "$5" ")"}')
show_info "磁盘使用 (/)" "$DISK_USAGE_ROOT"

show_info "Zram Swap 状态" "$ZRAM_SWAP_STATUS"

# Zsh Shell 状态
show_info "Zsh Shell 状态" "$ZSH_INSTALL_STATUS"
if command -v zsh &>/dev/null; then
    ZSH_PATH_SUMMARY=$(which zsh)
    show_info "Zsh Shell 路径" "$ZSH_PATH_SUMMARY"
    show_info "Zsh Shell 版本" "$(zsh --version 2>/dev/null | awk '{print $2}' || echo '未知')"
    
    # 检查是否为默认shell
    ROOT_SHELL=$(getent passwd root | cut -d: -f7)
    if [ "$ROOT_SHELL" = "$ZSH_PATH_SUMMARY" ]; then
        show_info "默认 Shell 状态" "Zsh (已设为默认)"
    else
        show_info "默认 Shell 状态" "Bash (Zsh 未设为默认)"
    fi
    
    # 检查 Oh My Zsh
    if [ -d "$HOME/.oh-my-zsh" ]; then
        show_info "Oh My Zsh" "已安装"
    else
        show_info "Oh My Zsh" "未安装"
    fi
    
    # 检查 Powerlevel10k
    if [ -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
        show_info "Powerlevel10k 主题" "已安装"
    else
        show_info "Powerlevel10k 主题" "未安装"
    fi
fi

# Mise 和 Python 状态
show_info "Mise 版本管理器" "$MISE_INSTALL_STATUS"
if [ -f "$MISE_PATH" ]; then
    show_info "Mise 路径" "$MISE_PATH"
    
    # 检查 Python 配置
    if $MISE_PATH list python 2>/dev/null | grep -q "3.10"; then
        PYTHON_VERSION=$($MISE_PATH which python 2>/dev/null && $($MISE_PATH which python) --version 2>/dev/null || echo "已配置但版本获取失败")
        show_info "Python (Mise)" "$PYTHON_VERSION"
    else
        show_info "Python (Mise)" "未配置"
    fi
fi

# SSH 端口状态
DISPLAY_SSH_PORT_SUMMARY="$NEW_SSH_PORT_SET"
SSH_PORT_WARNING=""
if echo "$NEW_SSH_PORT_SET" | grep -q "Failed to restart"; then
    DISPLAY_SSH_PORT_SUMMARY=$(echo "$NEW_SSH_PORT_SET" | sed 's/Failed to restart\///')
    SSH_PORT_WARNING=" (警告: SSH 服务重启失败)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ] && [ "$CHANGE_PORT_REQUESTED" = true ]; then
    SSH_PORT_WARNING=" (尝试更改失败/端口被占用)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ]; then
     SSH_PORT_WARNING=" (未更改)"
else
     SSH_PORT_WARNING=" (已成功更改)"
fi
show_info "SSH 端口" "$DISPLAY_SSH_PORT_SUMMARY$SSH_PORT_WARNING"

# Docker 状态
DOCKER_VER_SUMMARY="未安装"
ACTIVE_CONTAINERS_COUNT="N/A"
command -v docker >/dev/null 2>&1 && DOCKER_VER_SUMMARY=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未知版本') && ACTIVE_CONTAINERS_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo '检查失败') || true
show_info "Docker 版本" "$DOCKER_VER_SUMMARY"
show_info "活跃 Docker 容器数" "$ACTIVE_CONTAINERS_COUNT"

# NextTrace 状态
NEXTTRACE_FULL_OUTPUT=$(nexttrace -V 2>&1 || true)
NEXTTRACE_VER_LINE=$(echo "$NEXTTRACE_FULL_OUTPUT" | grep -v '\[API\]' | head -n 1)
NEXTTRACE_VER_SUMMARY="未安装"
if [ -n "$NEXTTRACE_VER_LINE" ]; then
    NEXTTRACE_VER_SUMMARY=$(echo "$NEXTTRACE_VER_LINE" | awk '{print $2}' | tr -d ',' || echo "提取失败")
fi
[ -z "$NEXTTRACE_VER_SUMMARY" ] && NEXTTRACE_VER_SUMMARY="未安装"
show_info "NextTrace 版本" "$NEXTTRACE_VER_SUMMARY"

# 网络优化参数
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败")
show_info "网络参数 (sysctl)" "CC=$CURR_CC, Qdisc=$CURR_QDISC"

BBR_MODULE_STATUS="未知"
if /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1; then
    BBR_MODULE_STATUS="模块可用/已加载"
elif [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m); then
     BBR_MODULE_STATUS="编译进内核/可用模块"
else
     BBR_MODULE_STATUS="模块不存在"
fi
show_info "BBR 内核模块状态" "$BBR_MODULE_STATUS"

# 时区设置
TIMEZONE_SUMMARY="未知"
command -v timedatectl >/dev/null 2>&1 && TIMEZONE_SUMMARY=$(timedatectl | grep "Time zone" | awk '{print $3}')
show_info "系统时区设置" "$TIMEZONE_SUMMARY"

# Shell 信息
show_info "当前脚本 Shell" "$SHELL"
ROOT_LOGIN_SHELL=$(getent passwd root | cut -d: -f7 || echo "获取失败")
show_info "Root 用户默认登录 Shell" "$ROOT_LOGIN_SHELL"

# Tuned Profile
TUNED_PROFILE_SUMMARY=$(tuned-adm active 2>/dev/null | grep 'Current active profile:' | awk -F': ' '{print $NF}')
[ -z "$TUNED_PROFILE_SUMMARY" ] && TUNED_PROFILE_SUMMARY="(未检测到活跃 Profile)"
show_info "活跃 Tuned Profile" "$TUNED_PROFILE_SUMMARY"

# Compose 容器状态
if [ "$SUCCESSFUL_RUNNING_CONTAINERS" -gt 0 ]; then
    show_info "Compose 容器状态" "在配置目录共检测到 $SUCCESSFUL_RUNNING_CONTAINERS 个容器运行中."
else
    log " • Compose 容器状态: 未检测到运行中的 Compose 容器." "info"
fi
[ -n "$FAILED_DIRS" ] && log " • 警告: Compose 启动失败目录: $FAILED_DIRS" "error"

log "\n──────────────────────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "info"
log "──────────────────────────────────────────────────\n" "title"

step_end 12 "摘要报告已生成"

# --- 保存部署状态 ---
printf '{
  "script_version": "%s",
  "last_run": "%s",
  "ssh_port": "%s",
  "system": "%s",
  "zram_status": "%s",
  "zsh_status": "%s",
  "mise_status": "%s",
  "network_optimization": {
    "tcp_congestion_control": "%s",
    "default_qdisc": "%s"
  },
  "container_status": {
    "successful_running": %d,
    "failed_dirs": "%s"
  }
}\n' \
"$SCRIPT_VERSION" \
"$(date '+%Y-%m-%d %H:%M:%S')" \
"$NEW_SSH_PORT_SET" \
"$OS_PRETTY_NAME" \
"$ZRAM_SWAP_STATUS" \
"$ZSH_INSTALL_STATUS" \
"$MISE_INSTALL_STATUS" \
"$CURR_CC" \
"$CURR_QDISC" \
"$SUCCESSFUL_RUNNING_CONTAINERS" \
"$FAILED_DIRS" \
> "$STATUS_FILE"

# 验证状态文件创建
if [ -f "$STATUS_FILE" ]; then
    log "部署状态已保存至文件: $STATUS_FILE" "info"
else
    log "警告: 无法创建状态文件 $STATUS_FILE." "error"
fi

# --- 最终提示 ---
log "✅ 脚本执行完毕." "title"

if [ "$CHANGE_PORT_REQUESTED" = true ] && [ "$NEW_SSH_PORT_SET" = "$new_port_input" ] && [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
    log "⚠️  重要提示: 请使用新 SSH 端口 $NEW_SSH_PORT_SET 连接." "warn"
    log "   示例: ssh -p $NEW_SSH_PORT_SET 您的用户名@您的服务器IP地址" "warn"
fi

if $RERUN_MODE; then
    log "➡️  重运行模式: 已按需更新配置和服务." "info"
else
    log "🎉 初始部署完成!" "info"
fi

# Zsh 使用提示
if command -v zsh &>/dev/null; then
    log "🐚 Zsh Shell 使用提示:" "info"
    log "   立即体验 Zsh: exec zsh" "info"
    log "   配置 Powerlevel10k 主题: p10k configure" "info"
    if [ "$(getent passwd root | cut -d: -f7)" != "$(which zsh)" ]; then
        log "   如需设为默认: chsh -s $(which zsh) root" "info"
    fi
fi

# Mise 使用提示
if [ -f "$MISE_PATH" ]; then
    log "🔧 Mise 使用提示:" "info"
    log "   要激活 Mise 环境: source ~/.bashrc 或 exec zsh" "info"
    log "   查看已安装工具: $MISE_PATH list" "info"
    log "   使用 Python: $MISE_PATH which python && $($MISE_PATH which python) --version" "info"
fi

log "🔄 可随时再次运行此脚本进行维护或更新." "info"
log "手动检查建议: 请验证旧 Swap 文件/配置是否已正确移除." "warn"
