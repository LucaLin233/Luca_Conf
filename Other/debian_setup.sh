#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署与优化脚本 (Zsh版本)
# 版本: 2.0.1 (移除Fish/Starship，集成Zsh + Oh My Zsh + Powerlevel10k + mise + Docker IPv6)
# 适用系统: Debian 12
# 功能概述: 包含 Zsh Shell, Docker (IPv6), Zram, 网络优化, SSH 加固, 自动更新等功能。
# 脚本特性: 幂等可重复执行，确保 Cron 定时任务唯一性。
#
# 作者: LucaLin233
# 贡献者/优化: Linux AI Buddy (Zram 配置优化 - 使用 PERCENT)
# -----------------------------------------------------------------------------

# --- 脚本版本 ---
SCRIPT_VERSION="2.0.1" # Zsh集成版本 + Docker IPv6支持

# --- 文件路径 ---
STATUS_FILE="/var/lib/system-deploy-status.json" # 存储部署状态的文件
CONTAINER_DIRS=(/root /root/proxy /root/vmagent) # 包含 docker-compose 文件的目录

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

# run_cmd <命令> [参数...] - 执行命令并检查退出状态
run_cmd() {
    "$@"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        if [ "$1" = "apt" ] && ([ "$2" = "upgrade" ] || [ "$2" = "full-upgrade" ]) && [ "$exit_status" -eq 100 ]; then
             log "命令 '$*' 返回退出码 100，继续执行." "warn"
             return 0
        fi
        # 对于非致命命令，记录警告；对于其他命令，记录错误并可能返回失败
        case "$1" in
            sysctl|/bin/cp|/bin/rm|sed|tee|chmod|chsh|mkdir) # 扩展非致命命令列表
                log "执行命令警告 (非致命): '$*'. 退出状态: $exit_status" "warn"
                return 0 # 即使这些命令失败，也允许脚本继续
                ;;
            *)
                log "执行命令失败: '$*'. 退出状态: $exit_status" "error"
                return 1
                ;;
        esac
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

# MEM_TOTAL 在需要时获取，避免过早获取导致后续free命令不准确（如果脚本运行时间较长）
MEM_TOTAL="" # 初始化

# --- 步骤 1: 网络与基础工具检查 ---
step_start 1 "网络与基础工具检查"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络不稳定，可能影响安装." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi
for cmd in curl wget apt gpg; do
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
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    if ! dpkg -s "$pkg" &>/dev/null; then
         PKGS_TO_INSTALL+=($pkg)
    fi
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的核心软件包: ${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}" || step_fail 2 "核心软件包安装失败."
else
    log "所有核心软件包已安装!" "info"
fi
HNAME=$(hostname)
if grep -q "^127.0.1.1" /etc/hosts; then
    if ! grep "^127.0.1.1" /etc/hosts | grep -wq "$HNAME"; then
        run_cmd cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S) # 更精确的备份文件名
        run_cmd sed -i "/^127.0.1.1/ s/\$/ $HNAME/" /etc/hosts
        log "已将主机名 $HNAME 添加到 127.0.1.1 行." "warn"
    fi
else
    echo "127.0.1.1 $HNAME" | run_cmd tee -a /etc/hosts > /dev/null
    log "已将 127.0.1.1 和主机名 $HNAME 追加到 /etc/hosts." "warn"
fi
step_end 2 "系统更新与核心软件包就绪"

# --- 步骤 3: 配置并启用 Zram Swap (使用 zstd 压缩，物理内存一半通过 PERCENT) ---
step_start 3 "配置并启用 Zram Swap (使用 zstd 压缩，物理内存一半通过 PERCENT)"
ZRAM_SWAP_STATUS="未配置/检查失败"
ZRAM_CONFIG_FILE="/etc/default/zramswap"

