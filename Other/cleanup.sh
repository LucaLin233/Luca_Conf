#!/bin/bash

# Fish → Zsh 完整迁移脚本 - 保护mise并直接迁移到Zsh
# 功能：清理Fish + 安装Zsh + 迁移mise到Zsh

set -e

# 检查是否为自动模式
AUTO_CONFIRM=false
if [ "$1" = "-y" ] || [ "$1" = "--yes" ]; then
    AUTO_CONFIRM=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[1;35m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

title() {
    echo -e "${PURPLE}🚀 $1${NC}"
}

# 检测操作系统
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt > /dev/null 2>&1; then
            OS="ubuntu"
        elif command -v dnf > /dev/null 2>&1; then
            OS="fedora"
        elif command -v pacman > /dev/null 2>&1; then
            OS="arch"
        else
            error "不支持的 Linux 发行版"
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        error "不支持的操作系统"
        exit 1
    fi
    success "检测到操作系统: $OS"
}

# 步骤1: 检查当前状态
log "=== 步骤1: 检查当前状态 ==="
echo "当前用户: $(whoami)"
echo "当前shell: $SHELL"

# 检测mise
MISE_INSTALLED=false
MISE_PATH=""
MISE_DATA_DIR=""

for path in ~/.local/bin/mise /usr/local/bin/mise /usr/bin/mise; do
    if [ -f "$path" ]; then
        MISE_PATH="$path"
        MISE_INSTALLED=true
        echo "mise程序: $path"
        break
    fi
done

for data_dir in ~/.local/share/mise ~/.mise; do
    if [ -d "$data_dir" ]; then
        MISE_DATA_DIR="$data_dir"
        echo "mise数据: $data_dir"
        break
    fi
done

if [ "$MISE_INSTALLED" = true ]; then
    success "mise已安装"
    export PATH="$(dirname "$MISE_PATH"):$PATH"
    if command -v mise >/dev/null 2>&1; then
        echo "mise版本: $(mise --version 2>/dev/null || echo '无法获取版本')"
    fi
else
    warn "mise未检测到"
fi

# 检测当前shell环境
if command -v fish >/dev/null 2>&1; then
    echo "fish版本: $(fish --version)"
    success "fish已安装"
    FISH_INSTALLED=true
else
    warn "fish未检测到"
    FISH_INSTALLED=false
fi

if command -v starship >/dev/null 2>&1; then
    echo "starship版本: $(starship --version)"
    success "starship已安装"
    STARSHIP_INSTALLED=true
else
    warn "starship未检测到"
    STARSHIP_INSTALLED=false
fi

if command -v zsh >/dev/null 2>&1; then
    echo "zsh版本: $(zsh --version)"
    warn "zsh已安装"
    ZSH_INSTALLED=true
else
    log "zsh未检测到，将进行安装"
    ZSH_INSTALLED=false
fi

detect_os
echo

# 步骤2: 备份mise配置
if [ "$MISE_INSTALLED" = true ]; then
    log "=== 步骤2: 备份mise配置和状态 ==="
    
    BACKUP_DIR="/tmp/mise_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    export PATH="$(dirname "$MISE_PATH"):$PATH"
    
    mise list > "$BACKUP_DIR/mise_list.txt" 2>/dev/null || echo "mise list failed" > "$BACKUP_DIR/mise_list.txt"
    mise current > "$BACKUP_DIR/mise_current.txt" 2>/dev/null || echo "mise current failed" > "$BACKUP_DIR/mise_current.txt"
    echo "$MISE_PATH" > "$BACKUP_DIR/mise_path.txt"
    echo "$MISE_DATA_DIR" > "$BACKUP_DIR/mise_data_dir.txt"
    
    if [ -f ~/.config/fish/config.fish ]; then
        grep -n "mise" ~/.config/fish/config.fish > "$BACKUP_DIR/fish_mise_config.txt" 2>/dev/null || echo "No mise config in fish" > "$BACKUP_DIR/fish_mise_config.txt"
        cp ~/.config/fish/config.fish "$BACKUP_DIR/config.fish.bak" 2>/dev/null || true
    fi
    
    success "mise状态已备份到: $BACKUP_DIR"
    echo
