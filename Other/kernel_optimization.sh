#!/bin/bash

# VPS 网络优化脚本 - 强制应用 BBR 拥塞算法 + cake 队列，无需选择

SYSCTL_FILE="/etc/sysctl.conf"
INITIAL_BACKUP_FILE="/etc/sysctl.conf.initial_backup"
NET_IF="eth0" # 请将 eth0 改成你的真实网卡名！

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

declare -A PARAMS=(
    [fs.file-max]="6815744"
    [net.ipv4.tcp_max_syn_backlog]="8192"
    [net.core.somaxconn]="8192"
    [net.ipv4.tcp_tw_reuse]="1"
    [net.ipv4.tcp_abort_on_overflow]="1"
    [net.ipv4.tcp_no_metrics_save]="1"
    [net.ipv4.tcp_ecn]="0"
    [net.ipv4.tcp_frto]="0"
    [net.ipv4.tcp_mtu_probing]="0"
    [net.ipv4.tcp_rfc1337]="1"
    [net.ipv4.tcp_sack]="1"
    [net.ipv4.tcp_fack]="1"
    [net.ipv4.tcp_window_scaling]="1"
    [net.ipv4.tcp_adv_win_scale]="2"
    [net.ipv4.tcp_moderate_rcvbuf]="1"
    [net.ipv4.tcp_fin_timeout]="30"
    [net.ipv4.tcp_rmem]="4096 87380 67108864"
    [net.ipv4.tcp_wmem]="4096 65536 67108864"
    [net.core.rmem_max]="67108864"
    [net.core.wmem_max]="67108864"
    [net.ipv4.udp_rmem_min]="8192"
    [net.ipv4.udp_wmem_min]="8192"
    [net.ipv4.ip_local_port_range]="1024 65535"
    [net.ipv4.tcp_timestamps]="1"
    [net.ipv4.conf.all.rp_filter]="0"
    [net.ipv4.conf.default.rp_filter]="0"
    [net.ipv4.ip_forward]="1"
    [net.ipv4.conf.all.route_localnet]="1"
    [net.core.default_qdisc]="cake"
    [net.ipv4.tcp_congestion_control]="bbr"
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
        echo "${param} = ${value}" >> "$TEMP_FILE"
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

# 强制设置队列到 cake
if ! which tc >/dev/null 2>&1; then
    echo "⚠️  未检测到 tc 命令，跳过队列自动切换，请手动安装 iproute2 包！"
else
    if tc qdisc show dev $NET_IF 2>/dev/null | grep -q "cake"; then
        echo "✅ $NET_IF 已在使用 cake 队列。"
    else
        sudo tc qdisc replace dev $NET_IF root cake && echo "🚀 $NET_IF 队列已切换到 cake"
    fi
fi

# 检查一下BBR是否真的启用
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$current_cc" = "bbr" ]; then
    echo "✅ BBR 拥塞算法已启用"
else
    echo "⚠️  BBR 可能未成功启用，当前为: $current_cc"
    echo "   检查内核是否支持 BBR (`lsmod | grep bbr` 查看)，或重启服务器后再试。"
fi

echo ""
echo "🎉 优化完成！"
echo "提示：如需恢复初始配置，请运行：'curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | sudo bash -s restore'"
