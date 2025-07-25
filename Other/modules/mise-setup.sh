#!/bin/bash
# Mise 版本管理器配置模块

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

MISE_PATH="$HOME/.local/bin/mise"

# 创建目录
mkdir -p "$HOME/.local/bin"

# 安装 Mise
log "检查并安装 Mise..." "info"
if [ ! -f "$MISE_PATH" ]; then
    log "安装 Mise..." "info"
    curl https://mise.run | sh
    if [ ! -f "$MISE_PATH" ]; then
        log "Mise 安装失败" "error"
        exit 1
    fi
    log "Mise 安装完成" "info"
else
    MISE_VERSION=$($MISE_PATH --version 2>/dev/null || echo "未知")
    log "Mise 已安装 ($MISE_VERSION)" "info"
    
    read -p "是否更新 Mise 到最新版本? (y/n): " update_mise
    if [[ "$update_mise" =~ ^[Yy]$ ]]; then
        curl https://mise.run | sh
        log "Mise 已更新" "info"
    fi
fi

# 配置 Python 3.10
log "配置 Python 3.10..." "info"
if $MISE_PATH list python 2>/dev/null | grep -q "3.10"; then
    log "Python 3.10 已通过 Mise 配置" "info"
    read -p "是否重新安装 Python 3.10? (y/n): " reinstall_python
    if [[ "$reinstall_python" =~ ^[Yy]$ ]]; then
        $MISE_PATH use -g python@3.10
        log "Python 3.10 重新配置完成" "info"
    fi
else
    log "安装 Python 3.10..." "info"
    if $MISE_PATH use -g python@3.10; then
        log "Python 3.10 安装完成" "info"
    else
        log "Python 3.10 安装失败" "warn"
    fi
fi

# 把 mise 管理的 python 链接到 /usr/bin/python 和 /usr/bin/python3
link_python_to_usr_bin() {
    local mise_python_shim
    mise_python_shim="$($MISE_PATH which python 2>/dev/null)"
    # 不直接用shim，找到实际可执行文件
    if [ -x "$mise_python_shim" ]; then
        local real_python
        real_python=$("$mise_python_shim" -c 'import sys; print(sys.executable)')
        if [ -n "$real_python" ] && [ -x "$real_python" ]; then
            log "sudo ln -sf $real_python /usr/bin/python" "warn"
            sudo ln -sf "$real_python" /usr/bin/python
            log "/usr/bin/python 已指向: $real_python" "info"
            log "sudo ln -sf $real_python /usr/bin/python3" "warn"
            sudo ln -sf "$real_python" /usr/bin/python3
            log "/usr/bin/python3 已指向: $real_python" "info"
        else
            log "找不到实际可执行的 Python，未建立链接" "error"
        fi
    else
        log "mise 的 python shim 不可执行，未建立链接" "error"
    fi
}

link_python_to_usr_bin

# 配置 Shell 集成
log "配置 Shell 集成..." "info"

# 配置 .bashrc
BASHRC_FILE="$HOME/.bashrc"
[ ! -f "$BASHRC_FILE" ] && touch "$BASHRC_FILE"

if ! grep -q "mise activate bash" "$BASHRC_FILE"; then
    echo -e "\n# Mise version manager\neval \"\$(\$HOME/.local/bin/mise activate bash)\"" >> "$BASHRC_FILE"
    log "Mise 已添加到 .bashrc" "info"
else
    log "Mise 已存在于 .bashrc" "info"
fi

# 配置 .zshrc (如果存在)
if [ -f "$HOME/.zshrc" ] && command -v zsh &>/dev/null; then
    if ! grep -q "mise activate zsh" "$HOME/.zshrc"; then
        sed -i '/# mise 版本管理器配置/a eval "$(mise activate zsh)"' "$HOME/.zshrc"
        log "Mise 已添加到 .zshrc" "info"
    else
        log "Mise 已存在于 .zshrc" "info"
    fi
fi

log "Mise 配置完成" "info"
log "提示: 运行 'source ~/.bashrc' 或重新登录以激活 Mise" "info"

if [ -f "$MISE_PATH" ]; then
    log "提示: 查看已安装工具: $MISE_PATH list" "info"
    if $MISE_PATH which python &>/dev/null; then
        PYTHON_VERSION=$($($MISE_PATH which python) --version 2>/dev/null || echo "版本获取失败")
        log "Python 状态: $PYTHON_VERSION" "info"
    fi
fi

exit 0
