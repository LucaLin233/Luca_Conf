#!/bin/bash

# 函数：错误检查
check_error() {
    if [ $? -ne 0 ]; then
        echo "错误: $1 失败"
        exit 1
    fi
}

echo "开始系统初始化配置..."

# 1. 检测并配置swap
echo "检查内存和swap配置..."
RAM_SIZE=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)

# 如果内存大于2GB，则清除swap
if [ "$RAM_SIZE" -gt 2048 ]; then
    echo "内存大于2GB，禁用swap..."
    swapoff -a
    sed -i '/swap/d' /etc/fstab
    [ -f /mnt/swap ] && rm -f /mnt/swap
    echo "swap已禁用"
else
    echo "内存小于2GB，配置1GB swap..."
    swapoff -a
    sed -i '/swap/d' /etc/fstab
    
    # 创建新的swap文件
    rm -f /mnt/swap
    dd if=/dev/zero of=/mnt/swap bs=1M count=1024
    check_error "创建swap文件"
    
    chmod 600 /mnt/swap
    mkswap /mnt/swap
    
    # 添加到fstab并启用
    echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
    swapon -a
    check_error "启用swap"
    
    echo "swap大小已设置为1GB"
fi

# 设置swappiness值
sed -i '/vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 10" >> /etc/sysctl.conf
sysctl -w vm.swappiness=10
check_error "配置swappiness"

# 2. 添加存储库
echo "添加Docker和fish存储库..."
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
wget -q -O /etc/yum.repos.d/fish.repo https://download.opensuse.org/repositories/shells:fish:release:3/CentOS-9_Stream/shells:fish:release:3.repo
check_error "添加存储库"

# 3. 更新软件包并一次性安装所有必需的软件
echo "更新系统并安装必要软件..."
dnf update -y
check_error "系统更新"

dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    bind-utils tuned zram-generator wget util-linux-user fish
check_error "安装必要软件"

# 4. 启用并立即启动服务
echo "启用系统服务..."
systemctl enable --now docker tuned
check_error "启用服务"

# 5. 设置系统配置
echo "设置系统时区和SSH..."
timedatectl set-timezone Asia/Shanghai
check_error "设置时区"

# 修改SSH端口并重启服务
sed -i 's/^#\?Port .*/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd
check_error "配置SSH"

# 6. 安装NextTrace
echo "安装NextTrace..."
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
check_error "安装NextTrace"

# 7. 配置ZRAM
echo "配置ZRAM..."
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf
check_error "配置ZRAM"

# 8. 启动容器和服务 (使用一个函数简化)
start_containers() {
    local dir=$1
    echo "启动 $dir 目录的容器..."
    cd $dir && docker compose up -d
    check_error "启动 $dir 容器"
}

start_containers "/root"
start_containers "/root/proxy"
cd /root/vmagent && docker compose pull && docker compose up -d
check_error "启动vmagent容器"

# 9. 添加定时任务
echo "配置定时任务..."
(crontab -l 2>/dev/null; echo "5 0 * * * dnf upgrade -y") | crontab -
check_error "添加定时任务"

# 10. 设置fish为默认shell
echo "配置fish shell..."
echo $(which fish) | tee -a /etc/shells
chsh -s $(which fish)
check_error "设置默认shell"

echo "所有任务完成！请重新连接 SSH 以启用 fish shell。"
