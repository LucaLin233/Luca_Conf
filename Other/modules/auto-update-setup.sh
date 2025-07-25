#!/bin/bash
# 自动更新系统配置模块 (修正版)

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

UPDATE_SCRIPT="/root/auto-update.sh"

log "配置自动更新系统..." "info"

# 创建自动更新脚本
log "创建自动更新脚本..." "info"
cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动系统更新脚本 v2.0
# 功能: 更新软件包，检查新内核，必要时重启

LOGFILE="/var/log/auto-update.log"
APT_OPTIONS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::ListChanges::Frontend=none"

# 日志函数
log_update() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 清空旧日志
> "$LOGFILE"

log_update "开始自动系统更新"

# 更新软件包列表
log_update "更新软件包列表..."
if apt-get update >>"$LOGFILE" 2>&1; then
    log_update "软件包列表更新成功"
else
    log_update "软件包列表更新失败"
fi

# 升级软件包
log_update "升级系统软件包..."
if DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >>"$LOGFILE" 2>&1; then
    log_update "软件包升级完成"
else
    log_update "软件包升级失败"
    exit 1
fi

# 检查内核更新
CURRENT_KERNEL=$(uname -r)
log_update "当前运行内核: $CURRENT_KERNEL"

# 获取最新安装的内核
LATEST_KERNEL=$(dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image-[0-9]*' 2>/dev/null | \
                sort -k2 -V | tail -n1 | awk '{print $1}' | sed 's/^linux-image-//')

if [ -n "$LATEST_KERNEL" ] && [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ]; then
    log_update "检测到新内核: $LATEST_KERNEL (当前: $CURRENT_KERNEL)"
    
    # 确保 SSH 服务运行
    if ! systemctl is-active sshd >/dev/null 2>&1; then
        log_update "启动 SSH 服务..."
        systemctl start sshd
    fi
    
    log_update "系统将在 30 秒后重启以应用新内核..."
    sleep 30
    reboot
else
    log_update "内核为最新版本，无需重启"
fi

# 清理系统
log_update "清理系统..."
apt-get autoremove -y >>"$LOGFILE" 2>&1
apt-get autoclean >>"$LOGFILE" 2>&1

log_update "自动更新完成"
EOF

chmod +x "$UPDATE_SCRIPT"
log "自动更新脚本创建完成: $UPDATE_SCRIPT" "info"

# 配置 Cron 任务
log "配置 Cron 定时任务..." "info"

# 显示当前 Cron 任务
log "当前 Cron 任务列表:" "info"
if crontab -l 2>/dev/null | grep -q .; then
    crontab -l 2>/dev/null | while IFS= read -r line; do
        log "  $line" "info"
    done
else
    log "  (当前没有 Cron 任务)" "info"
fi

# 检查是否已存在相同的自动更新任务
ESCAPED_SCRIPT=$(echo "$UPDATE_SCRIPT" | sed 's/[\/&]/\\&/g')
if crontab -l 2>/dev/null | grep -q "$ESCAPED_SCRIPT"; then
    log "检测到已存在的自动更新任务" "warn"
    read -p "是否替换现有任务? (y/N): " replace_existing
    if [[ ! "$replace_existing" =~ ^[Yy]$ ]]; then
        log "保持现有 Cron 任务不变" "info"
        exit 0
    fi
fi

# 询问用户是否自定义时间
echo ""
log "配置更新时间:" "info"
log "默认: 每周日凌晨2点执行自动更新" "info"
read -p "是否自定义更新时间? (y/N): " custom_time

if [[ "$custom_time" =~ ^[Yy]$ ]]; then
    echo ""
    log "Cron 时间格式: 分 时 日 月 周" "info"
    log "示例:" "info"
    log "  0 2 * * 0  # 每周日凌晨2点" "info"
    log "  0 3 * * 1  # 每周一凌晨3点" "info"
    log "  0 1 1 * *  # 每月1号凌晨1点" "info"
    log "  0 4 * * 6  # 每周六凌晨4点" "info"
    echo ""
    
    while true; do
        read -p "请输入 Cron 时间表达式: " custom_cron
        if [ -n "$custom_cron" ]; then
            # 简单验证 Cron 表达式格式 (5个字段)
            if echo "$custom_cron" | grep -E '^[0-9*,-/]+ +[0-9*,-/]+ +[0-9*,-/]+ +[0-9*,-/]+ +[0-9*,-/]+$' >/dev/null; then
                CRON_JOB="$custom_cron $UPDATE_SCRIPT"
                log "将使用自定义时间: $custom_cron" "info"
                break
            else
                log "格式错误，请重新输入 (格式: 分 时 日 月 周)" "error"
            fi
        else
            log "输入为空，使用默认时间" "info"
            CRON_JOB="0 2 * * 0 $UPDATE_SCRIPT"
            break
        fi
    done
else
    CRON_JOB="0 2 * * 0 $UPDATE_SCRIPT"
    log "使用默认时间: 每周日凌晨2点" "info"
fi

# 安全地更新 Cron 任务
log "更新 Cron 任务..." "info"

# 创建临时文件保存新的 crontab
TEMP_CRON=$(mktemp)

# 获取现有 crontab，排除我们的脚本
crontab -l 2>/dev/null | grep -v "$ESCAPED_SCRIPT" > "$TEMP_CRON"

# 添加新任务
echo "$CRON_JOB" >> "$TEMP_CRON"

# 应用新的 crontab
if crontab "$TEMP_CRON"; then
    log "Cron 任务配置成功" "info"
else
    log "Cron 任务配置失败" "error"
    rm -f "$TEMP_CRON"
    exit 1
fi

# 清理临时文件
rm -f "$TEMP_CRON"

# 显示更新后的 Cron 任务
echo ""
log "更新后的 Cron 任务列表:" "info"
crontab -l 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "$ESCAPED_SCRIPT"; then
        log "  $line  ← 新添加" "info"
    else
        log "  $line" "info"
    fi
done

# 验证配置
if crontab -l 2>/dev/null | grep -q "$ESCAPED_SCRIPT"; then
    echo ""
    log "✅ 自动更新配置成功!" "info"
    log "📋 配置信息:" "info"
    log "   脚本路径: $UPDATE_SCRIPT" "info"
    log "   日志文件: /var/log/auto-update.log" "info"
    log "   执行时间: $(echo "$CRON_JOB" | awk '{print $1, $2, $3, $4, $5}')" "info"
    log "   手动执行: $UPDATE_SCRIPT" "info"
    
    # 解释执行时间
    CRON_TIME=$(echo "$CRON_JOB" | awk '{print $1, $2, $3, $4, $5}')
    case "$CRON_TIME" in
        "0 2 * * 0") log "   时间说明: 每周日凌晨2点执行" "info" ;;
        "0 3 * * 1") log "   时间说明: 每周一凌晨3点执行" "info" ;;
        "0 1 1 * *") log "   时间说明: 每月1号凌晨1点执行" "info" ;;
        *) log "   时间说明: 自定义时间" "info" ;;
    esac
else
    log "❌ Cron 任务验证失败" "error"
    exit 1
fi

# 询问是否立即测试
echo ""
read -p "是否立即测试自动更新脚本? (不会重启系统) (y/N): " test_script
if [[ "$test_script" =~ ^[Yy]$ ]]; then
    log "执行测试更新..." "info"
    log "注意: 这将执行真实的系统更新!" "warn"
    read -p "确认继续? (y/N): " confirm_test
    if [[ "$confirm_test" =~ ^[Yy]$ ]]; then
        echo ""
        log "开始测试自动更新脚本..." "info"
        "$UPDATE_SCRIPT"
        echo ""
        log "测试完成! 请检查日志文件:" "info"
        log "  tail -f /var/log/auto-update.log" "info"
    else
        log "跳过测试" "info"
    fi
fi

echo ""
log "🎉 自动更新系统配置完成!" "info"
exit 0
