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
    # 特殊处理sysctl命令
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
    
    # 持久化swap并设置swappiness
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

# 步骤1: 更新系统并安装基础软件
green "步骤1: 更新系统并安装基础软件..."
run_cmd apt-get update
run_cmd apt-get upgrade -y
run_cmd apt-get install -y dnsutils wget curl rsync chrony cron

# 步骤2: 内存检查和SWAP设置
green "步骤2: 检查内存和SWAP..."
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

if [ $MEM_TOTAL -lt 2048 ] && [ $SWAP_TOTAL -eq 0 ]; then
    yellow "内存小于2G且无SWAP，创建1G SWAP..."
    setup_swap
else
    green "内存配置满足要求或SWAP已存在，跳过SWAP设置"
fi

# 步骤3: 设置时区和修改SSH端口
green "步骤3: 设置时区和SSH端口..."
run_cmd timedatectl set-timezone Asia/Shanghai

# 检查SSH端口是否已配置为9399
if ! grep -q "^Port 9399" /etc/ssh/sshd_config; then
    sed -i 's/^#\?Port [0-9]*/Port 9399/' /etc/ssh/sshd_config
    if ! grep -q "^Port 9399" /etc/ssh/sshd_config; then
        echo "Port 9399" >> /etc/ssh/sshd_config
    fi
    run_cmd systemctl restart sshd
    yellow "SSH端口已更改为9399，请使用新端口连接"
else
    green "SSH端口已是9399，无需修改"
fi

# 步骤4: 安装Docker和NextTrace
green "步骤4: 安装Docker和NextTrace..."

# 仅在Docker未安装时安装
if ! command -v docker &>/dev/null; then
    green "安装Docker..."
    run_cmd curl -fsSL https://get.docker.com | bash
else
    green "Docker已安装，跳过安装步骤"
fi

# 仅在NextTrace未安装时安装
if ! command -v nexttrace &>/dev/null; then
    green "安装NextTrace..."
    run_cmd bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
else
    green "NextTrace已安装，跳过安装步骤"
fi

# 步骤5: 启动容器
green "步骤5: 启动容器..."
for dir in /root /root/proxy /root/vmagent; do
    if [ -d "$dir" ]; then
        green "启动目录 $dir 中的容器..."
        (cd "$dir" && (docker compose up -d || docker-compose up -d)) || yellow "警告: $dir 中无有效的Docker Compose文件"
    fi
done

# 步骤6: 设置定时更新任务
green "步骤6: 设置定时更新任务..."
CRON_CMD="5 0 * * 0 apt-get update && apt-get upgrade -y > /var/log/auto-update.log 2>&1"
if ! (crontab -l 2>/dev/null | grep -q "apt-get update && apt-get upgrade"); then
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    green "已添加每天凌晨0:05的自动更新任务"
else
    green "自动更新任务已存在，跳过设置"
fi

# 步骤7: 安装Fish和tuned
green "步骤7: 安装Fish和tuned..."
# 安装Fish和tuned
run_cmd apt-get install -y fish tuned

# 启用tuned服务
if ! systemctl is-active tuned &>/dev/null; then
    run_cmd systemctl enable --now tuned
    green "tuned服务已启用"
else
    green "tuned服务已在运行"
fi

# 设置Fish为默认shell
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    if ! grep -q "$fish_path" /etc/shells; then
        echo "$fish_path" >> /etc/shells
    fi
    
    if [ "$SHELL" != "$fish_path" ]; then
        run_cmd chsh -s "$fish_path"
        green "Fish已设置为默认shell，重新登录后生效"
    else
        green "Fish已是默认shell"
    fi
else
    red "Fish未成功安装，跳过设置默认shell"
fi

# 步骤8: 系统信息汇总
green "\n====== 部署完成，系统信息汇总 ======="
echo "系统版本: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')"
echo "内核版本: $(uname -r)"
echo "CPU核心数: $(nproc)"
echo "内存情况: $(free -h | grep Mem | awk '{print $2}')"
echo "SWAP情况: $(free -h | grep Swap | awk '{print $2}')"
echo "磁盘使用: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
echo "SSH端口: $(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')"
echo "Docker版本: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
echo "活跃容器数: $(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"
echo "时区设置: $(timedatectl | grep "Time zone" | awk '{print $3}')"
echo "========================================="

green "\n所有步骤已成功完成！"
yellow "提示: 如果SSH端口已更改，请使用端口9399连接"
