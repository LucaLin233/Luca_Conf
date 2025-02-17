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
CURRENT_SWAP_SIZE=$(free -m | awk '/Swap:/{print $2}')
TARGET_SWAP_SIZE=1024  # 固定1GB大小

# 如果内存大于2GB，则清除swap
if [ "$RAM_SIZE" -gt 2048 ]; then
    if [ "$CURRENT_SWAP_SIZE" -gt 0 ]; then
        echo "内存大于2GB，当前swap大小: ${CURRENT_SWAP_SIZE}M，正在清除swap..."
        swapoff -a
        check_error "关闭swap"
        
        # 从fstab中移除旧的swap条目
        sed -i '/swap/d' /etc/fstab
        check_error "清理fstab中的swap条目"
        
        # 删除swap文件（如果存在）
        [ -f /mnt/swap ] && rm -f /mnt/swap
        
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
        
        # 从fstab中移除旧的swap条目
        sed -i '/swap/d' /etc/fstab
        check_error "清理fstab中的swap条目"
        
        # 创建新的swap文件
        echo "创建新的swap文件..."
        rm -f /mnt/swap
        dd if=/dev/zero of=/mnt/swap bs=1M count=1024
        check_error "创建swap文件"
        
        chmod 600 /mnt/swap
        check_error "设置swap文件权限"
        
        mkswap /mnt/swap
        check_error "格式化swap文件"
        
        # 添加到fstab
        echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
        check_error "添加swap到fstab"
        
        # 启用所有swap
        swapon -a
        check_error "启用swap"
        
        echo "swap大小已调整为1GB"
    else
        echo "swap大小已经是1GB，无需调整"
    fi
fi

# 设置swappiness值
sed -i '/vm.swappiness/d' /etc/sysctl.conf
check_error "删除旧的swappiness设置"
echo "vm.swappiness = 10" >> /etc/sysctl.conf
check_error "添加新的swappiness设置"
sysctl -w vm.swappiness=10
check_error "应用swappiness设置"

# 2. 更新软件包并安装必需的软件
echo "更新系统并安装必要软件..."
dnf update -y
check_error "系统更新"

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
check_error "添加Docker仓库"

dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin bind-utils tuned zram-generator wget util-linux-user
check_error "安装必要软件"

# 3. 启用并立即启动 Docker 和 Tuned 服务
echo "启用系统服务..."
systemctl enable --now docker
check_error "启用Docker服务"

systemctl enable --now tuned
check_error "启用Tuned服务"

# 4. 修改时区为上海
echo "设置系统时区..."
timedatectl set-timezone Asia/Shanghai
check_error "设置时区"

# 5. 修改SSH端口
echo "配置SSH..."
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
check_error "修改SSH端口"

systemctl restart sshd
check_error "重启SSH服务"

# 6. 运行NextTrace安装脚本
echo "安装NextTrace..."
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
check_error "安装NextTrace"

# 7. 启用zram
echo "配置ZRAM..."
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" | tee /etc/systemd/zram-generator.conf
check_error "配置ZRAM"

# 8. 启动容器和服务
echo "启动容器..."
cd /root && docker compose up -d
check_error "启动root目录容器"

cd /root/proxy && bash sbinstall.sh
check_error "启动proxy服务"

cd /root/vmagent && docker compose pull && docker compose up -d
check_error "启动vmagent容器"

# 9. 添加定时任务
echo "配置定时任务..."
(crontab -l 2>/dev/null; echo "5 0 * * * dnf update -y") | crontab -
check_error "添加定时任务"

# 10. 安装fish
echo "安装fish shell..."
cd /etc/yum.repos.d/
wget https://download.opensuse.org/repositories/shells:fish:release:3/CentOS-9_Stream/shells:fish:release:3.repo
check_error "下载fish仓库"

dnf install fish -y
check_error "安装fish"

echo /usr/local/bin/fish | sudo tee -a /etc/shells
check_error "添加fish到shells"

chsh -s $(which fish)
check_error "设置默认shell为fish"

echo "所有任务完成！请重新连接 SSH 以启用 fish shell。"
