#!/bin/bash

# 彩色输出函数
green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# 错误处理函数
check_error() {
    if [ $? -ne 0 ]; then
        red "错误: 步骤 $1 执行失败"
        exit 1
    fi
}

# 步骤1: 更新系统并安装基础软件
green "步骤1: 更新系统并安装基础软件..."
apt update && apt upgrade -y && apt install -y dnsutils wget curl
check_error "系统更新和安装基础软件"

# 步骤2: 内存检查和SWAP设置
green "步骤2: 检查内存和SWAP..."
if [ $(free -m | grep Mem | awk '{print $2}') -lt 2048 ] && [ $(free -m | grep Swap | awk '{print $2}') -eq 0 ]; then
    green "内存小于2G且无SWAP，创建1G SWAP..."
    # 一次性创建和设置swap文件
    dd if=/dev/zero of=/swapfile bs=1M count=1024 && chmod 600 /swapfile && \
    mkswap /swapfile && swapon /swapfile
    check_error "创建并激活SWAP"
    
    # 持久化swap并设置swappiness
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p
    check_error "配置SWAP和swappiness"
fi

# 步骤3: 设置时区和修改SSH端口
green "步骤3: 设置时区和SSH端口..."
timedatectl set-timezone Asia/Shanghai
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
if ! grep -q "^Port 9399" /etc/ssh/sshd_config; then
    echo "Port 9399" >> /etc/ssh/sshd_config
fi
systemctl restart sshd
check_error "设置时区和SSH端口"

# 步骤4: 安装Docker和NextTrace
green "步骤4: 安装Docker和NextTrace..."
curl -fsSL https://get.docker.com | bash -s docker
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
check_error "安装Docker和NextTrace"

# 步骤5: 启动容器
green "步骤5: 启动容器..."
for dir in /root /root/proxy /root/vmagent; do
    if [ -d "$dir" ]; then
        (cd "$dir" && (docker-compose up -d 2>/dev/null || docker compose up -d))
    fi
done
check_error "启动容器"

# 步骤6: 设置定时更新任务
green "步骤6: 设置定时更新任务..."
(crontab -l 2>/dev/null || echo "") | grep -v "apt update && apt upgrade" | { cat; echo "5 0 * * * apt update && apt upgrade -y"; } | crontab -
check_error "设置定时更新"

# 步骤7: 安装Fish和tuned
green "步骤7: 安装Fish和tuned..."
# 直接安装Fish和tuned
apt install -y fish tuned
check_error "安装Fish和tuned"

# 启用tuned服务
systemctl enable --now tuned
check_error "启用tuned服务"

# 设置Fish为默认shell
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    grep -qxF "$fish_path" /etc/shells || echo "$fish_path" >> /etc/shells
    chsh -s "$fish_path"
    check_error "设置Fish为默认shell"
else
    red "Fish未成功安装，跳过设置默认shell"
fi

green "所有步骤已成功完成！"
green "提示: SSH端口已更改为9399，请使用新端口连接"
