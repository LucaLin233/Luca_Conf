#!/bin/bash

# 彩色输出函数
green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# 错误处理函数
check_error() {
    if [ $? -ne 0 ]; then
        red "错误: $1 执行失败"
        exit 1
    fi
}

# 命令执行封装
run_cmd() {
    if [[ "$1" == "sysctl" ]]; then
        "$@" -e || true
        return 0
    fi
    
    "$@"
    check_error "$*"
}

# SWAP设置函数
setup_swap() {
    green "创建1G SWAP文件..."
    run_cmd dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    run_cmd chmod 600 /swapfile
    run_cmd mkswap /swapfile
    run_cmd swapon /swapfile
    
    if ! grep -q "^/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
        sysctl -p -e || true
    fi
}

# 步骤0: 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    red "此脚本必须以root用户运行"
    exit 1
fi

# 步骤1: 更新系统并安装所有基础软件
yellow "步骤1: 更新系统并安装基础软件..."
green "开始执行更新和安装..."
run_cmd apt update
run_cmd apt upgrade -y
run_cmd apt install -y dnsutils wget curl rsync chrony cron fish tuned
green "步骤1完成: 更新和安装成功。"

# 步骤2: 内存检查和SWAP设置
yellow "步骤2: 检查内存和SWAP..."
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

if [ $MEM_TOTAL -lt 2048 ] && [ $SWAP_TOTAL -eq 0 ]; then
    yellow "内存小于2G且无SWAP，创建1G SWAP..."
    setup_swap
    green "步骤2完成: SWAP设置已应用。"
else
    green "内存配置满足要求或SWAP已存在，跳过SWAP设置。"
fi
green "步骤2完成: 内存检查结束。"

# 备份SSH配置文件（在最后步骤前准备好）
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 步骤3: 检查并安装Docker和NextTrace
yellow "步骤3: 检查并安装Docker和NextTrace..."
if ! command -v docker &>/dev/null; then
    green "Docker未检测到，正在安装..."
    run_cmd curl -fsSL https://get.docker.com | bash
    green "Docker安装完成。"
else
    green "Docker已安装，跳过安装步骤。"
fi

if ! command -v nexttrace &>/dev/null; then
    green "NextTrace未检测到，正在安装..."
    run_cmd bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
    green "NextTrace安装完成。"
else
    green "NextTrace已安装，跳过安装步骤。"
fi
green "步骤3完成: Docker和NextTrace检查结束。"

# 步骤4: 启动容器
yellow "步骤4: 启动容器..."
SUCCESSFUL_STARTS=0  # 计数器，跟踪成功启动的容器
FAILED_DIRS=""  # 跟踪失败目录
for dir in /root /root/proxy /root/vmagent; do
    if [ -d "$dir" ]; then
        green "检查目录 $dir 中的容器..."
        if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/compose.yaml" ]; then
            green "检测到Compose文件，正在尝试启动目录 $dir 中的容器..."
            if cd "$dir" && (docker compose up -d || docker-compose up -d); then
                green "成功启动容器在 $dir"
                SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + 1))
            else
                red "错误: 在 $dir 中启动容器失败！请检查Docker配置或文件。"
                FAILED_DIRS="$FAILED_DIRS $dir"
            fi
        else
            red "错误: 在 $dir 中未找到有效的Docker Compose文件 (如 docker-compose.yml 或 compose.yaml)！"
            FAILED_DIRS="$FAILED_DIRS $dir"
        fi
    else
        red "错误: 目录 $dir 不存在，无法启动容器。"
        FAILED_DIRS="$FAILED_DIRS $dir"
    fi
done
green "步骤4完成: 容器启动检查结束。成功启动: $SUCCESSFUL_STARTS 个。"

# 步骤5: 设置定时更新任务
yellow "步骤5: 设置定时更新任务..."
CRON_CMD="5 0 * * 0 apt update && apt upgrade -y > /var/log/auto-update.log 2>&1"
if ! (crontab -l 2>/dev/null | grep -q "apt update && apt upgrade"); then
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    green "已添加每周日凌晨0:05的自动更新任务"
else
    green "自动更新任务已存在，跳过设置"
fi
green "步骤5完成: 定时任务设置结束。"

# 步骤6: 启用tuned服务
yellow "步骤6: 启用tuned服务..."
if ! systemctl is-active tuned &>/dev/null; then
    run_cmd systemctl enable --now tuned
    green "tuned服务已启用"
else
    green "tuned服务已在运行"
fi
green "步骤6完成: tuned服务状态更新。"

# 步骤7: 设置Fish为默认shell
yellow "步骤7: 设置Fish为默认shell..."
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    if ! grep -q "$fish_path" /etc/shells; then
        echo "$fish_path" >> /etc/shells
    fi
    
    if [ "$SHELL" != "$fish_path" ]; then
        run_cmd chsh -s "$fish_path"
        green "Fish已成功设置为默认shell，重新登录后生效"
    else
        green "Fish已是默认shell，无需修改"
    fi
else
    red "Fish未成功安装，跳过设置默认shell"
fi
green "步骤7完成: Fish shell设置结束。"

# 步骤8: 设置时区
yellow "步骤8: 设置系统时区为上海..."
run_cmd timedatectl set-timezone Asia/Shanghai
green "时区已成功设置为上海"
green "步骤8完成: 时区设置结束。"

# 步骤9: 修改SSH端口
yellow "步骤9: 修改SSH端口..."
if ! grep -q "^Port 9399" /etc/ssh/sshd_config; then
    read -p "您要将SSH端口改为9399吗？ (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        sed -i 's/^#\?Port [0-9]*/Port 9399/' /etc/ssh/sshd_config
        if ! grep -q "^Port 9399" /etc/ssh/sshd_config; then
            echo "Port 9399" >> /etc/ssh/sshd_config
        fi
        run_cmd systemctl restart sshd
        yellow "SSH端口已更改为9399，请使用新端口连接"
    else
        yellow "SSH端口修改已取消，保持原端口"
    fi
else
    green "SSH端口已是9399，无需修改"
fi
green "步骤9完成: SSH端口修改结束。"

# 步骤10: 系统信息汇总
yellow "步骤10: 系统信息汇总"
green "系统版本: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')"
green "内核版本: $(uname -r)"
green "CPU核心数: $(nproc)"
green "内存情况: $(free -h | grep Mem | awk '{print $2}')"
green "SWAP情况: $(free -h | grep Swap | awk '{print $2}')"
green "磁盘使用: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
green "SSH端口: $(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' || echo '未指定 (默认22)')"
green "Docker版本: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
green "活跃容器数: $(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"

if [ -n "$FAILED_DIRS" ]; then
    red "警告: 以下目录中的容器未成功启动: $FAILED_DIRS！请检查并手动修复。"
fi

green "时区设置: $(timedatectl | grep "Time zone" | awk '{print $3}')"
green "Fish默认shell: $SHELL"
green "========================================="
green "步骤10完成: 汇总信息已显示。"

green "\n所有步骤已成功完成！"
yellow "提示: 如果SSH端口已更改，请使用端口9399连接"
