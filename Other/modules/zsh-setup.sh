#!/bin/bash
# Zsh Shell 环境配置模块

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# 安装 Zsh
log "检查并安装 Zsh..." "info"
if ! command -v zsh &>/dev/null; then
    apt install -y zsh git
fi

if ! command -v zsh &>/dev/null; then
    log "Zsh 安装失败" "error"
    exit 1
fi

ZSH_VERSION=$(zsh --version | awk '{print $2}')
log "Zsh 已安装 (版本: $ZSH_VERSION)" "info"

# 安装 Oh My Zsh
log "安装 Oh My Zsh..." "info"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    log "Oh My Zsh 安装完成" "info"
else
    log "Oh My Zsh 已存在" "info"
fi

# 安装 Powerlevel10k 主题
log "安装 Powerlevel10k 主题..." "info"
THEME_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ ! -d "$THEME_DIR" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR"
    log "Powerlevel10k 主题安装完成" "info"
else
    log "Powerlevel10k 主题已存在" "info"
fi

# 安装插件
log "安装 Zsh 插件..." "info"
CUSTOM_PLUGINS="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
mkdir -p "$CUSTOM_PLUGINS"

declare -A plugins=(
    ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
    ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    ["zsh-completions"]="https://github.com/zsh-users/zsh-completions"
)

for plugin in "${!plugins[@]}"; do
    if [ ! -d "$CUSTOM_PLUGINS/$plugin" ]; then
        git clone "${plugins[$plugin]}" "$CUSTOM_PLUGINS/$plugin"
        log "插件 $plugin 安装完成" "info"
    fi
done

# 配置 .zshrc
log "配置 .zshrc 文件..." "info"
[ -f "$HOME/.zshrc" ] && cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"

cat > "$HOME/.zshrc" << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# 新增：禁用 Oh My Zsh 自动更新提示，并设置更新频率
DISABLE_UPDATE_PROMPT="true"
UPDATE_ZSH_DAYS=7

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

source $ZSH/oh-my-zsh.sh
autoload -U compinit && compinit
export PATH="$HOME/.local/bin:$PATH"

# mise 版本管理器配置
command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"

# Powerlevel10k 配置
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 实用别名
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias autodel='docker system prune -a -f && apt autoremove -y'
alias copyall='cd /root/copy && ansible-playbook -i inventory.ini copyhk.yml && ansible-playbook -i inventory.ini copysg.yml && ansible-playbook -i inventory.ini copyother.yml'
EOF

log ".zshrc 配置完成" "info"

# 自动配置 Powerlevel10k 为 Rainbow 主题
# Powerlevel10k 自带了预设的配置文件，可以直接复制
log "Powerlevel10k 已自动配置为 Rainbow 主题..." "info"
cp "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/config/p10k-rainbow.zsh" "$HOME/.p10k.zsh"
log "Rainbow 主题配置完成" "info"

# 询问是否设置为默认 Shell
CURRENT_SHELL=$(getent passwd root | cut -d: -f7)
ZSH_PATH=$(which zsh)

if [ "$CURRENT_SHELL" != "$ZSH_PATH" ]; then
    read -p "是否将 Zsh 设置为默认 Shell? (y/n): " set_default
    if [[ "$set_default" =~ ^[Yy]$ ]]; then
        chsh -s "$ZSH_PATH" root
        log "Zsh 已设置为默认 Shell (重新登录后生效)" "info"
    fi
else
    log "Zsh 已是默认 Shell" "info"
fi

log "Zsh 环境配置完成" "info"
log "提示: 运行 'exec zsh' 立即体验新环境" "info"

exit 0
