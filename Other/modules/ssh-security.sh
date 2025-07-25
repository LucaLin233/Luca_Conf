#!/bin/bash
# SSH 安全配置模块 v2.1.0 (优化版)
# 功能: SSH端口配置, 密钥认证, 安全加固, 防火墙集成
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="ssh-security"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
SSH_BACKUP_DIR="/var/backups/ssh-security"
SSH_KEY_DIR="/root/.ssh"
FAIL2BAN_CONFIG_DIR="/etc/fail2ban"
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
    
    # 检查SSH服务是否存在
    if ! systemctl list-unit-files | grep -q "ssh.service\|sshd.service"; then
        log "SSH服务未安装" "error"
        return 1
    fi
    
    # 检查SSH配置文件
    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        log "SSH配置文件不存在: $SSH_CONFIG_FILE" "error"
        return 1
    fi
    
    # 检查必要命令
    local required_commands=("sshd" "ssh-keygen" "ss" "netstat")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            return 1
        fi
        debug_log "命令检查通过: $cmd"
    done
    
    # 检查是否为root用户
    if [ "$(id -u)" != "0" ]; then
        log "此模块需要root权限执行" "error"
        return 1
    fi
    
    # 创建备份目录
    mkdir -p "$SSH_BACKUP_DIR" "$SSH_KEY_DIR"
    
    return 0
}
# 备份SSH配置
backup_ssh_config() {
    log "备份SSH配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$SSH_BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份SSH相关文件
    local backup_files=(
        "$SSH_CONFIG_FILE"
        "/etc/ssh/ssh_config"
        "$SSH_KEY_DIR"
        "/etc/hosts.allow"
        "/etc/hosts.deny"
    )
    
    for file in "${backup_files[@]}"; do
        if [ -e "$file" ]; then
            cp -r "$file" "$backup_path/" 2>/dev/null || true
            debug_log "已备份: $file"
        fi
    done
    
    # 记录当前SSH状态
    {
        echo "=== SSH安全配置前状态 ==="
        echo "时间: $(date)"
        echo "SSH服务状态: $(systemctl is-active ssh.service 2>/dev/null || systemctl is-active sshd.service 2>/dev/null || echo "未知")"
        echo ""
        echo "=== 当前SSH配置摘要 ==="
        grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" "$SSH_CONFIG_FILE" 2>/dev/null || echo "配置获取失败"
        echo ""
        echo "=== 当前连接状态 ==="
        ss -tuln | grep ":22\|:2222" || echo "无SSH端口监听"
        echo ""
        echo "=== 认证密钥 ==="
        if [ -f "$SSH_KEY_DIR/authorized_keys" ]; then
            echo "authorized_keys行数: $(wc -l < "$SSH_KEY_DIR/authorized_keys")"
        else
            echo "未找到authorized_keys文件"
        fi
    } > "$backup_path/ssh_status_before.txt"
    
    # 清理旧备份 (保留最近10个)
    find "$SSH_BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +11 | xargs rm -rf 2>/dev/null || true
    
    # 创建专用备份文件
    if [ ! -f "${SSH_CONFIG_FILE}.backup.original" ]; then
        cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.backup.original"
        debug_log "已创建原始配置备份"
    fi
    
    cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.backup.$backup_timestamp"
    export SSH_BACKUP_FILE="${SSH_CONFIG_FILE}.backup.$backup_timestamp"
    
    debug_log "SSH配置备份完成: $backup_path"
}
# 检查SSH服务状态
check_ssh_service_status() {
    log "检查SSH服务状态..." "info"
    
    # 确定SSH服务名称
    local ssh_service=""
    if systemctl list-unit-files | grep -q "sshd.service"; then
        ssh_service="sshd.service"
    elif systemctl list-unit-files | grep -q "ssh.service"; then
        ssh_service="ssh.service"
    else
        log "无法确定SSH服务名称" "error"
        return 1
    fi
    
    export SSH_SERVICE_NAME="$ssh_service"
    
    # 检查服务状态
    if systemctl is-active "$ssh_service" &>/dev/null; then
        log "SSH服务运行正常: $ssh_service" "info"
    else
        log "SSH服务未运行，尝试启动..." "warn"
        if systemctl start "$ssh_service"; then
            log "SSH服务启动成功" "success"
        else
            log "SSH服务启动失败" "error"
            return 1
        fi
    fi
    
    # 检查服务是否开机自启
    if ! systemctl is-enabled "$ssh_service" &>/dev/null; then
        log "启用SSH服务开机自启..." "info"
        systemctl enable "$ssh_service"
    fi
    
    return 0
}
# 分析当前SSH配置
analyze_current_ssh_config() {
    log "分析当前SSH配置..." "info"
    
    # 获取当前配置
    local current_port=$(grep "^Port " "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    [ -z "$current_port" ] && current_port="22"
    
    local permit_root=$(grep "^PermitRootLogin" "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    [ -z "$permit_root" ] && permit_root="yes"  # 默认值
    
    local password_auth=$(grep "^PasswordAuthentication" "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    [ -z "$password_auth" ] && password_auth="yes"  # 默认值
    
    local pubkey_auth=$(grep "^PubkeyAuthentication" "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    [ -z "$pubkey_auth" ] && pubkey_auth="yes"  # 默认值
    
    # 导出配置供其他函数使用
    export CURRENT_SSH_PORT="$current_port"
    export CURRENT_PERMIT_ROOT="$permit_root"
    export CURRENT_PASSWORD_AUTH="$password_auth"
    export CURRENT_PUBKEY_AUTH="$pubkey_auth"
    
    # 显示当前配置
    log "当前SSH配置分析:" "info"
    log "  • SSH端口: $current_port" "info"
    log "  • Root登录: $permit_root" "info"
    log "  • 密码认证: $password_auth" "info"
    log "  • 密钥认证: $pubkey_auth" "info"
    
    # 检查密钥文件
    if [ -f "$SSH_KEY_DIR/authorized_keys" ] && [ -s "$SSH_KEY_DIR/authorized_keys" ]; then
        local key_count=$(wc -l < "$SSH_KEY_DIR/authorized_keys")
        log "  • 授权密钥: $key_count 个" "info"
        export HAS_SSH_KEYS=true
    else
        log "  • 授权密钥: 未配置" "warn"
        export HAS_SSH_KEYS=false
    fi
    
    # 安全风险评估
    assess_security_risks
}
assess_security_risks() {
    log "SSH安全风险评估:" "info"
    
    local risk_level=0
    local risks=()
    
    # 检查默认端口
    if [ "$CURRENT_SSH_PORT" = "22" ]; then
        risks+=("使用默认SSH端口22，容易被扫描攻击")
        ((risk_level++))
    fi
    
    # 检查root登录
    if [ "$CURRENT_PERMIT_ROOT" = "yes" ]; then
        risks+=("允许root用户直接登录，安全风险高")
        ((risk_level += 2))
    fi
    
    # 检查密码认证
    if [ "$CURRENT_PASSWORD_AUTH" = "yes" ]; then
        if [ "$HAS_SSH_KEYS" = false ]; then
            risks+=("仅依赖密码认证，建议配置SSH密钥")
            ((risk_level++))
        else
            risks+=("密码认证已启用，建议仅使用密钥认证")
            ((risk_level++))
        fi
    fi
    
    # 检查密钥认证
    if [ "$CURRENT_PUBKEY_AUTH" != "yes" ]; then
        risks+=("密钥认证未启用，建议启用")
        ((risk_level++))
    fi
    
    # 显示风险评估结果
    if [ ${#risks[@]} -gt 0 ]; then
        log "发现以下安全风险:" "warn"
        for risk in "${risks[@]}"; do
            log "  ⚠️  $risk" "warn"
        done
    else
        log "当前SSH配置安全性良好" "success"
    fi
    
    export SSH_RISK_LEVEL="$risk_level"
    export SSH_RISKS=("${risks[@]}")
}
# 端口可用性检查
check_port_availability() {
    local port="$1"
    
    # 检查端口范围
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        debug_log "端口 $port 超出有效范围"
        return 1
    fi
    
    # 检查端口是否被占用
    if ss -tuln | grep -q ":$port\b"; then
        debug_log "端口 $port 已被占用"
        return 1
    fi
    
    # 检查是否为保留端口
    local reserved_ports=(80 443 25 53 110 143 993 995)
    for reserved in "${reserved_ports[@]}"; do
        if [ "$port" -eq "$reserved" ]; then
            debug_log "端口 $port 为系统保留端口"
            return 1
        fi
    done
    
    debug_log "端口 $port 可用"
    return 0
}
# 生成安全的SSH端口建议
suggest_secure_ports() {
    local suggested_ports=()
    local port_ranges=(
        "2222 2299"
        "8022 8099" 
        "9022 9099"
        "10022 10099"
        "22222 22299"
    )
    
    for range in "${port_ranges[@]}"; do
        local start=$(echo "$range" | awk '{print $1}')
        local end=$(echo "$range" | awk '{print $2}')
        
        for ((port=start; port<=end; port++)); do
            if check_port_availability "$port"; then
                suggested_ports+=("$port")
                [ ${#suggested_ports[@]} -ge 5 ] && break 2
            fi
        done
    done
    
    echo "${suggested_ports[@]}"
}
# --- SSH端口配置优化 ---
configure_ssh_port() {
    log "配置SSH端口..." "info"
    
    local new_port=""
    local change_port=false
    
    # 显示当前端口和风险提示
    log "当前SSH端口: $CURRENT_SSH_PORT" "info"
    
    if [ "$CURRENT_SSH_PORT" = "22" ]; then
        log "建议更改默认端口22以提高安全性" "warn"
    fi
    
    # 批量模式处理
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        if [ "${AUTO_CHANGE_SSH_PORT:-false}" = "true" ]; then
            local suggested_ports=($(suggest_secure_ports))
            if [ ${#suggested_ports[@]} -gt 0 ]; then
                new_port="${suggested_ports[0]}"
                change_port=true
                log "批量模式: 自动选择端口 $new_port" "info"
            fi
        else
            log "批量模式: 保持当前端口" "info"
        fi
    else
        # 交互模式
        display_port_options
        if get_user_port_choice; then
            change_port=true
        fi
    fi
    
    # 执行端口更改
    if [ "$change_port" = true ] && [ -n "$new_port" ]; then
        if apply_ssh_port_change "$new_port"; then
            export NEW_SSH_PORT="$new_port"
            return 0
        else
            return 1
        fi
    else
        log "保持当前SSH端口: $CURRENT_SSH_PORT" "info"
        export NEW_SSH_PORT="$CURRENT_SSH_PORT"
        return 0
    fi
}
display_port_options() {
    log "SSH端口配置选项:" "info"
    log "  1. 保持当前端口 ($CURRENT_SSH_PORT)" "info"
    log "  2. 使用推荐端口" "info"
    log "  3. 自定义端口" "info"
    
    # 显示推荐端口
    local suggested_ports=($(suggest_secure_ports))
    if [ ${#suggested_ports[@]} -gt 0 ]; then
        log "推荐的可用端口: ${suggested_ports[*]}" "info"
    else
        log "未找到推荐端口，请自定义" "warn"
    fi
}
get_user_port_choice() {
    while true; do
        read -p "请选择 (1-3) 或直接输入端口号: " choice
        
        case "$choice" in
            1)
                log "保持当前端口" "info"
                return 1
                ;;
            2)
                local suggested_ports=($(suggest_secure_ports))
                if [ ${#suggested_ports[@]} -gt 0 ]; then
                    new_port="${suggested_ports[0]}"
                    log "选择推荐端口: $new_port" "info"
                    return 0
                else
                    log "没有可用的推荐端口" "error"
                    continue
                fi
                ;;
            3)
                read -p "请输入自定义端口 (1024-65535): " custom_port
                if validate_port_input "$custom_port"; then
                    new_port="$custom_port"
                    return 0
                else
                    continue
                fi
                ;;
            *)
                # 直接输入端口号
                if validate_port_input "$choice"; then
                    new_port="$choice"
                    return 0
                else
                    log "无效选择，请重新输入" "error"
                    continue
                fi
                ;;
        esac
    done
}
validate_port_input() {
    local port="$1"
    
    # 检查是否为数字
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log "端口号必须为数字" "error"
        return 1
    fi
    
    # 检查端口范围
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        log "端口号必须在 1024-65535 范围内" "error"
        return 1
    fi
    
    # 检查端口可用性
    if ! check_port_availability "$port"; then
        log "端口 $port 不可用（已被占用或为保留端口）" "error"
        return 1
    fi
    
    return 0
}
apply_ssh_port_change() {
    local new_port="$1"
    
    log "更改SSH端口到 $new_port..." "info"
    
    # 创建临时配置文件
    local temp_config=$(mktemp)
    cp "$SSH_CONFIG_FILE" "$temp_config"
    
    # 移除现有Port配置
    sed -i '/^Port /d' "$temp_config"
    sed -i '/^#Port /d' "$temp_config"
    
    # 在配置文件开头添加新端口
    sed -i "1i Port $new_port" "$temp_config"
    
    # 验证配置文件
    if ! sshd -t -f "$temp_config"; then
        log "SSH配置验证失败" "error"
        rm -f "$temp_config"
        return 1
    fi
    
    # 应用配置
    mv "$temp_config" "$SSH_CONFIG_FILE"
    
    # 重启SSH服务
    log "重启SSH服务..." "info"
    if systemctl restart "$SSH_SERVICE_NAME"; then
        # 验证服务是否在新端口监听
        sleep 3
        if ss -tuln | grep -q ":$new_port\b"; then
            log "SSH端口已成功更改为 $new_port" "success"
            log "⚠️  重要提示:" "warn"
            log "   • 请确保防火墙允许端口 $new_port" "warn"
            log "   • 新连接命令: ssh -p $new_port user@server" "warn"
            log "   • 请在新终端测试连接后再关闭当前会话" "warn"
            
            # 检查防火墙状态
            check_and_suggest_firewall_config "$new_port"
            
            return 0
        else
            log "SSH服务重启后端口验证失败" "error"
            restore_ssh_config
            return 1
        fi
    else
        log "SSH服务重启失败" "error"
        restore_ssh_config
        return 1
    fi
}
check_and_suggest_firewall_config() {
    local port="$1"
    
    # 检查ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log "检测到UFW防火墙，建议执行以下命令:" "info"
        log "   sudo ufw allow $port/tcp" "info"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否自动配置UFW防火墙规则? (y/N): " config_ufw
            if [[ "$config_ufw" =~ ^[Yy]$ ]]; then
                if ufw allow "$port/tcp" 2>/dev/null; then
                    log "UFW防火墙规则配置成功" "success"
                else
                    log "UFW防火墙规则配置失败" "warn"
                fi
            fi
        fi
    fi
    
    # 检查iptables
    if command -v iptables &>/dev/null && iptables -L INPUT | grep -q "ACCEPT\|DROP\|REJECT"; then
        log "检测到iptables规则，请手动添加以下规则:" "info"
        log "   iptables -A INPUT -p tcp --dport $port -j ACCEPT" "info"
    fi
    
    # 检查fail2ban
    if [ -d "$FAIL2BAN_CONFIG_DIR" ]; then
        log "检测到fail2ban，建议更新SSH监控端口配置" "info"
    fi
}
restore_ssh_config() {
    log "恢复SSH配置..." "warn"
    
    if [ -n "${SSH_BACKUP_FILE:-}" ] && [ -f "$SSH_BACKUP_FILE" ]; then
        cp "$SSH_BACKUP_FILE" "$SSH_CONFIG_FILE"
        if systemctl restart "$SSH_SERVICE_NAME"; then
            log "SSH配置已恢复" "info"
        else
            log "SSH服务恢复失败" "error"
        fi
    else
        log "备份文件不存在，无法自动恢复" "error"
    fi
}
# --- SSH密钥管理 ---
manage_ssh_keys() {
    log "配置SSH密钥认证..." "info"
    
    # 检查现有密钥
    analyze_existing_keys
    
    # 根据情况决定操作
    if [ "$HAS_SSH_KEYS" = false ]; then
        log "未检测到SSH密钥，建议生成新密钥" "warn"
        offer_key_generation
    else
        log "检测到现有SSH密钥" "info"
        offer_key_management
    fi
    
    # 配置密钥权限
    secure_ssh_key_permissions
}
analyze_existing_keys() {
    log "分析现有SSH密钥..." "info"
    
    local authorized_keys="$SSH_KEY_DIR/authorized_keys"
    
    if [ -f "$authorized_keys" ] && [ -s "$authorized_keys" ]; then
        local key_count=$(wc -l < "$authorized_keys")
        log "发现 $key_count 个授权密钥:" "info"
        
        # 分析密钥类型和强度
        local line_num=0
        while IFS= read -r line; do
            ((line_num++))
            if [[ "$line" =~ ^ssh- ]]; then
                local key_type=$(echo "$line" | awk '{print $1}')
                local key_comment=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
                local key_strength=""
                
                case "$key_type" in
                    "ssh-rsa")
                        # 检查RSA密钥长度
                        local key_bits=$(echo "$line" | awk '{print $2}' | base64 -d 2>/dev/null | wc -c 2>/dev/null || echo 0)
                        if [ "$key_bits" -ge 512 ]; then
                            key_strength="(4096位)"
                        elif [ "$key_bits" -ge 256 ]; then
                            key_strength="(2048位)"
                        else
                            key_strength="(位数不足)"
                        fi
                        ;;
                    "ssh-ed25519")
                        key_strength="(ED25519-高强度)"
                        ;;
                    "ssh-ecdsa")
                        key_strength="(ECDSA)"
                        ;;
                    *)
                        key_strength="(未知类型)"
                        ;;
                esac
                
                log "  • 密钥 $line_num: $key_type $key_strength" "info"
                [ -n "$key_comment" ] && log "    备注: $key_comment" "info"
            fi
        done < "$authorized_keys"
        
        export HAS_SSH_KEYS=true
    else
        log "未找到有效的授权密钥文件" "warn"
        export HAS_SSH_KEYS=false
    fi
}
offer_key_generation() {
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        if [ "${AUTO_GENERATE_SSH_KEY:-false}" = "true" ]; then
            generate_ssh_key_pair
        else
            log "批量模式: 跳过SSH密钥生成" "info"
        fi
    else
        read -p "是否生成新的SSH密钥对? (y/N): " generate_key
        if [[ "$generate_key" =~ ^[Yy]$ ]]; then
            generate_ssh_key_pair
        fi
    fi
}
offer_key_management() {
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        log "批量模式: 保持现有密钥配置" "info"
        return 0
    fi
    
    log "SSH密钥管理选项:" "info"
    log "  1. 保持现有密钥" "info"
    log "  2. 添加新密钥" "info"
    log "  3. 生成新密钥对" "info"
    log "  4. 查看密钥详情" "info"
    
    read -p "请选择 (1-4): " key_choice
    
    case "$key_choice" in
        1)
            log "保持现有密钥配置" "info"
            ;;
        2)
            add_ssh_key_interactive
            ;;
        3)
            generate_ssh_key_pair
            ;;
        4)
            show_key_details
            ;;
        *)
            log "无效选择，保持现有配置" "warn"
            ;;
    esac
}
generate_ssh_key_pair() {
    log "生成SSH密钥对..." "info"
    
    # 选择密钥类型
    local key_type="ed25519"  # 默认使用最安全的类型
    local key_file="$SSH_KEY_DIR/id_ed25519"
    local comment="root@$(hostname)-$(date +%Y%m%d)"
    
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "选择密钥类型:" "info"
        log "  1. ED25519 (推荐，最安全)" "info"
        log "  2. RSA 4096位" "info"
        log "  3. ECDSA" "info"
        
        read -p "请选择 (1-3, 默认1): " type_choice
        
        case "${type_choice:-1}" in
            1)
                key_type="ed25519"
                key_file="$SSH_KEY_DIR/id_ed25519"
                ;;
            2)
                key_type="rsa"
                key_file="$SSH_KEY_DIR/id_rsa"
                ;;
            3)
                key_type="ecdsa"
                key_file="$SSH_KEY_DIR/id_ecdsa"
                ;;
            *)
                log "使用默认类型: ED25519" "info"
                ;;
        esac
        
        read -p "输入密钥备注 (默认: $comment): " user_comment
        [ -n "$user_comment" ] && comment="$user_comment"
    fi
    
    # 检查是否存在同类型密钥
    if [ -f "$key_file" ]; then
        log "警告: 密钥文件已存在: $key_file" "warn"
        
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否覆盖现有密钥? (y/N): " overwrite
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                log "取消密钥生成" "info"
                return 0
            fi
        else
            log "批量模式: 跳过密钥生成（文件已存在）" "info"
            return 0
        fi
    fi
    
    # 生成密钥
    local ssh_keygen_opts=""
    case "$key_type" in
        "ed25519")
            ssh_keygen_opts="-t ed25519 -a 100"
            ;;
        "rsa")
            ssh_keygen_opts="-t rsa -b 4096 -a 100"
            ;;
        "ecdsa")
            ssh_keygen_opts="-t ecdsa -b 521"
            ;;
    esac
    
    log "生成 $key_type 密钥..." "info"
    if ssh-keygen $ssh_keygen_opts -f "$key_file" -C "$comment" -N "" 2>/dev/null; then
        log "密钥对生成成功:" "success"
        log "  • 私钥: $key_file" "info"
        log "  • 公钥: ${key_file}.pub" "info"
        
        # 自动添加公钥到authorized_keys
        if add_public_key_to_authorized "${key_file}.pub"; then
            log "公钥已添加到authorized_keys" "success"
        fi
        
        # 显示公钥内容
        log "公钥内容:" "info"
        cat "${key_file}.pub" | while IFS= read -r line; do
            log "  $line" "info"
        done
        
    else
        log "密钥生成失败" "error"
        return 1
    fi
}
add_ssh_key_interactive() {
    log "添加SSH公钥..." "info"
    log "请粘贴SSH公钥内容 (以ssh-开头的完整行):"
    log "输入完成后按Enter，然后输入空行结束:"
    
    local temp_key_file=$(mktemp)
    local line_count=0
    
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            break
        fi
        
        echo "$line" >> "$temp_key_file"
        ((line_count++))
    done
    
    if [ $line_count -eq 0 ]; then
        log "未输入任何内容" "warn"
        rm -f "$temp_key_file"
        return 1
    fi
    
    # 验证公钥格式
    if validate_ssh_public_key "$temp_key_file"; then
        if add_public_key_to_authorized "$temp_key_file"; then
            log "SSH公钥添加成功" "success"
        else
            log "SSH公钥添加失败" "error"
        fi
    else
        log "SSH公钥格式无效" "error"
    fi
    
    rm -f "$temp_key_file"
}
validate_ssh_public_key() {
    local key_file="$1"
    
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^ssh- ]]; then
            debug_log "无效的公钥格式: $line"
            return 1
        fi
        
        # 尝试解析公钥
        if ! ssh-keygen -l -f <(echo "$line") &>/dev/null; then
            debug_log "公钥解析失败: $line"
            return 1
        fi
    done < "$key_file"
    
    return 0
}
add_public_key_to_authorized() {
    local key_file="$1"
    local authorized_keys="$SSH_KEY_DIR/authorized_keys"
    
    # 创建authorized_keys文件（如果不存在）
    touch "$authorized_keys"
    
    # 检查重复
    while IFS= read -r line; do
        if grep -Fq "$line" "$authorized_keys"; then
            log "公钥已存在，跳过添加" "warn"
            continue
        fi
        
        echo "$line" >> "$authorized_keys"
        debug_log "公钥已添加: $(echo "$line" | awk '{print $1, substr($2,1,20)"..."}')"
    done < "$key_file"
    
    return 0
}
show_key_details() {
    local authorized_keys="$SSH_KEY_DIR/authorized_keys"
    
    if [ ! -f "$authorized_keys" ] || [ ! -s "$authorized_keys" ]; then
        log "未找到授权密钥" "warn"
        return 1
    fi
    
    log "SSH密钥详细信息:" "info"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        
        if [[ "$line" =~ ^ssh- ]]; then
            log "密钥 #$line_num:" "info"
            
            # 获取密钥指纹
            local fingerprint=$(ssh-keygen -l -f <(echo "$line") 2>/dev/null | awk '{print $2}' || echo "获取失败")
            log "  • 指纹: $fingerprint" "info"
            
            # 获取密钥类型和大小
            local key_info=$(ssh-keygen -l -f <(echo "$line") 2>/dev/null | awk '{print $1, $4}' || echo "未知")
            log "  • 信息: $key_info" "info"
            
            # 获取备注
            local comment=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
            [ -n "$comment" ] && log "  • 备注: $comment" "info"
            
            log "" "info"
        fi
    done < "$authorized_keys"
}
secure_ssh_key_permissions() {
    log "设置SSH密钥文件权限..." "info"
    
    # 设置.ssh目录权限
    chmod 700 "$SSH_KEY_DIR"
    
    # 设置authorized_keys权限
    if [ -f "$SSH_KEY_DIR/authorized_keys" ]; then
        chmod 600 "$SSH_KEY_DIR/authorized_keys"
        debug_log "authorized_keys权限已设置为600"
    fi
    
    # 设置私钥权限
    find "$SSH_KEY_DIR" -name "id_*" -not -name "*.pub" -exec chmod 600 {} \;
    
    # 设置公钥权限
    find "$SSH_KEY_DIR" -name "*.pub" -exec chmod 644 {} \;
    
    # 确保所有者为root
    chown -R root:root "$SSH_KEY_DIR"
    
    debug_log "SSH密钥权限设置完成"
}
# --- SSH安全配置优化 ---
configure_ssh_security_settings() {
    log "配置SSH安全参数..." "info"
    
    # 创建安全配置
    create_secure_ssh_config
    
    # 配置认证设置
    configure_authentication_settings
    
    # 应用高级安全配置
    apply_advanced_security_config
    
    # 验证配置
    validate_ssh_configuration
}
create_secure_ssh_config() {
    log "生成安全SSH配置..." "info"
    
    # 创建临时配置文件
    local temp_config=$(mktemp)
    
    # 基础配置（保留现有的Port设置）
    cat > "$temp_config" << EOF
# SSH安全配置 v2.1.0 - 生成时间: $(date)
$(grep "^Port " "$SSH_CONFIG_FILE" 2>/dev/null || echo "Port 22")
# === 协议和加密配置 ===
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
# 强化密钥交换算法
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
# 强化加密算法
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
# 强化MAC算法
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512
# === 认证配置 ===
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication $([ "$HAS_SSH_KEYS" = "true" ] && echo "no" || echo "yes")
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
# === 连接和会话配置 ===
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:60
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive yes
# === 访问控制 ===
PermitRootLogin $([ "$HAS_SSH_KEYS" = "true" ] && echo "prohibit-password" || echo "yes")
AllowUsers root
DenyUsers guest
# === 安全特性 ===
StrictModes yes
IgnoreRhosts yes
HostbasedAuthentication no
PermitUserEnvironment no
Compression delayed
UseDNS no
# === X11和端口转发 ===
X11Forwarding no
X11DisplayOffset 10
X11UseLocalhost yes
PermitTunnel no
AllowTcpForwarding local
AllowStreamLocalForwarding no
GatewayPorts no
# === 日志配置 ===
SyslogFacility AUTHPRIV
LogLevel VERBOSE
# === 其他安全设置 ===
PrintMotd no
PrintLastLog yes
Banner none
DebianBanner no
EOF
    
    # 添加自定义配置（如果存在）
    add_custom_ssh_config "$temp_config"
    
    export TEMP_SSH_CONFIG="$temp_config"
    debug_log "安全SSH配置已生成"
}
add_custom_ssh_config() {
    local config_file="$1"
    
    # 检查是否有自定义配置需要保留
    local custom_settings=(
        "AllowUsers"
        "DenyUsers"
        "AllowGroups"
        "DenyGroups"
        "Match"
        "Subsystem"
    )
    
    echo "" >> "$config_file"
    echo "# === 自定义配置 ===" >> "$config_file"
    
    for setting in "${custom_settings[@]}"; do
        if grep -q "^$setting" "$SSH_CONFIG_FILE"; then
            grep "^$setting" "$SSH_CONFIG_FILE" >> "$config_file"
            debug_log "保留自定义配置: $setting"
        fi
    done
    
    # 添加Subsystem配置（SFTP支持）
    if ! grep -q "^Subsystem" "$config_file"; then
        echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> "$config_file"
    fi
}
configure_authentication_settings() {
    log "配置认证设置..." "info"
    
    local auth_config=""
    
    if [ "$HAS_SSH_KEYS" = "true" ]; then
        log "检测到SSH密钥，启用强安全模式" "info"
        auth_config="强安全模式（仅密钥认证）"
        
        # 在配置中禁用密码认证
        sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$TEMP_SSH_CONFIG"
        sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' "$TEMP_SSH_CONFIG"
        
    else
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            log "未检测到SSH密钥，当前将保持密码认证" "warn"
            log "强烈建议配置SSH密钥后禁用密码认证" "warn"
            
            read -p "是否现在强制禁用密码认证? (不推荐，可能锁定系统) (y/N): " force_disable
            if [[ "$force_disable" =~ ^[Yy]$ ]]; then
                log "警告: 强制禁用密码认证，请确保有其他访问方式" "warn"
                sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$TEMP_SSH_CONFIG"
                auth_config="强制禁用密码（高风险）"
            else
                auth_config="密码认证已保留"
            fi
        else
            log "批量模式: 保留密码认证（未配置密钥）" "info"
            auth_config="密码认证已保留"
        fi
    fi
    
    export AUTH_CONFIG_MODE="$auth_config"
}
apply_advanced_security_config() {
    log "应用高级安全配置..." "info"
    
    # 检查SSH版本兼容性
    local ssh_version=$(sshd -V 2>&1 | head -1 | awk '{print $1}' | cut -d'_' -f2)
    debug_log "SSH版本: $ssh_version"
    
    # 根据SSH版本调整配置
    adjust_config_for_ssh_version "$ssh_version"
    
    # 配置SSH证书认证（如果支持）
    configure_ssh_certificates
    
    # 配置连接限制
    configure_connection_limits
}
adjust_config_for_ssh_version() {
    local version="$1"
    
    # 提取主版本号
    local major_version=$(echo "$version" | cut -d'.' -f1)
    local minor_version=$(echo "$version" | cut -d'.' -f2)
    
    if [ "$major_version" -lt 7 ]; then
        log "检测到较旧的SSH版本，调整配置兼容性" "warn"
        
        # 移除新版本特有的配置
        sed -i '/KexAlgorithms.*curve25519/d' "$TEMP_SSH_CONFIG"
        sed -i '/Ciphers.*chacha20/d' "$TEMP_SSH_CONFIG"
        sed -i '/MACs.*etm/d' "$TEMP_SSH_CONFIG"
        
        debug_log "已调整SSH配置以兼容版本 $version"
    fi
}
configure_ssh_certificates() {
    local cert_dir="/etc/ssh/certificates"
    
    # 检查是否支持证书认证
    if sshd -T 2>/dev/null | grep -q "trustedusercakeys"; then
        debug_log "SSH支持证书认证"
        
        # 创建证书目录
        mkdir -p "$cert_dir"
        chmod 755 "$cert_dir"
        
        # 添加证书配置（如果有证书文件）
        if [ -f "$cert_dir/user_ca.pub" ]; then
            echo "TrustedUserCAKeys $cert_dir/user_ca.pub" >> "$TEMP_SSH_CONFIG"
            debug_log "已启用用户证书认证"
        fi
        
        if [ -f "$cert_dir/host_ca.pub" ]; then
            echo "HostCertificate $cert_dir/ssh_host_rsa_key-cert.pub" >> "$TEMP_SSH_CONFIG"
            debug_log "已启用主机证书认证"
        fi
    fi
}
configure_connection_limits() {
    log "配置连接限制..." "info"
    
    # 根据系统资源调整连接限制
    local total_mem_mb=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
    local max_sessions max_startups
    
    if [ "$total_mem_mb" -ge 4096 ]; then
        max_sessions=20
        max_startups="20:50:100"
    elif [ "$total_mem_mb" -ge 2048 ]; then
        max_sessions=15
        max_startups="15:40:80"
    else
        max_sessions=10
        max_startups="10:30:60"
    fi
    
    # 更新配置文件中的限制
    sed -i "s/^MaxSessions.*/MaxSessions $max_sessions/" "$TEMP_SSH_CONFIG"
    sed -i "s/^MaxStartups.*/MaxStartups $max_startups/" "$TEMP_SSH_CONFIG"
    
    debug_log "连接限制: MaxSessions=$max_sessions, MaxStartups=$max_startups"
}
validate_ssh_configuration() {
    log "验证SSH配置..." "info"
    
    # 语法检查
    if ! sshd -t -f "$TEMP_SSH_CONFIG"; then
        log "SSH配置语法验证失败" "error"
        debug_log "配置内容: $(head -20 "$TEMP_SSH_CONFIG")"
        return 1
    fi
    
    # 应用配置
    cp "$TEMP_SSH_CONFIG" "$SSH_CONFIG_FILE"
    rm -f "$TEMP_SSH_CONFIG"
    
    # 重启SSH服务
    log "重新加载SSH配置..." "info"
    if systemctl reload "$SSH_SERVICE_NAME"; then
        log "SSH配置验证通过并已应用" "success"
        return 0
    else
        log "SSH服务重新加载失败" "error"
        restore_ssh_config
        return 1
    fi
}
# --- Fail2ban集成 ---
configure_fail2ban() {
    log "配置Fail2ban入侵防护..." "info"
    
    # 检查fail2ban是否可用
    if ! check_fail2ban_availability; then
        offer_fail2ban_installation
        return $?
    fi
    
    # 配置fail2ban规则
    configure_fail2ban_ssh_jail
    
    # 启动fail2ban服务
    enable_fail2ban_service
}
check_fail2ban_availability() {
    if command -v fail2ban-server &>/dev/null; then
        debug_log "fail2ban已安装"
        return 0
    else
        debug_log "fail2ban未安装"
        return 1
    fi
}
offer_fail2ban_installation() {
    if [ "${BATCH_MODE:-false}" = "true" ]; then
        if [ "${AUTO_INSTALL_FAIL2BAN:-false}" = "true" ]; then
            install_fail2ban
        else
            log "批量模式: 跳过fail2ban安装" "info"
        fi
    else
        log "Fail2ban可以防护SSH暴力破解攻击" "info"
        read -p "是否安装fail2ban? (Y/n): " install_f2b
        if [[ ! "$install_f2b" =~ ^[Nn]$ ]]; then
            install_fail2ban
        fi
    fi
}
install_fail2ban() {
    log "安装fail2ban..." "info"
    
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
       DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban; then
        log "fail2ban安装成功" "success"
        configure_fail2ban_ssh_jail
        enable_fail2ban_service
    else
        log "fail2ban安装失败" "error"
        return 1
    fi
}
configure_fail2ban_ssh_jail() {
    log "配置fail2ban SSH监狱..." "info"
    
    local jail_local="$FAIL2BAN_CONFIG_DIR/jail.local"
    local ssh_port="${NEW_SSH_PORT:-$CURRENT_SSH_PORT}"
    
    # 创建jail.local配置
    cat > "$jail_local" << EOF
# Fail2ban SSH配置 - 生成时间: $(date)
[DEFAULT]
# 默认配置
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd
# 邮件通知（如果配置了邮件）
destemail = root@localhost
sendername = Fail2Ban
mta = sendmail
# 白名单IP（请根据需要修改）
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
# SSH暴力破解防护
[sshd-ddos]
enabled = true
port = $ssh_port
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 6
bantime = 600
findtime = 120
EOF
    
    # 如果SSH端口不是22，创建自定义过滤器
    if [ "$ssh_port" != "22" ]; then
        create_custom_ssh_filter "$ssh_port"
    fi
    
    debug_log "fail2ban配置已创建: $jail_local"
}
create_custom_ssh_filter() {
    local port="$1"
    local filter_dir="$FAIL2BAN_CONFIG_DIR/filter.d"
    local custom_filter="$filter_dir/sshd-custom.conf"
    
    mkdir -p "$filter_dir"
    
    cat > "$custom_filter" << EOF
# 自定义SSH过滤器 - 端口 $port
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error|failed) for .* from <HOST>( via \S+)?\s*$
            ^%(__prefix_line)s(?:error: )?Received disconnect from <HOST>: 3: .*: Auth fail
            ^%(__prefix_line)sFailed (?:password|publickey) for .* from <HOST>(?: port $port)?(?: ssh\d*)?(?: on \S+)?\s*$
            ^%(__prefix_line)sROOT LOGIN REFUSED.* FROM <HOST>
            ^%(__prefix_line)s[iI](?:llegal|nvalid) user .* from <HOST>
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers
            ^%(__prefix_line)sConnection from <HOST> port \d+ rejected
