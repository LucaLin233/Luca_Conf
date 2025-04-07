#!/bin/bash

set -e

# 记录步骤
step=0
log_file="/root/deployment.log"

# 记录函数
log_step() {
    ((step++))
    echo -e "\033[0;32m执行步骤 $step: $1\033[0m"
    echo "执行步骤 $step: $1" >> $log_file
}

# 错误处理
handle_error() {
    echo -e "\033[0;31m步骤 $step 出错: $1\033[0m"
    exit 1
}

# 1. 更新系统和安装基础软件 (合并了步骤1和2)
log_step "更新系统并安装基础软件包"
apt update && apt upgrade -y && apt install -y dnsutils wget curl || handle_error "系统更新或软件安装失败"

# 2. 检查内存和配置swap
log_step "检查内存并配置swap"
mem_total=$(free -m | grep Mem | awk '{print $2}')
swap_total=$(free -m | grep Swap | awk '{print $2}')

if [ $mem_total -lt 2048 ] && [ $swap_total -eq 0 ]; then
    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1G count=1 || handle_error "创建swap文件失败"
    chmod 600 /swapfile || handle_error "设置swap权限失败"
    mkswap /swapfile || handle_error "格式化swap失败"
    swapon /swapfile || handle_error "激活swap失败"
    echo '/swapfile none swap sw 0 0' >> /etc/fstab || handle_error "添加swap到fstab失败"
    
    # 设置合理的swappiness
    echo 'vm.swappiness=10' >> /etc/sysctl.conf || handle_error "设置swappiness失败"
    sysctl -p || handle_error "应用sysctl配置失败"
fi

# 3. 安装Docker
log_step "安装Docker"
curl -fsSL https://get.docker.com | bash -s docker || handle_error "Docker安装失败"

# 4. 设置时区
log_step "设置时区"
timedatectl set-timezone Asia/Shanghai || handle_error "时区设置失败"

# 5. 更改SSH端口
log_step "更改SSH端口"
if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak || handle_error "备份SSH配置失败"
    sed -i 's/^#\?Port .*/Port 9399/' /etc/ssh/sshd_config || handle_error "修改SSH端口失败"
    systemctl restart sshd || handle_error "重启SSH服务失败"
else
    handle_error "SSH配置文件不存在"
fi

# 6. 安装NextTrace
log_step "安装NextTrace"
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)" || handle_error "NextTrace安装失败"

# 7. 启动容器
log_step "启动容器"
for dir in "/root" "/root/proxy" "/root/vmagent"; do
    if [ -d "$dir" ]; then
        # 先尝试docker-compose.yml，再尝试compose.yml
        if [ -f "$dir/docker-compose.yml" ]; then 
            (cd "$dir" && docker compose up -d) || handle_error "启动 $dir 的容器失败"
        elif [ -f "$dir/compose.yml" ] || [ -f "$dir/compose.yaml" ]; then
            (cd "$dir" && docker compose up -d) || handle_error "启动 $dir 的容器失败"
        else
            echo "目录 $dir 中未找到compose配置文件，跳过..." >> $log_file
        fi
    else
        echo "目录 $dir 不存在，跳过..." >> $log_file
    fi
done

# 8. 配置crontab任务
log_step "配置crontab任务"
(crontab -l 2>/dev/null | grep -v "apt update && apt upgrade" || true; echo "5 0 * * * apt update && apt upgrade -y") | crontab - || handle_error "配置crontab失败"

# 9. 安装Fish并设置为默认shell
log_step "安装Fish并设置为默认shell"
echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_12/ /' | tee /etc/apt/sources.list.d/shells:fish:release:4.list && \
curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:4/Debian_12/Release.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/shells_fish_release_4.gpg > /dev/null && \
apt update && apt install -y fish || handle_error "安装Fish失败"

fish_path=$(which fish)
echo "$fish_path" | tee -a /etc/shells && chsh -s "$fish_path" || handle_error "设置Fish为默认shell失败"

# 10. 安装并启动tuned
log_step "安装并启动tuned"
apt install -y tuned && systemctl enable --now tuned || handle_error "安装或配置tuned失败"

echo -e "\033[0;32m部署成功完成！日志文件位于: $log_file\033[0m"
