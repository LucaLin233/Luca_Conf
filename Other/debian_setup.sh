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

# 安装必要的包
apt install -y dnsutils tuned zram-tools wget curl gpg
check_error "安装基础软件"

# 2. 检查内存和swap状态
echo "配置swap..."
RAM_SIZE=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)
CURRENT_SWAP_SIZE=$(free -m | awk '/Swap:/{print $2}')
TARGET_SWAP_SIZE=1024  # 固定1GB大小

# 如果内存大于2GB，则清除swap
if [ "$RAM_SIZE" -gt 2048 ]; then
    if [ "$CURRENT_SWAP_SIZE" -gt 0 ]; then
        echo "内存大于2GB，当前swap大小: ${CURRENT_SWAP_SIZE}M，正在清除swap..."
        # 获取所有swap设备和文件
        swap_devices=$(swapon --show=NAME --noheadings)
        
        # 关闭所有swap
        swapoff -a
        check_error "关闭swap"
        
        # 从fstab中移除所有swap条目
        sed -i '/\sswap\s/d' /etc/fstab
        check_error "清理fstab中的swap条目"
        
        # 删除swap文件（如果存在）
        for device in $swap_devices; do
            if [[ -f "$device" ]]; then
                rm -f "$device"
                echo "删除swap文件: $device"
            fi
        done
        
        echo "swap已成功清除。"
    else
        echo "当前未启用swap，无需清除。"
    fi
else
    if [ "$CURRENT_SWAP_SIZE" != "$TARGET_SWAP_SIZE" ]; then
        echo "当前swap大小: ${CURRENT_SWAP_SIZE}M"
        echo "目标swap大小: ${TARGET_SWAP_SIZE}M (1GB)"
        
        # 关闭所有swap
        swapoff -a
        check_error "关闭swap"
        
        # 从fstab中移除所有swap条目
        sed -i '/\sswap\s/d' /etc/fstab
        check_error "清理fstab中的swap条目"
        
        # 创建新的swap文件
        echo "创建新的swap文件..."
        mkdir -p /mnt
        
        # 使用fallocate替代dd（更快）
        fallocate -l 1G /mnt/swap
        if [ $? -ne 0 ]; then
            echo "fallocate失败，尝试使用dd..."
            dd if=/dev/zero of=/mnt/swap bs=1M count=1024
            check_error "创建swap文件"
        fi
        
        chmod 600 /mnt/swap
        check_error "设置swap文件权限"
        
        mkswap /mnt/swap
        check_error "格式化swap文件"
        
        # 添加到fstab
        echo "/mnt/swap none swap sw 0 0" >> /etc/fstab
        check_error "添加swap到fstab"
        
        # 启用所有swap
        swapon -a
        check_error "启用swap"
        
        echo "swap大小已调整为1GB"
    else
        echo "swap大小已经是1GB，无需调整"
    fi
fi

# 3. 配置系统参数
# 设置swappiness
if [ -f /etc/sysctl.d/99-swappiness.conf ]; then
    rm -f /etc/sysctl.d/99-swappiness.conf
fi
echo "vm.swappiness = 10" > /etc/sysctl.d/99-swappiness.conf
check_error "创建swappiness配置文件"

sysctl -w vm.swappiness=10
check_error "应用swappiness设置"

# 4. 安装Docker
echo "安装Docker..."
curl -fsSL https://get.docker.com | bash -s docker
check_error "安装Docker"

systemctl enable --now docker
check_error "启用Docker服务"

# 5. 配置系统服务
echo "配置系统服务..."
# 启用系统日志持久化
mkdir -p /var/log/journal
check_error "创建日志目录"

systemd-tmpfiles --create --prefix /var/log/journal
check_error "配置日志目录"

echo "Storage=persistent" >> /etc/systemd/journald.conf
check_error "配置持久化日志"

systemctl restart systemd-journald
check_error "重启journald服务"

# 启用Tuned服务
systemctl enable --now tuned
check_error "启用Tuned服务"

# 6. 系统设置
echo "配置系统设置..."
# 设置时区
timedatectl set-timezone Asia/Shanghai
check_error "设置时区"

# 配置SSH
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
check_error "修改SSH端口"

systemctl restart sshd
check_error "重启SSH服务"

# 7. 安装其他工具
echo "安装其他工具..."
# 安装NextTrace
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
check_error "安装NextTrace"

# 配置ZRAM
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" | tee /etc/systemd/zram-generator.conf
check_error "配置ZRAM"

# 8. 启动容器和服务
echo "启动容器..."
cd /root && docker compose up -d
check_error "启动root目录容器"

cd /root/proxy && docker compose up -d
check_error "启动proxy容器"

cd /root/vmagent && docker compose pull && docker compose up -d
check_error "启动vmagent容器"

# 9. 配置定时任务
echo "配置定时任务..."
(crontab -l 2>/dev/null; echo "5 0 * * * apt update && apt upgrade -y") | crontab -
check_error "添加定时任务"

# 10. 安装fish shell
echo "安装fish shell..."
echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/3/Debian_12/ /' | tee /etc/apt/sources.list.d/shells:fish:release:3.list
check_error "添加fish仓库"

curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:3/Debian_12/Release.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/shells_fish_release_3.gpg > /dev/null
check_error "添加fish密钥"

apt update
check_error "更新软件源"

apt install -y fish
check_error "安装fish"

echo /usr/bin/fish | tee -a /etc/shells
check_error "添加fish到shells"

chsh -s $(which fish)
check_error "设置默认shell为fish"

echo "所有任务完成！请重新连接 SSH 以启用 fish shell。"