fi

# 步骤3: 用户确认
log "=== 即将执行的操作 ==="
echo "将会删除:"
[ "$FISH_INSTALLED" = true ] && echo "  - Fish shell及其所有配置"
[ "$STARSHIP_INSTALLED" = true ] && echo "  - Starship提示符"
echo "  - Fish官方源和GPG密钥"
echo "  - ~/.config/fish/ 目录"
echo

echo "将会安装:"
[ "$ZSH_INSTALLED" = false ] && echo "  - Zsh shell"
echo "  - Oh My Zsh + Powerlevel10k"
echo "  - 推荐的zsh插件"
echo

echo "将会保留并迁移:"
[ "$MISE_INSTALLED" = true ] && echo "  - mise程序及所有数据"
[ "$MISE_INSTALLED" = true ] && echo "  - mise将配置到zsh环境"
echo

if [ "$AUTO_CONFIRM" = true ]; then
    confirm="y"
    success "自动确认模式，继续执行..."
else
    read -p "确认执行迁移操作? (y/N): " confirm </dev/tty
fi

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    error "操作已取消"
    exit 1
fi

# 步骤4: 清理Fish和Starship
title "步骤4: 清理Fish和Starship"

if [ "$FISH_INSTALLED" = true ]; then
    log "卸载Fish shell..."
    sudo apt remove --purge fish -y >/dev/null 2>&1 || warn "apt remove fish失败"
    sudo apt autoremove -y >/dev/null 2>&1 || true
    success "Fish shell已卸载"
fi