# 1. 安装 zram-tools (如果尚未安装)
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "未检测到 zram-tools。正在安装..." "warn"
    if run_cmd apt update; then
        if run_cmd apt install -y zram-tools; then
            log "zram-tools 安装成功." "info"
            ZRAM_SWAP_STATUS="已安装，待配置"
        else
            log "错误: zram-tools 安装失败." "error"
            ZRAM_SWAP_STATUS="安装失败"
            step_fail 3 "安装 zram-tools 失败."
        fi
    else
        log "apt update 失败，无法安装 zram-tools." "error"
        ZRAM_SWAP_STATUS="apt更新失败，安装跳过"
        step_fail 3 "安装 zram-tools 前 apt update 失败."
    fi
else
    log "zram-tools 已安装." "info"
    ZRAM_SWAP_STATUS="已安装，检查配置"
fi

# 只有当 zram-tools 成功安装后，才进行配置和启动
if echo "$ZRAM_SWAP_STATUS" | grep -q "已安装"; then
    log "配置 $ZRAM_CONFIG_FILE (ALGO=zstd, PERCENT=50)..." "warn"

    # 备份原始配置文件 (如果存在且与默认不同或未备份过)
    ZRAM_BACKUP_FILE="$ZRAM_CONFIG_FILE.bak.orig.$SCRIPT_VERSION"
    if [ -f "$ZRAM_CONFIG_FILE" ] && [ ! -f "$ZRAM_BACKUP_FILE" ]; then
        # 简单的检查，避免覆盖重要用户配置，实际可更复杂
        if grep -q "ALGO=zstd" "$ZRAM_CONFIG_FILE" && grep -q "PERCENT=50" "$ZRAM_CONFIG_FILE"; then
            log "$ZRAM_CONFIG_FILE 已包含期望配置，跳过备份和覆盖." "info"
        else
            run_cmd cp "$ZRAM_CONFIG_FILE" "$ZRAM_BACKUP_FILE"
            log "已备份原始配置到 $ZRAM_BACKUP_FILE" "info"
        fi
    fi

    # 创建新的配置文件
    cat > "$ZRAM_CONFIG_FILE" << 'EOF'
# Zram configuration
ALGO=zstd
PERCENT=50
PRIORITY=10
EOF

    log "Zram 配置文件已更新: ALGO=zstd, PERCENT=50" "info"

    # 重启 zramswap 服务以应用新配置
    if systemctl is-active zramswap &>/dev/null; then
        log "重启 zramswap 服务以应用新配置..." "warn"
        run_cmd systemctl restart zramswap
    else
        log "启动 zramswap 服务..." "warn"
        run_cmd systemctl enable --now zramswap
    fi

    # 验证 zram 状态
    if systemctl is-active zramswap &>/dev/null; then
        ZRAM_SWAP_STATUS="配置成功并运行"
        log "Zram Swap 配置成功并运行." "info"
        # 显示 zram 信息
        if command -v zramctl &>/dev/null; then
            log "当前 Zram 状态:" "info"
            zramctl
        fi
    else
        ZRAM_SWAP_STATUS="配置完成但服务未运行"
        log "Zram 配置完成但服务未能正常启动." "warn"
    fi
else
    log "Zram-tools 未正确安装，跳过配置." "warn"
fi

step_end 3 "Zram Swap 配置完成"

# --- 步骤 4: 安装和配置 Zsh + Oh My Zsh + Powerlevel10k ---
step_start 4 "安装和配置 Zsh Shell 环境"

# 4.1: 安装 Zsh 和必要工具
ZSH_PKGS_TO_INSTALL=()
for pkg in zsh git curl wget; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        ZSH_PKGS_TO_INSTALL+=($pkg)
    fi
done

