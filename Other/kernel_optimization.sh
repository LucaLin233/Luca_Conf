#!/bin/bash

# 网络优化脚本 - 智能更新sysctl参数
# 会检查重复参数并覆盖，新参数则追加

SYSCTL_FILE="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S)"

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
    ["net.ipv6.conf.all.forwarding"]="1"
    ["net.ipv6.conf.default.forwarding"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
)

echo "🚀 开始网络优化配置..."

# 备份原文件
cp "$SYSCTL_FILE" "$BACKUP_FILE"
echo "✅ 已备份原配置到: $BACKUP_FILE"

# 创建临时文件
TEMP_FILE=$(mktemp)
cp "$SYSCTL_FILE" "$TEMP_FILE"

echo "🔍 检查和更新参数..."

# 处理每个参数
for param in "${!PARAMS[@]}"; do
    value="${PARAMS[$param]}"
    escaped_param=$(echo "$param" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # 检查参数是否已存在（忽略注释行）
    if grep -q "^[[:space:]]*${escaped_param}[[:space:]]*=" "$TEMP_FILE"; then
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

# 替换原文件
mv "$TEMP_FILE" "$SYSCTL_FILE"

echo "📝 配置文件已更新！"
echo "🔄 应用新配置..."

# 应用配置
if sysctl -p && sysctl --system; then
    echo "✅ 网络优化配置应用成功！"
    echo "📁 备份文件: $BACKUP_FILE"
else
    echo "❌ 配置应用失败，正在恢复备份..."
    cp "$BACKUP_FILE" "$SYSCTL_FILE"
    echo "🔄 已恢复原配置"
    exit 1
fi
