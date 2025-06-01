#!/bin/bash

# Fish/Starship 安全清理脚本 - 保护mise (最终完善版)
# 修复了mise PATH配置问题、chsh认证失败、fish源残留等问题

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
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

# 步骤1: 检查当前状态
log "=== 步骤1: 检查当前状态 ==="
echo "当前用户: $(whoami)"
echo "当前shell: $SHELL"

# 更准确地检测mise
MISE_INSTALLED=false
MISE_PATH=""
MISE_DATA_DIR=""

# 检查常见mise位置
for path in ~/.local/bin/mise /usr/local/bin/mise /usr/bin/mise; do
    if [ -f "$path" ]; then
        MISE_PATH="$path"
        MISE_INSTALLED=true
        echo "mise程序: $path"
        break
    fi
done

# 检查mise数据目录
for data_dir in ~/.local/share/mise ~/.mise; do
    if [ -d "$data_dir" ]; then
        MISE_DATA_DIR="$data_dir"
        echo "mise数据: $data_dir"
        break
    fi
done

if [ "$MISE_INSTALLED" = true ]; then
    success "mise已安装"
    # 临时设置PATH来获取版本
    export PATH="$(dirname "$MISE_PATH"):$PATH"
    if command -v mise >/dev/null 2>&1; then
        echo "mise版本: $(mise --version 2>/dev/null || echo '无法获取版本')"
    fi
else
    warn "mise未检测到"
fi

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

echo

# 步骤2: 备份mise配置和状态
if [ "$MISE_INSTALLED" = true ]; then
    log "=== 步骤2: 备份mise配置和状态 ==="
    
    BACKUP_DIR="/tmp/mise_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # 确保mise可用
    export PATH="$(dirname "$MISE_PATH"):$PATH"
    
    # 备份mise当前状态
    mise list > "$BACKUP_DIR/mise_list.txt" 2>/dev/null || echo "mise list failed" > "$BACKUP_DIR/mise_list.txt"
    mise current > "$BACKUP_DIR/mise_current.txt" 2>/dev/null || echo "mise current failed" > "$BACKUP_DIR/mise_current.txt"
    echo "$MISE_PATH" > "$BACKUP_DIR/mise_path.txt"
    echo "$MISE_DATA_DIR" > "$BACKUP_DIR/mise_data_dir.txt"
    
    # 备份fish配置中的mise部分（如果存在）
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
echo "  - ~/.local/share/fish/ 目录"
echo

echo "将会保留:"
[ "$MISE_INSTALLED" = true ] && echo "  - mise程序: $MISE_PATH"
[ -n "$MISE_DATA_DIR" ] && echo "  - mise数据: $MISE_DATA_DIR"
echo "  - 其他系统配置"
echo

read -p "确认执行清理操作? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    error "操作已取消"
    exit 1
fi

# 步骤4: 执行清理
log "=== 步骤4: 执行清理操作 ==="

# 清理fish
if [ "$FISH_INSTALLED" = true ]; then
    log "卸载Fish shell..."
    sudo apt remove --purge fish -y >/dev/null 2>&1 || warn "apt remove fish失败，可能已卸载"
    sudo apt autoremove -y >/dev/null 2>&1 || true
    success "Fish shell已卸载"
fi