if [ ${#ZSH_PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装 Zsh 相关软件包: ${ZSH_PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${ZSH_PKGS_TO_INSTALL[@]}" || step_fail 4 "Zsh 相关软件包安装失败."
else
    log "Zsh 相关软件包已安装!" "info"
fi

log "Zsh 版本: $(zsh --version)" "info"

# 4.2: 为 root 用户安装 Oh My Zsh
if [ -d "/root/.oh-my-zsh" ]; then
    log "Oh My Zsh 已存在，跳过安装" "warn"
else
    log "为 root 用户安装 Oh My Zsh..." "info"
    export RUNZSH=no
    export CHSH=no
    if su - root -c 'curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh' || \
       su - root -c 'wget -O- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh'; then
        log "Oh My Zsh 安装成功" "info"
    else
        log "Oh My Zsh 安装失败，但继续执行" "warn"
    fi
fi

# 4.3: 安装 Powerlevel10k 主题
THEME_DIR="/root/.oh-my-zsh/custom/themes/powerlevel10k"
if [ -d "$THEME_DIR" ]; then
    log "Powerlevel10k 主题已存在，跳过安装" "warn"
else
    log "安装 Powerlevel10k 主题..." "info"
    if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR"; then
        log "Powerlevel10k 主题安装成功" "info"
    else
        log "Powerlevel10k 主题安装失败，但继续执行" "warn"
    fi
fi

# 4.4: 安装推荐插件
log "安装推荐的 Zsh 插件..." "info"
CUSTOM_PLUGINS="/root/.oh-my-zsh/custom/plugins"

# zsh-autosuggestions
if [ ! -d "$CUSTOM_PLUGINS/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "$CUSTOM_PLUGINS/zsh-autosuggestions" || log "zsh-autosuggestions 安装失败" "warn"
else
    log "zsh-autosuggestions 已存在" "info"
fi

# zsh-syntax-highlighting
if [ ! -d "$CUSTOM_PLUGINS/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$CUSTOM_PLUGINS/zsh-syntax-highlighting" || log "zsh-syntax-highlighting 安装失败" "warn"
else
    log "zsh-syntax-highlighting 已存在" "info"
fi

# zsh-completions
if [ ! -d "$CUSTOM_PLUGINS/zsh-completions" ]; then
    git clone https://github.com/zsh-users/zsh-completions "$CUSTOM_PLUGINS/zsh-completions" || log "zsh-completions 安装失败" "warn"
else
    log "zsh-completions 已存在" "info"
fi

# 4.5: 配置 .zshrc
log "配置 .zshrc..." "info"
if [ -f "/root/.zshrc" ]; then
    cp "/root/.zshrc" "/root/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
    log "已备份现有 .zshrc" "info"
fi

cat > /root/.zshrc << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"

# 主题设置
ZSH_THEME="powerlevel10k/powerlevel10k"

# 插件配置
plugins=(
    git
    sudo
    command-not-found
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
)

# 加载 Oh My Zsh
source $ZSH/oh-my-zsh.sh

# 自定义配置
export EDITOR='nano'
export LANG=en_US.UTF-8

# 历史配置
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS

# 实用别名
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias autodel='docker system prune -a -f && apt autoremove -y'
alias copyall='cd /root/copy && ansible-playbook -i inventory.ini copyhk.yml && ansible-playbook -i inventory.ini copysg.yml && ansible-playbook -i inventory.ini copyother.yml'

# 如果存在 mise，则初始化
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

EOF

# 4.6: 设置 root 用户默认 shell 为 zsh
log "设置 root 用户默认 shell 为 zsh..." "info"
if [ "$SHELL" != "$(which zsh)" ]; then
    run_cmd chsh -s "$(which zsh)" root || log "更改默认 shell 失败，但继续执行" "warn"
    log "默认 shell 已设置为 zsh (重新登录后生效)" "info"
else
    log "默认 shell 已经是 zsh" "info"
fi

step_end 4 "Zsh Shell 环境配置完成"

# --- 步骤 5: 安装和配置 mise ---
step_start 5 "安装和配置 mise 工具"

# 检查 mise 是否已安装
if command -v mise >/dev/null 2>&1; then
    log "mise 已安装: $(mise --version)" "info"
    MISE_INSTALLED=true
else
    log "安装 mise..." "info"
    MISE_INSTALLED=false
    
    # 使用官方安装脚本安装 mise
    if curl https://mise.run | sh; then
        log "mise 安装成功" "info"
        # 将 mise 添加到当前会话的 PATH
        export PATH="$HOME/.local/bin:$PATH"
        MISE_INSTALLED=true
    else
        log "mise 安装失败，尝试备用方法..." "warn"
        # 备用安装方法
        if wget -qO- https://mise.run | sh; then
            log "mise 备用安装成功" "info"
            export PATH="$HOME/.local/bin:$PATH"
            MISE_INSTALLED=true
        else
            log "mise 安装失败" "error"
            MISE_INSTALLED=false
        fi
    fi
fi

if [ "$MISE_INSTALLED" = true ]; then
    # 确保 mise 在 PATH 中
    if ! command -v mise >/dev/null 2>&1; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # 验证 mise 安装
    if command -v mise >/dev/null 2>&1; then
        log "mise 版本: $(mise --version)" "info"
        
        # 更新 .zshrc 以确保 mise 正确初始化
        if ! grep -q "mise activate zsh" /root/.zshrc; then
            echo '' >> /root/.zshrc
            echo '# mise 初始化' >> /root/.zshrc
            echo 'if command -v mise >/dev/null 2>&1; then' >> /root/.zshrc
            echo '    eval "$(mise activate zsh)"' >> /root/.zshrc
            echo 'fi' >> /root/.zshrc
            log "已将 mise 初始化添加到 .zshrc" "info"
        fi
        
        log "mise 配置完成" "info"
    else
        log "mise 安装后验证失败" "warn"
    fi
else
    log "mise 安装失败，跳过配置" "warn"
fi

step_end 5 "mise 工具配置完成"

# --- 步骤 6: 网络优化配置 ---
step_start 6 "网络优化配置"
SYSCTL_CONFIG_FILE="/etc/sysctl.d/99-network-optimizations.conf"
SYSCTL_BACKUP_FILE="$SYSCTL_CONFIG_FILE.bak.orig.$SCRIPT_VERSION"

if [ -f "$SYSCTL_CONFIG_FILE" ] && [ ! -f "$SYSCTL_BACKUP_FILE" ]; then
    run_cmd cp "$SYSCTL_CONFIG_FILE" "$SYSCTL_BACKUP_FILE"
    log "已备份现有网络配置到 $SYSCTL_BACKUP_FILE" "info"
fi

cat > "$SYSCTL_CONFIG_FILE" << 'EOF'
# 网络优化配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF

run_cmd sysctl -p "$SYSCTL_CONFIG_FILE" || log "应用网络配置失败，但继续执行" "warn"
log "网络优化配置已应用" "info"
step_end 6 "网络优化配置完成"

# --- 步骤 7: SSH 安全加固 ---
step_start 7 "SSH 安全加固"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
SSH_BACKUP_FILE="$SSH_CONFIG_FILE.bak.orig.$SCRIPT_VERSION"

if [ -f "$SSH_CONFIG_FILE" ] && [ ! -f "$SSH_BACKUP_FILE" ]; then
    run_cmd cp "$SSH_CONFIG_FILE" "$SSH_BACKUP_FILE"
    log "已备份 SSH 配置到 $SSH_BACKUP_FILE" "info"
fi

# 应用 SSH 安全配置
run_cmd sed -i 's/#PermitRootLogin yes/PermitRootLogin yes/' "$SSH_CONFIG_FILE" || true
run_cmd sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$SSH_CONFIG_FILE" || true
run_cmd sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSH_CONFIG_FILE" || true

# 重启 SSH 服务
if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
    run_cmd systemctl reload ssh || run_cmd systemctl reload sshd || log "SSH 服务重载失败" "warn"
    log "SSH 配置已更新并重载" "info"
else
    log "SSH 服务未运行，配置已更新" "info"
fi

step_end 7 "SSH 安全加固完成"

# --- 步骤 8: Docker 安装与 IPv6 配置 ---
step_start 8 "Docker 安装与 IPv6 配置"

# 8.1: 检查系统 IPv6 支持
log "检查系统 IPv6 支持..." "info"
IPV6_SUPPORTED=false
if [ -f /proc/net/if_inet6 ] && grep -q "ipv6" /proc/modules 2>/dev/null; then
    IPV6_SUPPORTED=true
    log "系统支持 IPv6" "info"
else
    log "警告: 系统可能不支持 IPv6，将仍然配置 Docker IPv6 但可能无法正常工作" "warn"
fi

# 8.2: 安装 Docker
if command -v docker &>/dev/null; then
    log "Docker 已安装: $(docker --version)" "info"
    DOCKER_INSTALLED=true
else
    log "安装 Docker..." "info"
    DOCKER_INSTALLED=false
    
    # 安装依赖
    run_cmd apt install -y apt-transport-https ca-certificates gnupg lsb-release
    
    # 添加 Docker 官方 GPG 密钥
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        run_cmd mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | run_cmd gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    
    # 添加 Docker 仓库
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | run_cmd tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 安装 Docker
    run_cmd apt update
    run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # 启动并启用 Docker
    run_cmd systemctl enable --now docker
    log "Docker 安装完成" "info"
    DOCKER_INSTALLED=true
fi

# 8.3: 配置 Docker IPv6 支持
if [ "$DOCKER_INSTALLED" = true ]; then
    log "配置 Docker IPv6 支持..." "info"
    DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
    DOCKER_DAEMON_BACKUP="$DOCKER_DAEMON_JSON.bak.orig.$SCRIPT_VERSION"
    
    # 备份现有配置文件
    if [ -f "$DOCKER_DAEMON_JSON" ] && [ ! -f "$DOCKER_DAEMON_BACKUP" ]; then
        run_cmd cp "$DOCKER_DAEMON_JSON" "$DOCKER_DAEMON_BACKUP"
        log "已备份现有 Docker daemon.json 到 $DOCKER_DAEMON_BACKUP" "info"
    fi
    
    # 创建或更新 daemon.json
    run_cmd mkdir -p /etc/docker
    
    if [ -f "$DOCKER_DAEMON_JSON" ]; then
        # 如果文件存在，尝试合并配置
        log "检测到现有 daemon.json，尝试合并 IPv6 配置..." "info"
        
        # 使用 Python 或简单的文本处理来合并 JSON
        if command -v python3 &>/dev/null; then
            # 使用 Python 合并 JSON
            python3 -c "
import json
import sys

try:
    with open('$DOCKER_DAEMON_JSON', 'r') as f:
        config = json.load(f)
except:
    config = {}

config['ipv6'] = True
config['fixed-cidr-v6'] = 'fd00::/80'

with open('$DOCKER_DAEMON_JSON', 'w') as f:
    json.dump(config, f, indent=2)
    
print('IPv6 配置已合并到现有 daemon.json')
" && log "IPv6 配置已合并到现有 daemon.json" "info"
        else
            # 如果没有 Python，检查是否已包含 IPv6 配置
            if grep -q '"ipv6"' "$DOCKER_DAEMON_JSON" && grep -q '"fixed-cidr-v6"' "$DOCKER_DAEMON_JSON"; then
                log "daemon.json 已包含 IPv6 配置，跳过修改" "info"
            else
                log "无法自动合并配置，将覆盖 daemon.json" "warn"
                cat > "$DOCKER_DAEMON_JSON" << 'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
EOF
                log "已创建新的 daemon.json 配置" "info"
            fi
        fi
    else
        # 如果文件不存在，直接创建
        cat > "$DOCKER_DAEMON_JSON" << 'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
EOF
        log "已创建 Docker daemon.json 配置文件" "info"
    fi
    
    # 8.4: 重启 Docker 服务以应用 IPv6 配置
    log "重启 Docker 服务以应用 IPv6 配置..." "warn"
    if run_cmd systemctl restart docker; then
        log "Docker 服务重启成功" "info"
        
        # 验证 Docker 服务状态
        sleep 2
        if systemctl is-active docker &>/dev/null; then
            log "Docker 服务运行正常" "info"
            
            # 验证 IPv6 配置
            if docker network ls | grep -q bridge; then
                log "验证 Docker IPv6 配置..." "info"
                if docker network inspect bridge | grep -q "fd00::/80" 2>/dev/null; then
                    log "Docker IPv6 配置验证成功" "info"
                else
                    log "Docker IPv6 配置可能未生效，但服务正常运行" "warn"
                fi
            fi
        else
            log "Docker 服务重启后状态异常" "warn"
        fi
    else
        log "Docker 服务重启失败" "warn"
    fi
else
    log "Docker 未安装，跳过 IPv6 配置" "warn"
fi

# 8.5: 确保 Docker 服务正常运行
check_and_start_service docker

# 8.6: 安装 docker-compose (独立版本)
if ! command -v docker-compose &>/dev/null; then
    log "安装 docker-compose..." "info"
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
    if [ -n "$DOCKER_COMPOSE_VERSION" ]; then
        run_cmd curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        run_cmd chmod +x /usr/local/bin/docker-compose
        log "docker-compose 安装完成: $(docker-compose --version)" "info"
    else
        log "获取 docker-compose 版本失败，跳过安装" "warn"
    fi
else
    log "docker-compose 已安装: $(docker-compose --version)" "info"
fi

step_end 8 "Docker 安装与 IPv6 配置完成"

# --- 步骤 9: 系统服务优化 ---
step_start 9 "系统服务优化"

# 启用并启动关键服务
for service in chrony cron; do
    check_and_start_service "$service"
done

# 配置自动更新
if ! grep -q "unattended-upgrades" /etc/cron.daily/* 2>/dev/null; then
    log "配置自动更新..." "info"
    run_cmd apt install -y unattended-upgrades
    run_cmd dpkg-reconfigure -plow unattended-upgrades
fi

step_end 9 "系统服务优化完成"

# --- 步骤 10: 清理和完成 ---
step_start 10 "系统清理和状态记录"

# 清理
run_cmd apt autoremove -y
run_cmd apt autoclean

# 记录部署状态
cat > "$STATUS_FILE" << EOF
{
    "script_version": "$SCRIPT_VERSION",
    "deployment_date": "$(date -Iseconds)",
    "debian_version": "$(cat /etc/debian_version)",
    "zsh_installed": true,
    "mise_installed": $([ "$MISE_INSTALLED" = true ] && echo "true" || echo "false"),
    "docker_installed": $(command -v docker &>/dev/null && echo "true" || echo "false"),
    "docker_ipv6_enabled": true,
    "ipv6_supported": $([ "$IPV6_SUPPORTED" = true ] && echo "true" || echo "false"),
    "zram_configured": $(echo "$ZRAM_SWAP_STATUS" | grep -q "成功" && echo "true" || echo "false")
}
EOF

log "部署状态已记录到 $STATUS_FILE" "info"

step_end 10 "系统清理和状态记录完成"

# --- 完成 ---
echo
log "==============================================" "title"
log "🎉 Debian 系统部署完成!" "title"
log "==============================================" "title"
echo
log "主要组件状态:" "info"
log "  ✓ Zsh + Oh My Zsh + Powerlevel10k" "info"
log "  ✓ mise 工具 (如果安装成功)" "info"
log "  ✓ Docker + docker-compose (IPv6 已启用)" "info"
log "  ✓ Zram Swap 优化" "info"
log "  ✓ 网络性能优化" "info"
log "  ✓ SSH 安全加固" "info"
echo
log "实用别名已配置:" "info"
log "  • upgrade - 系统完整升级" "info"
log "  • update - 更新软件包列表" "info"
log "  • reproxy - 重新部署代理服务" "info"
log "  • autodel - 清理系统和Docker" "info"
log "  • copyall - 执行Ansible批量部署" "info"
echo
log "重要提醒:" "warn"
log "  • 请重新登录以使用 Zsh shell" "warn"
log "  • 首次使用 Zsh 时会提示配置 Powerlevel10k" "warn"
log "  • mise 工具需要在新的 shell 会话中使用" "warn"
log "  • Docker IPv6 支持已启用 (fd00::/80)" "warn"
echo
log "完成时间: $(date)" "info"
