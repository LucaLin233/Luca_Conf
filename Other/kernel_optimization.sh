#!/bin/bash

# 网络优化脚本 - 智能更新sysctl参数 (改进版)
# 会检查重复参数并覆盖，新参数则追加，跳过不支持的参数
# 增加了仅备份一次原文件，并支持 restore 命令恢复功能

SYSCTL_FILE="/etc/sysctl.conf"
INITIAL_BACKUP_FILE="/etc/sysctl.conf.initial_backup" # 第一次运行时的原始备份

# --- Restore 逻辑 ---
if [ "$1" == "restore" ]; then
    echo "🔄 尝试恢复初始sysctl配置..."
    if [ -f "$INITIAL_BACKUP_FILE" ]; then
        # 使用 sudo cp 确保权限
        sudo cp "$INITIAL_BACKUP_FILE" "$SYSCTL_FILE"
        echo "✅ 已从 $INITIAL_BACKUP_FILE 恢复到 $SYSCTL_FILE"
        echo "🔄 应用新配置..."
        # 使用 sudo sysctl -p 确保权限，并静默错误
        if sudo sysctl -p 2>/dev/null; then
            echo "✅ 配置应用成功！"
        else
            echo "⚠️  配置可能未能完全应用，请检查系统日志或手动运行 'sudo sysctl -p'。"
        fi
        exit 0
    else
        echo "❌ 初始备份文件 $INITIAL_BACKUP_FILE 不存在，无法恢复。"
        echo "请确保脚本至少成功运行过一次优化模式或者手动创建过备份。"
        exit 1
    fi
fi

echo "🚀 开始网络优化配置..."

# --- 优化备份逻辑：只在第一次运行时创建初始备份 ---
if [ ! -f "$INITIAL_BACKUP_FILE" ]; then
    echo "🔎 检测到首次运行，正在创建初始sysctl配置备份..."
    # 确保备份操作有sudo权限
    sudo cp "$SYSCTL_FILE" "$INITIAL_BACKUP_FILE"
    echo "✅ 初始配置已备份到: $INITIAL_BACKUP_FILE"
else
    echo "✅ 初始配置备份已存在 ($INITIAL_BACKUP_FILE)。"
fi

# 以下是原脚本的核心优化逻辑，基本不变
# 要设置的参数数组
declare -A PARAMS=(
    ["fs.file-max"]="6815744"
    ["net.ipv4.tcp_max_syn_backlog"]="8192"
    ["net.core.somaxconn"]="8192"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_abort_on_overflow"]="1"
    ["net.ipv4.tcp_no_metrics_save"]="1"
    ["net.ipv4.tcp_ecn"]="0"
    ["net.ipv4.tcp_frto"]="0"
    ["net.ipv4.tcp_mtu_probing"]="0"
    ["net.ipv4.tcp_rfc1337"]="1"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_fack"]="1"
    ["net.ipv4.tcp_window_scaling"]="1"
    ["net.ipv4.tcp_adv_win_scale"]="2"
    ["net.ipv4.tcp_moderate_rcvbuf"]="1"
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
    ["net.ipv4.tcp_wmem"]="4096 65536 67108864"
    ["net.core.rmem_max"]="67108864"
    ["net.core.wmem_max"]="67108864"
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.ip_local_port_range"]="1024 65535"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.conf.all.rp_filter"]="0"
    ["net.ipv4.conf.default.rp_filter"]="0"
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
)

# 创建临时文件，用于在修改前复制当前 sysctl.conf 内容
# 这样在处理过程中，如果出现问题，原始文件仍然安全
TEMP_FILE=$(mktemp)
cp "$SYSCTL_FILE" "$TEMP_FILE" # 将当前 sysctl.conf 复制到临时文件

echo "🔍 检查和更新参数..."

# 先检查哪些参数系统支持
declare -A SUPPORTED_PARAMS
for param in "${!PARAMS[@]}"; do
    # 检查 /proc/sys 路径是否存在作为补充，因为 sysctl -n 可能在某些情况下不直接返回
    if sysctl -n "$param" >/dev/null 2>&1 || [ -f "/proc/sys/$(echo "$param" | tr '.' '/')"]; then
        SUPPORTED_PARAMS["$param"]="${PARAMS[$param]}"
        echo "✅ 支持: $param"
    else
        echo "⚠️  跳过不支持的参数: $param"
    fi
done

# 处理支持的参数
for param in "${!SUPPORTED_PARAMS[@]}"; do
    value="${SUPPORTED_PARAMS[$param]}"
    escaped_param=$(echo "$param" | sed 's/[][\\.*^$()+?{|]/\\&/g') # 修正sed转义

    # 检查参数是否已存在（忽略注释和空行）
    if grep -qE "^[[:space:]]*${escaped_param}[[:space:]]*=" "$TEMP_FILE"; then
        # 存在则替换
        sed -i "s/^[[:space:]]*${escaped_param}[[:space:]]*=.*/${param} = ${value}/" "$TEMP_FILE"
        echo "🔄 更新: $param = $value"
    else
        # 不存在则追加
        echo "$param = $value" >> "$TEMP_FILE"
        echo "➕ 新增: $param = $value"
    fi
done

# 添加标识注释（如果不存在）
if ! grep -q "# Network optimization for VPS" "$TEMP_FILE"; then
    {
        echo ""
        echo "# Network optimization for VPS - $(date)"
    } >> "$TEMP_FILE"
fi

# 替换原文件 (需要sudo权限)
sudo mv "$TEMP_FILE" "$SYSCTL_FILE"

echo "📝 配置文件已更新！"
echo "🔄 应用新配置..."

# 应用配置，但忽略错误继续执行 (需要sudo权限)
if sudo sysctl -p 2>/dev/null; then
    echo "✅ 网络优化配置应用成功！"
else
    echo "⚠️  部分配置可能无法应用，但已写入配置文件。请检查系统日志或手动运行 'sudo sysctl -p'。"
fi

# 显示最终生效的参数
echo ""
echo "📊 当前生效的优化参数："
for param in "${!SUPPORTED_PARAMS[@]}"; do
    current_value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    echo "   $param = $current_value"
done

echo "🎉 优化完成！"
echo "提示：如需恢复初始配置，请运行脚本并带 'restore' 参数，例如：'sudo bash kernel_optimizer_v2.sh restore'"
