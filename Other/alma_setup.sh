#!/bin/bash

# 函数：错误检查
check_error() {
    if [ $? -ne 0 ]; then
        echo "错误: $1 失败"
        exit 1
    fi
}

# 检测并开启swap
if ! swapon --show | grep -q "swap"; then
    RAM_SIZE=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)
    check_error "获取内存大小"

    if [ "$RAM_SIZE" -lt 2048 ]; then
        # RAM 小于 2G，swap 为 1 倍
        SWAP_SIZE=$((RAM_SIZE))
        
        dd if=/dev/zero of=/mnt/swap bs=1M count="$SWAP_SIZE"
        check_error "创建swap文件"
        
        chmod 600 /mnt/swap
        check_error "设置swap文件权限"
        
        mkswap /mnt/swap
        check_error "格式化swap文件"
        
        echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
        check_error "添加swap到fstab"
        
        sed -i '/vm.swappiness/d' /etc/sysctl.conf
        echo "vm.swappiness = 10" >> /etc/sysctl.conf
        check_error "配置swappiness"
        
        sysctl -w vm.swappiness=10
        check_error "应用swappiness设置"
        
        swapon -a
        check_error "启用swap"
    fi
fi

# 执行内核调优
bash -c "$(curl -Ls https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Other/kernel_optimization.sh)"
check_error "执行内核调优"

# 更新软件包并安装必需的软件
dnf update -y
check_error "系统更新"

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
check_error "添加Docker仓库"

dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin bind-utils tuned zram-generator wget util-linux-user
check_error "安装必要软件"

# 启用系统日志持久化
mkdir -p /var/log/journal
check_error "创建日志目录"

systemd-tmpfiles --create --prefix /var/log/journal
check_error "配置日志目录"

echo "Storage=persistent" >> /etc/systemd/journald.conf
check_error "配置持久化日志"

systemctl restart systemd-journald
check_error "重启journald服务"

# 启用并立即启动 Docker 和 Tuned 服务
systemctl enable --now docker
check_error "启用Docker服务"

systemctl enable --now tuned
check_error "启用Tuned服务"

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai
check_error "设置时区"

# 修改SSH端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
check_error "修改SSH端口"

systemctl restart sshd
check_error "重启SSH服务"

# 运行NextTrace安装脚本
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
check_error "安装NextTrace"

# 启用zram
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" | tee /etc/systemd/zram-generator.conf
check_error "配置ZRAM"

# 启动容器
cd /root && docker compose up -d
check_error "启动root目录容器"

cd /root/proxy && docker compose pull && docker compose up -d
check_error "启动proxy容器"

cd /root/vmagent && docker compose pull && docker compose up -d
check_error "启动vmagent容器"

# 添加定时任务
(crontab -l 2>/dev/null; echo "5 0 * * * dnf update -y") | crontab -
check_error "添加定时任务"

# 安装fish
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
