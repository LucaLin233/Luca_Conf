#!/bin/bash
# 自动更新系统配置模块

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

# 移除旧的相关任务
crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "auto-update" | crontab -

# 添加新任务
CRON_JOB="0 2 * * 0 $UPDATE_SCRIPT"  # 每周日凌晨2点执行

# 询问用户是否自定义时间
read -p "是否自定义更新时间? 默认每周日凌晨2点 (y/N): " custom_time
if [[ "$custom_time" =~ ^[Yy]$ ]]; then
    echo "请输入 Cron 表达式 (分 时 日 月 周):"
    echo "例如: 0 2 * * 0 (每周日凌晨2点)"
    echo "例如: 0 3 * * 1 (每周一凌晨3点)"
    read -p "输入: " custom_cron
    if [ -n "$custom_cron" ]; then
        CRON_JOB="$custom_cron $UPDATE_SCRIPT"
    fi
fi

# 添加 Cron 任务
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

log "Cron 任务已配置: $CRON_JOB" "info"

# 验证 Cron 配置
if crontab -l | grep -q "$UPDATE_SCRIPT"; then
    log "自动更新配置成功" "info"
    log "日志文件: /var/log/auto-update.log" "info"
    log "手动执行: $UPDATE_SCRIPT" "info"
else
    log "Cron 任务配置失败" "error"
    exit 1
fi

# 询问是否立即测试
read -p "是否立即测试自动更新脚本? (y/N): " test_script
if [[ "$test_script" =~ ^[Yy]$ ]]; then
    log "执行测试更新..." "info"
    "$UPDATE_SCRIPT"
    log "测试完成，请检查日志: /var/log/auto-update.log" "info"
fi

log "自动更新系统配置完成" "info"
exit 0