log "清理Fish官方源和密钥..."
sudo rm -f /etc/apt/trusted.gpg.d/shells_fish_release_4.gpg 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/shells_fish_release_4.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/shells:fish:release:4.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/*fish* 2>/dev/null || true
success "Fish官方源已清理"

if [ "$STARSHIP_INSTALLED" = true ]; then
    log "卸载Starship..."
    sudo rm -f /usr/local/bin/starship 2>/dev/null || true
    rm -f ~/.local/bin/starship 2>/dev/null || true
    success "Starship已卸载"
fi

log "清理配置目录..."
rm -rf ~/.config/fish/ 2>/dev/null || true
rm -rf ~/.local/share/fish/ 2>/dev/null || true
success "配置目录已清理"

sudo rm -f /var/lib/system-deploy-status.json 2>/dev/null || true
sudo apt update >/dev/null 2>&1 || warn "apt update失败"

success "Fish/Starship清理完成"
echo

# 步骤5: 安装Zsh环境
title "步骤5: 安装Zsh + Oh My Zsh + Powerlevel10k"

# 5.1: 安装Zsh
if [ "$ZSH_INSTALLED" = false ]; then
    log "安装Zsh和必要工具..."
    case $OS in
        ubuntu)
            sudo apt update && sudo apt install -y zsh git curl wget
            ;;
        fedora)
            sudo dnf install -y zsh git curl wget
            ;;
        arch)
            sudo pacman -S --noconfirm zsh git curl wget
            ;;
        macos)
            if ! command -v brew > /dev/null 2>&1; then
                error "请先安装 Homebrew"
                exit 1
            fi
            brew install zsh git curl wget
            ;;
    esac
    success "Zsh安装完成，版本：$(zsh --version)"
else
    success "Zsh已存在，跳过安装"
fi

# 5.2: 安装Oh My Zsh
log "安装Oh My Zsh..."
if [ -d "$HOME/.oh-my-zsh" ]; then
    warn "Oh My Zsh已存在，跳过安装"
else
    RUNZSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || warn "Oh My Zsh安装可能失败"
fi
success "Oh My Zsh准备完成"

# 5.3: 安装Powerlevel10k主题
log "安装Powerlevel10k主题..."
THEME_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ -d "$THEME_DIR" ]; then
    warn "Powerlevel10k已存在，跳过安装"
else
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR"
fi
success "Powerlevel10k主题安装完成"

# 5.4: 安装推荐插件
log "安装推荐插件..."
CUSTOM_PLUGINS="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"

if [ ! -d "$CUSTOM_PLUGINS/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "$CUSTOM_PLUGINS/zsh-autosuggestions"
fi

if [ ! -d "$CUSTOM_PLUGINS/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$CUSTOM_PLUGINS/zsh-syntax-highlighting"
fi

if [ ! -d "$CUSTOM_PLUGINS/zsh-completions" ]; then
    git clone https://github.com/zsh-users/zsh-completions "$CUSTOM_PLUGINS/zsh-completions"
fi

success "插件安装完成"
echo

# 步骤6: 配置.zshrc并集成mise
title "步骤6: 配置Zsh并集成mise"

if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
    log "原.zshrc已备份"
fi

log "创建新的.zshrc配置..."
cat > "$HOME/.zshrc" << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"

# 设置主题
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
)

# 加载 Oh My Zsh
source $ZSH/oh-my-zsh.sh

# 启用补全
autoload -U compinit && compinit

# mise配置 (从fish迁移)
export PATH="$HOME/.local/bin:$PATH"
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF

success ".zshrc配置完成（已集成mise）"

# 测试mise在zsh中的配置
if [ "$MISE_INSTALLED" = true ]; then
    log "测试mise在zsh中的配置..."
    export PATH="$HOME/.local/bin:$PATH"
    if [ -f "$MISE_PATH" ]; then
        # 在zsh子shell中测试mise
        if zsh -c "source ~/.zshrc && mise --version" >/dev/null 2>&1; then
            success "mise已成功配置到zsh"
        else
            warn "mise配置可能需要重启终端后生效"
        fi
    fi
fi
echo

# 步骤7: 配置Powerlevel10k主题
title "步骤7: 配置Powerlevel10k主题"

echo "🎨 选择 Powerlevel10k 主题风格："
echo "1. 📏 Lean（简洁风格，推荐）"
echo "2. 🌈 Rainbow（彩虹风格，图标丰富）"
echo "3. 🎯 Classic（经典风格）"
echo "4. 🔍 Pure（极简风格）"
echo "5. ⚙️  稍后手动配置"
echo ""

while true; do
    if [ "$AUTO_CONFIRM" = true ]; then
        choice="2"
        log "自动模式选择: Rainbow风格（彩虹图标丰富）"
    else
        read -p "请选择配置选项 (1-5): " choice </dev/tty
    fi
    case $choice in
        1)
            if [ -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-lean.zsh" ]; then
                cp "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-lean.zsh" "$HOME/.p10k.zsh"
                success "Lean 风格设置完成！"
            else
                warn "预设配置文件不存在，稍后可运行 'p10k configure'"
            fi
            break
            ;;
        2)
            if [ -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-rainbow.zsh" ]; then
                cp "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-rainbow.zsh" "$HOME/.p10k.zsh"
                success "Rainbow 风格设置完成！"
            else
                warn "预设配置文件不存在，稍后可运行 'p10k configure'"
            fi
            break
            ;;
        3)
            if [ -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-classic.zsh" ]; then
                cp "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-classic.zsh" "$HOME/.p10k.zsh"
                success "Classic 风格设置完成！"
            else
                warn "预设配置文件不存在，稍后可运行 'p10k configure'"
            fi
            break
            ;;
        4)
            if [ -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-pure.zsh" ]; then
                cp "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/config/p10k-pure.zsh" "$HOME/.p10k.zsh"
                success "Pure 风格设置完成！"
            else
                warn "预设配置文件不存在，稍后可运行 'p10k configure'"
            fi
            break
            ;;
        5)
            warn "跳过预设配置，稍后可运行 'p10k configure'"
            break
            ;;
        *)
            echo "❌ 无效选择，请输入 1-5"
            ;;
    esac
done
echo

# 步骤8: 设置默认shell
title "步骤8: 设置Zsh为默认shell"

current_shell=$(getent passwd "$USER" | cut -d: -f7)
zsh_path=$(which zsh)

if [ "$current_shell" = "$zsh_path" ]; then
    success "Zsh已经是默认shell"
else
    log "设置Zsh为默认shell..."
    
    # 备份passwd文件
    sudo cp /etc/passwd /etc/passwd.bak.$(date +%Y%m%d%H%M%S)
    
    if sudo sed -i "s|^$USER:\([^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*|$USER:\1$zsh_path|" /etc/passwd; then
        new_shell=$(getent passwd "$USER" | cut -d: -f7)
        if [ "$new_shell" = "$zsh_path" ]; then
            success "默认shell已设置为zsh"
        else
            warn "默认shell设置可能失败，当前为: $new_shell"
        fi
    else
        warn "无法设置默认shell，可手动执行: chsh -s $(which zsh)"
    fi
fi
echo

# 步骤9: 验证结果
title "步骤9: 验证迁移结果"

# 验证清理结果
if ! command -v fish >/dev/null 2>&1; then
    success "fish已完全清理"
else
    warn "fish仍然存在: $(which fish)"
fi

if ! command -v starship >/dev/null 2>&1; then
    success "starship已完全清理"
else
    warn "starship仍然存在: $(which starship)"
fi

# 验证zsh安装
if command -v zsh >/dev/null 2>&1; then
    success "zsh安装成功: $(zsh --version)"
else
    error "zsh安装失败"
fi

if [ -d "$HOME/.oh-my-zsh" ]; then
    success "Oh My Zsh安装成功"
else
    error "Oh My Zsh安装失败"
fi

# 验证mise状态
if [ "$MISE_INSTALLED" = true ]; then
    export PATH="$HOME/.local/bin:$PATH"
    
    if [ -f "$MISE_PATH" ]; then
        success "mise程序保持完好: $MISE_PATH"
        
        log "在zsh环境中测试mise..."
        if zsh -c "source ~/.zshrc && mise --version && mise list" >/dev/null 2>&1; then
            success "mise在zsh中工作正常"
            echo "mise版本: $(zsh -c "source ~/.zshrc && mise --version" 2>/dev/null)"
            echo "已安装工具:"
            zsh -c "source ~/.zshrc && mise list" 2>/dev/null | head -5
        else
            warn "mise需要重启终端后在zsh中生效"
        fi
    else
        error "mise程序丢失！检查备份: $BACKUP_DIR"
    fi
fi

# 检查apt源
fish_sources=$(ls /etc/apt/sources.list.d/ 2>/dev/null | grep -i fish || true)
if [ -z "$fish_sources" ]; then
    success "apt源已完全清理"
else
    warn "发现残留fish源，正在清理..."
    for source in $fish_sources; do
        sudo rm -f "/etc/apt/sources.list.d/$source"
    done
    sudo apt update >/dev/null 2>&1 || true
    success "残留源文件已清理"
fi

echo
title "🎉 迁移完成！"
echo
success "Fish → Zsh 迁移成功完成！"
[ "$MISE_INSTALLED" = true ] && success "mise已迁移到zsh环境"
[ -n "$BACKUP_DIR" ] && echo "备份位置: $BACKUP_DIR"

echo
warn "下一步操作:"
echo "1. 启动zsh体验新环境: exec zsh"
echo "2. 验证mise: mise --version && mise list"
echo "3. 重新配置p10k主题: p10k configure"
echo "4. 可选更新mise: mise self-update"

echo
log "=== 立即启动zsh ==="
echo "执行以下命令立即切换到zsh:"
echo "exec zsh"
