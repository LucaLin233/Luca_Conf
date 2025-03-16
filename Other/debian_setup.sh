#!/bin/bash

# 函数：错误检查
check_error() {
    if [ $? -ne 0 ]; then
        echo "错误: $1 失败"
        exit 1
    fi
}

echo "开始系统初始化配置..."

# 1. 系统更新和基础软件安装
echo "更新系统和安装基础软件..."
apt update && apt upgrade -y
check_error "系统更新"

# 添加fish仓库
echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/3/Debian_12/ /' | tee /etc/apt/sources.list.d/shells:fish:release:3.list
curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:3/Debian_12/Release.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/shells_fish_release_3.gpg > /dev/null
apt update
check_error "添加软件源"

# 一次性安装所有软件包
apt install -y dnsutils tuned zram-tools wget curl gpg fish
check_error "安装基础软件"

# 2. 配置swap
echo "配置swap..."
RAM_SIZE=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)

# 如果内存大于2GB，则清除swap
if [ "$RAM_SIZE" -gt 2048 ]; then
    echo "内存大于2GB，禁用swap..."
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
    
    # 获取并删除所有swap文件
    swap_devices=$(swapon --show=NAME --noheadings)
    for device in $swap_devices; do
        if [[ -f "$device" ]]; then
            rm -f "$device"
            echo "删除swap文件: $device"
        fi
    done
    echo "swap已禁用"
else
    echo "内存小于2GB，配置1GB swap..."
    swapoff -a
    sed -i '/\sswap\s/d' /etc/fstab
    
    # 创建新的swap文件
    mkdir -p /mnt
    if command -v fallocate > /dev/null; then
        fallocate -l 1G /mnt/swap || dd if=/dev/zero of=/mnt/swap bs=1M count=1024
    else
        dd if=/dev/zero of=/mnt/swap bs=1M count=1024
    fi
    check_error "创建swap文件"
    
    chmod 600 /mnt/swap
    mkswap /mnt/swap
    
    # 添加到fstab并启用
    echo "/mnt/swap none swap sw 0 0" >> /etc/fstab
    swapon -a
    check_error "启用swap"
    
    echo "swap大小已设置为1GB"
fi

# 3. 配置系统参数
echo "vm.swappiness = 10" > /etc/sysctl.d/99-swappiness.conf
sysctl -w vm.swappiness=10
check_error "配置swappiness"

# 4. 安装Docker
echo "安装Docker..."
curl -fsSL https://get.docker.com | bash -s docker
systemctl enable --now docker
check_error "安装并启用Docker"

# 5. 配置系统服务
echo "配置系统服务..."
# 启用系统日志持久化
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
echo "Storage=persistent" >> /etc/systemd/journald.conf
systemctl restart systemd-journald

# 启用Tuned服务
systemctl enable --now tuned
check_error "配置系统服务"

# 6. 系统设置
echo "配置系统设置..."
timedatectl set-timezone Asia/Shanghai

# 配置SSH - 使用更准确的sed表达式
sed -i 's/^#\?Port .*/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd
check_error "配置系统设置"

# 7. 安装其他工具
echo "安装其他工具..."
# 安装NextTrace
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 配置ZRAM
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
check_error "配置工具"

# 8. 启动容器和服务（使用函数简化）
start_containers() {
    local dir=$1
    echo "启动 $dir 目录的容器..."
    cd $dir && docker compose up -d
    check_error "启动 $dir 容器"
}

start_containers "/root"
start_containers "/root/proxy"
cd /root/vmagent && docker compose pull && docker compose up -d
check_error "启动容器"

# 9. 配置定时任务
echo "配置定时任务..."
(crontab -l 2>/dev/null; echo "5 0 * * * apt update && apt upgrade -y") | crontab -
check_error "设置定时任务"

# 10. 配置fish shell
echo "配置fish shell..."
echo $(which fish) | tee -a /etc/shells
chsh -s $(which fish)
check_error "设置默认shell"

echo "所有任务完成！请重新连接 SSH 以启用 fish shell。"
