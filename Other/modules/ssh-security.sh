#!/bin/bash
# SSH 安全配置模块

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

log "配置 SSH 安全设置..." "info"

# 备份 SSH 配置
[ ! -f /etc/ssh/sshd_config.backup ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# 获取当前 SSH 端口
CURRENT_SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT="22"

log "当前 SSH 端口: $CURRENT_SSH_PORT" "info"

# 询问是否更改端口
read -p "是否更改 SSH 端口? 输入新端口号 (1024-65535) 或回车跳过: " new_port

if [ -n "$new_port" ]; then
    # 验证端口号
    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        log "无效的端口号格式" "error"
        exit 1
    fi
    
    if [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        log "端口号必须在 1024-65535 范围内" "error"
        exit 1
    fi
    
    # 检查端口是否被占用
    if ss -tuln | grep -q ":$new_port\b"; then
        log "端口 $new_port 已被占用" "error"
        exit 1
    fi
    
    log "更改 SSH 端口到 $new_port..." "info"
    
    # 移除旧的 Port 配置
    sed -i '/^Port /d' /etc/ssh/sshd_config
    sed -i '/^#Port /d' /etc/ssh/sshd_config
    
    # 添加新端口配置
    echo "Port $new_port" >> /etc/ssh/sshd_config
    
    # 重启 SSH 服务
    log "重启 SSH 服务..." "info"
    if systemctl restart sshd; then
        log "SSH 端口已成功更改为 $new_port" "info"
        log "⚠️  重要: 请确保防火墙允许新端口 $new_port" "warn"
        log "⚠️  重要: 请使用新端口连接: ssh -p $new_port user@server" "warn"
        
        # 保存新端口信息到文件
        echo "$new_port" > /tmp/new_ssh_port
    else
        log "SSH 服务重启失败，端口更改可能未生效" "error"
        exit 1
    fi
else
    log "保持当前 SSH 端口 $CURRENT_SSH_PORT" "info"
fi

# 基础 SSH 安全配置
log "应用基础 SSH 安全设置..." "info"

# 禁用 root 密码登录 (保留密钥登录)
if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
    log "已禁用 root 密码登录" "info"
fi

# 禁用密码认证 (可选，需要确保有密钥)
read -p "是否禁用密码认证 (仅允许密钥登录)? (y/N): " disable_password
if [[ "$disable_password" =~ ^[Yy]$ ]]; then
    if [ -f "$HOME/.ssh/authorized_keys" ] && [ -s "$HOME/.ssh/authorized_keys" ]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        log "已禁用密码认证" "info"
    else
        log "警告: 未找到 SSH 密钥，不建议禁用密码认证" "warn"
        log "请先配置 SSH 密钥后再禁用密码认证" "warn"
    fi
fi

# 其他安全设置
cat >> /etc/ssh/sshd_config << 'EOF'

# 安全配置
Protocol 2
MaxAuthTries 3
ClientAliveInterval 600
ClientAliveCountMax 3
LoginGraceTime 60
EOF

# 验证配置并重启
log "验证 SSH 配置..." "info"
if sshd -t; then
    systemctl reload sshd
    log "SSH 安全配置已应用" "info"
else
    log "SSH 配置验证失败，恢复备份" "error"
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    systemctl reload sshd
    exit 1
fi

# 显示当前配置
FINAL_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$FINAL_PORT" ] && FINAL_PORT="22"

log "SSH 安全配置完成" "info"
log "当前 SSH 端口: $FINAL_PORT" "info"

exit 0
