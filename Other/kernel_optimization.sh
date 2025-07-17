#!/bin/bash

# 网络优化脚本 - 智能更新sysctl参数 (参数已全部替换，无 bbr 和 fq，by AI 友情提示)
# 如果你要恢复 bbr&fq 配置，记得单独管理！
# 其余逻辑结构和说明未改

SYSCTL_FILE="/etc/sysctl.conf"
INITIAL_BACKUP_FILE="/etc/sysctl.conf.initial_backup"

if [ -n "$1" ] && [ "$1" == "restore" ]; then
    echo "🔄 尝试恢复初始sysctl配置..."
    if [ -f "$INITIAL_BACKUP_FILE" ]; then
        sudo cp "$INITIAL_BACKUP_FILE" "$SYSCTL_FILE"
        echo "✅ 已从 $INITIAL_BACKUP_FILE 恢复到 $SYSCTL_FILE"
        echo "🔄 应用新配置..."
        if sudo sysctl -p 2>/dev/null; then
            echo "✅ 配置应用成功！"
        else
            echo "⚠️  配置可能未能完全应用，但文件已恢复。请检查系统日志或手动运行 'sudo sysctl -p'。"
        fi
        exit 0
    else
        echo "❌ 初始备份文件 $INITIAL_BACKUP_FILE 不存在，无法恢复。"
        exit 1
    fi
fi

echo "🚀 开始网络优化配置..."

if [ ! -f "$INITIAL_BACKUP_FILE" ]; then
    echo "🔎 检测到首次运行优化模式，正在创建初始sysctl配置备份..."
    if sudo cp "$SYSCTL_FILE" "$INITIAL_BACKUP_FILE" 2>/dev/null; then
        echo "✅ 初始配置已备份到: $INITIAL_BACKUP_FILE"
    else
        echo "❌ 无法创建初始备份文件 $INITIAL_BACKUP_FILE。请检查权限或文件是否存在。"
        exit 1
    fi
else
    echo "✅ 初始配置备份已存在 ($INITIAL_BACKUP_FILE)。"
fi

# 下面是只包含你刚发的那批参数（**去掉 fq/bbr**）的配置
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

TEMP_FILE=$(mktemp)
if [ ! -f "$SYSCTL_FILE" ]; then
    touch "$TEMP_FILE"
else
    cp "$SYSCTL_FILE" "$TEMP_FILE"
fi

echo "🔍 检查和更新参数..."

declare -A SUPPORTED_PARAMS
for param in "${!PARAMS[@]}"; do
    if sysctl -n "$param" >/dev/null 2>&1 || [ -f "/proc/sys/$(echo "$param" | tr '.' '/')" ]; then
        SUPPORTED_PARAMS["$param"]="${PARAMS[$param]}"
        echo "✅ 支持: $param"
    else
        echo "⚠️  跳过不支持的参数: $param"
    fi
done

for param in "${!SUPPORTED_PARAMS[@]}"; do
    value="${SUPPORTED_PARAMS[$param]}"
    escaped_param=$(echo "$param" | sed 's/[][\\.*^$()+?{|]/\\&/g')
    if grep -qE "^[[:space:]]*${escaped_param}[[:space:]]*=" "$TEMP_FILE"; then
        sed -i "s/^[[:space:]]*${escaped_param}[[:space:]]*=.*/${param} = ${value}/" "$TEMP_FILE"
        echo "🔄 更新: $param = $value"
    else
        echo "$param = $value" >> "$TEMP_FILE"
        echo "➕ 新增: $param = $value"
    fi
done

if ! grep -q "# Network optimization for VPS" "$TEMP_FILE"; then
    {
        echo ""
        echo "# Network optimization for VPS - $(date)"
    } >> "$TEMP_FILE"
fi

sudo mv "$TEMP_FILE" "$SYSCTL_FILE"

echo "📝 配置文件已更新！"
echo "🔄 应用新配置..."

if sudo sysctl -p 2>/dev/null; then
    echo "✅ 网络优化配置应用成功！"
else
    echo "⚠️  部分配置可能无法应用，但已写入配置文件。请检查系统日志或手动运行 'sudo sysctl -p'。"
fi

echo ""
echo "📊 当前生效的优化参数："
for param in "${!SUPPORTED_PARAMS[@]}"; do
    current_value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    echo "   $param = $current_value"
done

echo "🎉 优化完成！"
echo "提示：如需恢复初始配置，请运行以下命令：'curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | sudo bash -s restore'"