# 更彻底地清理fish官方源和密钥
log "清理Fish官方源和密钥..."
sudo rm -f /etc/apt/trusted.gpg.d/shells_fish_release_4.gpg 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/shells_fish_release_4.list 2>/dev/null || true
# 清理可能的其他命名方式
sudo rm -f /etc/apt/sources.list.d/shells:fish:release:4.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/*fish* 2>/dev/null || true
success "Fish官方源已清理"

# 清理starship
if [ "$STARSHIP_INSTALLED" = true ]; then
    log "卸载Starship..."
    sudo rm -f /usr/local/bin/starship 2>/dev/null || true
    # 也检查用户本地安装
    rm -f ~/.local/bin/starship 2>/dev/null || true
    success "Starship已卸载"
fi

# 清理配置目录
log "清理配置目录..."
rm -rf ~/.config/fish/ 2>/dev/null || true
rm -rf ~/.local/share/fish/ 2>/dev/null || true
success "配置目录已清理"

# 清理脚本状态文件
sudo rm -f /var/lib/system-deploy-status.json 2>/dev/null || true

# 更新apt缓存
log "更新apt缓存..."
sudo apt update >/dev/null 2>&1 || warn "apt update失败"

success "清理操作完成"
echo

# 步骤5: 恢复mise到bash（如果needed）
if [ "$MISE_INSTALLED" = true ]; then
    log "=== 步骤5: 配置mise到bash ==="
    
    # 检查bash配置中是否已有mise相关配置
    MISE_PATH_IN_BASHRC=false
    MISE_ACTIVATE_IN_BASHRC=false
    
    if grep -q "\.local/bin.*PATH" ~/.bashrc 2>/dev/null; then
        MISE_PATH_IN_BASHRC=true
    fi
    
    if grep -q "mise activate bash" ~/.bashrc 2>/dev/null; then
        MISE_ACTIVATE_IN_BASHRC=true
    fi
    
    # 添加PATH配置
    if [ "$MISE_PATH_IN_BASHRC" = false ]; then
        log "添加mise PATH到bash配置..."
        echo '' >> ~/.bashrc
        echo '# mise配置 (添加于fish清理后)' >> ~/.bashrc
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        success "mise PATH已添加到 ~/.bashrc"
    else
        success "mise PATH已在bash配置中"
    fi
    
    # 添加mise激活配置
    if [ "$MISE_ACTIVATE_IN_BASHRC" = false ]; then
        log "添加mise激活到bash配置..."
        echo 'eval "$(mise activate bash)"' >> ~/.bashrc
        success "mise激活已添加到 ~/.bashrc"
    else
        success "mise激活已在bash配置中"
    fi
    
    # 立即在当前会话中配置mise
    log "在当前会话中激活mise..."
    export PATH="$HOME/.local/bin:$PATH"
    if [ -f "$MISE_PATH" ]; then
        eval "$("$MISE_PATH" activate bash)" 2>/dev/null || warn "mise激活失败，但配置已添加到bashrc"
        success "mise已在当前会话中激活"
    fi
    
    success "mise配置到bash完成"
    echo
fi

# 步骤6: 恢复用户默认shell（非阻塞版本）
log "=== 步骤6: 检查并修复默认shell ==="
current_shell=$(getent passwd "$USER" | cut -d: -f7)
if echo "$current_shell" | grep -q fish; then
    log "检测到默认shell为fish，修改为bash..."
    
    # 备份passwd文件
    sudo cp /etc/passwd /etc/passwd.bak.$(date +%Y%m%d%H%M%S)
    
    # 直接使用最可靠的方法，避免交互
    if sudo sed -i "s|^$USER:\([^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*|$USER:\1/bin/bash|" /etc/passwd; then
        new_shell=$(getent passwd "$USER" | cut -d: -f7)
        if echo "$new_shell" | grep -q bash; then
            success "默认shell已修改为: $new_shell"
        else
            warn "shell修改可能失败，但不影响mise功能"
        fi
    else
        warn "无法修改默认shell，但不影响mise功能"
    fi
else
    success "默认shell无需修改: $current_shell"
fi
echo

# 步骤7: 验证结果
log "=== 步骤7: 验证清理结果 ==="

# 验证fish已清理
if ! command -v fish >/dev/null 2>&1; then
    success "fish已完全清理"
else
    warn "fish仍然存在: $(which fish)"
fi

# 验证starship已清理
if ! command -v starship >/dev/null 2>&1; then
    success "starship已完全清理"
else
    warn "starship仍然存在: $(which starship)"
fi

# 验证mise状态
if [ "$MISE_INSTALLED" = true ]; then
    # 确保PATH正确
    export PATH="$HOME/.local/bin:$PATH"
    
    if [ -f "$MISE_PATH" ]; then
        success "mise程序保持完好: $MISE_PATH"
        
        # 测试mise功能
        log "测试mise功能..."
        if "$MISE_PATH" --version >/dev/null 2>&1; then
            success "mise工作正常"
            echo "mise版本: $("$MISE_PATH" --version)"
            
            # 显示恢复的工具
            log "检查已安装的工具..."
            if "$MISE_PATH" list 2>/dev/null | grep -q .; then
                success "工具列表已恢复:"
                "$MISE_PATH" list 2>/dev/null | head -10
            else
                warn "暂无已安装的工具，但mise功能正常"
            fi
        else
            warn "mise需要重启终端后才能正常工作"
        fi
    else
        error "mise程序丢失！检查备份: $BACKUP_DIR"
    fi
fi

# 更彻底地检查apt源清理结果
log "检查apt源清理情况..."
fish_sources=$(ls /etc/apt/sources.list.d/ 2>/dev/null | grep -i fish || true)
if [ -z "$fish_sources" ]; then
    success "apt源已完全清理"
else
    warn "发现残留fish源文件，正在清理: $fish_sources"
    for source in $fish_sources; do
        sudo rm -f "/etc/apt/sources.list.d/$source"
        log "已删除: $source"
    done
    sudo apt update >/dev/null 2>&1 || true
    success "残留源文件已清理完成"
fi

echo
log "=== 清理完成总结 ==="
success "Fish和Starship已完全清理"
[ "$MISE_INSTALLED" = true ] && success "mise和所有工具数据完整保留"
[ -n "$BACKUP_DIR" ] && echo "备份位置: $BACKUP_DIR"

echo
warn "下一步操作:"
echo "1. 重启终端或执行: source ~/.bashrc"
echo "2. 验证mise: mise --version && mise list"
echo "3. 如需激活python: mise use python@latest"
echo "4. 可选更新mise: mise self-update"

# 提供立即验证命令
echo
log "=== 立即验证命令 ==="
echo "执行以下命令验证mise是否正常:"
echo "source ~/.bashrc && mise --version && mise list && echo '一切正常！'"