ignoreregex = 
EOF
    
    debug_log "自定义SSH过滤器已创建: $custom_filter"
}
enable_fail2ban_service() {
    log "启用fail2ban服务..." "info"
    
    if systemctl enable fail2ban && systemctl start fail2ban; then
        log "fail2ban服务已启动" "success"
        
        # 检查服务状态
        sleep 3
        if systemctl is-active fail2ban &>/dev/null; then
            log "fail2ban运行状态正常" "success"
            
            # 显示当前监狱状态
            if command -v fail2ban-client &>/dev/null; then
                local jail_status=$(fail2ban-client status 2>/dev/null || echo "状态获取失败")
                debug_log "fail2ban状态: $jail_status"
            fi
        else
            log "fail2ban服务状态异常" "warn"
        fi
    else
        log "fail2ban服务启动失败" "error"
        return 1
    fi
}
# --- SSH安全状态验证 ---
verify_ssh_security() {
    log "验证SSH安全配置..." "info"
    
    local verification_passed=true
    local issues=()
    
    # 验证SSH服务状态
    if ! systemctl is-active "$SSH_SERVICE_NAME" &>/dev/null; then
        issues+=("SSH服务未运行")
        verification_passed=false
    fi
    
    # 验证端口监听
    local ssh_port="${NEW_SSH_PORT:-$CURRENT_SSH_PORT}"
    if ! ss -tuln | grep -q ":$ssh_port\b"; then
        issues+=("SSH端口 $ssh_port 未监听")
        verification_passed=false
    fi
    
    # 验证配置参数
    local config_checks=(
        "PasswordAuthentication:$([ "$HAS_SSH_KEYS" = "true" ] && echo "no" || echo "yes")"
        "PermitRootLogin:$([ "$HAS_SSH_KEYS" = "true" ] && echo "prohibit-password" || echo "yes")"
        "PubkeyAuthentication:yes"
        "Protocol:2"
        "MaxAuthTries:3"
    )
    
    for check in "${config_checks[@]}"; do
        local param=$(echo "$check" | cut -d':' -f1)
        local expected=$(echo "$check" | cut -d':' -f2)
        local actual=$(sshd -T 2>/dev/null | grep "^$param " | awk '{print $2}' || echo "")
        
        if [ "$actual" != "$expected" ]; then
            issues+=("$param: 期望 $expected, 实际 $actual")
            verification_passed=false
        fi
    done
    
    # 验证密钥权限
    if [ -f "$SSH_KEY_DIR/authorized_keys" ]; then
        local key_perms=$(stat -c "%a" "$SSH_KEY_DIR/authorized_keys")
        if [ "$key_perms" != "600" ]; then
            issues+=("authorized_keys权限异常: $key_perms")
            verification_passed=false
        fi
    fi
    
    # 生成验证报告
    if [ "$verification_passed" = true ]; then
        log "SSH安全配置验证通过" "success"
    else
        log "SSH安全配置验证发现问题:" "warn"
        for issue in "${issues[@]}"; do
            log "  • $issue" "warn"
        done
    fi
    
    return $([ "$verification_passed" = true ] && echo 0 || echo 1)
}
# --- 生成SSH安全状态报告 ---
generate_ssh_security_report() {
    log "生成SSH安全状态报告..." "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    log "🔐 SSH安全配置状态报告" "success"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    # 基本信息
    log "📋 基本信息:" "info"
    log "  • 配置版本: v2.1.0" "info"
    log "  • 配置时间: $(date)" "info"
    log "  • SSH服务: $SSH_SERVICE_NAME" "info"
    
    # SSH配置状态
    local ssh_port="${NEW_SSH_PORT:-$CURRENT_SSH_PORT}"
    local service_status=$(systemctl is-active "$SSH_SERVICE_NAME" 2>/dev/null || echo "未知")
    
    log "🚪 连接配置:" "info"
    log "  • SSH端口: $ssh_port" "info"
    log "  • 服务状态: $service_status" "info"
    log "  • 开机自启: $(systemctl is-enabled "$SSH_SERVICE_NAME" 2>/dev/null || echo "未知")" "info"
    
    # 认证配置
    log "🔑 认证配置:" "info"
    log "  • 认证模式: ${AUTH_CONFIG_MODE:-"未配置"}" "info"
    
    if [ "$HAS_SSH_KEYS" = "true" ]; then
        local key_count=$(wc -l < "$SSH_KEY_DIR/authorized_keys" 2>/dev/null || echo 0)
        log "  • SSH密钥: $key_count 个已配置" "success"
        log "  • 密码认证: 已禁用" "success"
    else
        log "  • SSH密钥: 未配置" "warn"
        log "  • 密码认证: 已启用" "warn"
    fi
    
    # 安全特性
    log "🛡️  安全特性:" "info"
    local security_features=(
        "强化加密算法"
        "连接超时控制"
        "登录尝试限制"
        "详细日志记录"
    )
    
    for feature in "${security_features[@]}"; do
        log "  • $feature: 已启用" "success"
    done
    
    # Fail2ban状态
    if command -v fail2ban-server &>/dev/null; then
        local f2b_status=$(systemctl is-active fail2ban 2>/dev/null || echo "未运行")
        log "🚫 入侵防护:" "info"
        log "  • Fail2ban: $f2b_status" "$([ "$f2b_status" = "active" ] && echo "success" || echo "warn")"
        
        if [ "$f2b_status" = "active" ] && command -v fail2ban-client &>/dev/null; then
            local banned_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}' || echo "0")
            log "  • 当前封禁: $banned_count 个IP" "info"
        fi
    else
        log "🚫 入侵防护: 未安装fail2ban" "warn"
    fi
    
    # 配置文件位置
    log "📄 配置文件:" "info"
    log "  • SSH配置: $SSH_CONFIG_FILE" "info"
    log "  • 密钥目录: $SSH_KEY_DIR" "info"
    log "  • 配置备份: $SSH_BACKUP_DIR" "info"
    
    # 连接提示
    log "💡 连接提示:" "info"
    if [ "$ssh_port" != "22" ]; then
        log "  • 连接命令: ssh -p $ssh_port user@server" "info"
    else
        log "  • 连接命令: ssh user@server" "info"
    fi
    
    if [ "$HAS_SSH_KEYS" = "true" ]; then
        log "  • 使用密钥认证，无需密码" "info"
    else
        log "  • 需要密码认证" "info"
    fi
    
    # 安全建议
    if [ "$SSH_RISK_LEVEL" -gt 0 ] || [ "$HAS_SSH_KEYS" = "false" ]; then
        log "⚠️  安全建议:" "warn"
        
        if [ "$HAS_SSH_KEYS" = "false" ]; then
            log "  • 配置SSH密钥认证" "warn"
            log "  • 禁用密码认证" "warn"
        fi
        
        if [ "$ssh_port" = "22" ]; then
            log "  • 更改默认SSH端口" "warn"
        fi
        
        if ! command -v fail2ban-server &>/dev/null; then
            log "  • 安装fail2ban防护工具" "warn"
        fi
    else
        log "✅ 当前SSH配置安全性良好" "success"
    fi
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
}
# --- 主函数 ---
main() {
    log "开始SSH安全配置..." "info"
    
    # 1. 系统要求检查
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 2. 备份SSH配置
    backup_ssh_config
    
    # 3. 检查SSH服务状态
    if ! check_ssh_service_status; then
        log "SSH服务状态检查失败" "error"
        exit 1
    fi
    
    # 4. 分析当前配置
    analyze_current_ssh_config
    
    # 5. 配置SSH端口
    if ! configure_ssh_port; then
        log "SSH端口配置失败" "error"
        exit 1
    fi
    
    # 6. 管理SSH密钥
    manage_ssh_keys
    
    # 7. 配置SSH安全设置
    if ! configure_ssh_security_settings; then
        log "SSH安全配置失败" "error"
        exit 1
    fi
    
    # 8. 配置fail2ban（可选）
    configure_fail2ban
    
    # 9. 验证配置
    verify_ssh_security
    
    # 10. 生成状态报告
    generate_ssh_security_report
    
    log "🎉 SSH安全配置完成!" "success"
    
    # 最终提示
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        local ssh_port="${NEW_SSH_PORT:-$CURRENT_SSH_PORT}"
        
        log "💡 重要提示:" "warn"
        log "  • 请在新终端测试SSH连接后再关闭当前会话" "warn"
        log "  • 连接命令: ssh -p $ssh_port root@$(hostname -I | awk '{print $1}')" "warn"
        
        if [ "$HAS_SSH_KEYS" = "false" ]; then
            log "  • 建议尽快配置SSH密钥认证" "warn"
        fi
    fi
    
    exit 0
}
# 执行主函数
main "$@"
