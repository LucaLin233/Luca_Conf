#!/bin/bash

# 网络优化脚本 - 智能更新sysctl参数 (改进版)
# 会检查重复参数并覆盖，新参数则追加，跳过不支持的参数
# 增加了仅备份一次原文件，并支持 restore 命令恢复功能

# 定义重要文件路径
SYSCTL_FILE="/etc/sysctl.conf"
INITIAL_BACKUP_FILE="/etc/sysctl.conf.initial_backup" # 第一次运行时的原始备份文件

# --- Restore 逻辑 ---
# 如果脚本有任何参数，并且第一个参数是 "restore"，则执行恢复操作
if [ -n "$1" ] && [ "$1" == "restore" ]; then
    echo "🔄 尝试恢复初始sysctl配置..."
    if [ -f "$INITIAL_BACKUP_FILE" ]; then
        # 使用 sudo cp 确保权限，并将备份文件恢复到主配置文件
        sudo cp "$INITIAL_BACKUP_FILE" "$SYSCTL_FILE"
        echo "✅ 已从 $INITIAL_BACKUP_FILE 恢复到 $SYSCTL_FILE"
        echo "🔄 应用新配置..."
        # 使用 sudo sysctl -p 确保权限，并静默错误输出
        if sudo sysctl -p 2>/dev/null; then
            echo "✅ 配置应用成功！"
        else
            echo "⚠️  配置可能未能完全应用，但文件已恢复。请检查系统日志或手动运行 'sudo sysctl -p'。"
        fi
        exit 0 # 恢复成功或失败，都退出脚本
    else
        echo "❌ 初始备份文件 $INITIAL_BACKUP_FILE 不存在，无法恢复。"
        echo "请确保脚本至少成功运行过一次优化模式或者手动创建过备份。"
        exit 1 # 备份文件不存在，退出并报错
    fi
fi

# --- 正常的优化逻辑从这里开始 ---

echo "🚀 开始网络优化配置..."

# --- 优化备份逻辑：只在第一次运行时创建初始备份 ---
# 检查初始备份文件是否存在
if [ ! -f "$INITIAL_BACKUP_FILE" ]; then
    echo "🔎 检测到首次运行优化模式，正在创建初始sysctl配置备份..."
    # 确保备份操作有sudo权限，将当前sysctl.conf备份到指定路径
    # 如果 sysctl.conf 不存在，cp 会创建，这通常不应发生
    if sudo cp "$SYSCTL_FILE" "$INITIAL_BACKUP_FILE" 2>/dev/null; then
        echo "✅ 初始配置已备份到: $INITIAL_BACKUP_FILE"
    else
        echo "❌ 无法创建初始备份文件 $INITIAL_BACKUP_FILE。请检查权限或文件是否存在。"
        exit 1 # 无法备份，退出
    fi
else
    echo "✅ 初始配置备份已存在 ($INITIAL_BACKUP_FILE)。"
fi

# 定义要设置的参数数组
# 注意：TCP/IP 参数的调整需要非常谨慎，不当的设置可能影响网络稳定性
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
    # 以下是之前可能导致问题的转发参数。
    # 如果你的服务器不需要作为路由器/网关来转发流量，这些参数就不需要开启。
    # 如果开启，会默认禁用路由器广告接收（RA），导致依赖RA获取IPv6网关的系统无法正常工作
    # ["net.ipv6.conf.all.forwarding"]="1"    # 如果不需要IPv6转发，请不要开启或注释掉
    # ["net.ipv6.conf.default.forwarding"]="1" # 同上
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
)

# 使用 mktemp 创建一个安全的临时文件，用于编辑配置
TEMP_FILE=$(mktemp)
if [ ! -f "$SYSCTL_FILE" ]; then
    # 如果 sysctl.conf 不存在，创建一个空的临时文件
    touch "$TEMP_FILE"
else
    # 否则，将当前 sysctl.conf 内容复制到临时文件
    cp "$SYSCTL_FILE" "$TEMP_FILE"
fi

echo "🔍 检查和更新参数..."

# 检查哪些参数系统支持，并存储到 SUPPORTED_PARAMS 数组
declare -A SUPPORTED_PARAMS
for param in "${!PARAMS[@]}"; do
    # 尝试查询参数值，如果查询失败（参数不存在），则尝试检查 /proc/sys 路径
    if sysctl -n "$param" >/dev/null 2>&1 || [ -f "/proc/sys/$(echo "$param" | tr '.' '/')"]; then
        SUPPORTED_PARAMS["$param"]="${PARAMS[$param]}"
        echo "✅ 支持: $param"
    else
        echo "⚠️  跳过不支持的参数: $param"
    fi
done

# 遍历所有支持的参数，更新或添加它们到临时文件
for param in "${!SUPPORTED_PARAMS[@]}"; do
    value="${SUPPORTED_PARAMS[$param]}"
    # 为 sed 命令转义参数名中的特殊字符，确保替换正确
    escaped_param=$(echo "$param" | sed 's/[][\\.*^$()+?{|]/\\&/g')

    # 检查参数在临时文件中是否已存在（忽略注释行和前导空白）
    # 使用 grep -E 进行扩展正则表达式匹配
    if grep -qE "^[[:space:]]*${escaped_param}[[:space:]]*=" "$TEMP_FILE"; then
        # 参数存在，使用 sed -i 替换对应的行
        # sed -i 在 Linux 上可以直接编辑文件，但在某些系统上可能需要 -e
        # 注意：这里直接修改 TEMP_FILE
        sed -i "s/^[[:space:]]*${escaped_param}[[:space:]]*=.*/${param} = ${value}/" "$TEMP_FILE"
        echo "🔄 更新: $param = $value"
    else
        # 参数不存在，追加到临时文件末尾
        echo "$param = $value" >> "$TEMP_FILE"
        echo "➕ 新增: $param = $value"
    fi
done

# 添加一个标识注释到配置文件末尾（如果不存在），方便识别脚本修改
if ! grep -q "# Network optimization for VPS" "$TEMP_FILE"; then
    {
        echo ""
        echo "# Network optimization for VPS - $(date)"
    } >> "$TEMP_FILE"
fi

# 将修改后的临时文件覆盖原来的 sysctl.conf
# 需要 sudo 权限
sudo mv "$TEMP_FILE" "$SYSCTL_FILE"

echo "📝 配置文件已更新！"
echo "🔄 应用新配置..."

# 强制加载新的 sysctl 配置
# 需要 sudo 权限，并静默错误输出，如果失败则打印警告
if sudo sysctl -p 2>/dev/null; then
    echo "✅ 网络优化配置应用成功！"
else
    echo "⚠️  部分配置可能无法应用，但已写入配置文件。请检查系统日志或手动运行 'sudo sysctl -p'。"
fi

# 显示当前生效的优化参数
echo ""
echo "📊 当前生效的优化参数："
for param in "${!SUPPORTED_PARAMS[@]}"; do
    # 尝试获取参数的当前值，如果获取失败则显示 "N/A"
    current_value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    echo "   $param = $current_value"
done

echo "🎉 优化完成！"
echo "提示：如需恢复初始配置，请运行以下命令：'curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | sudo bash -s restore'"
