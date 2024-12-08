#!/bin/bash

# 检测并开启swap
if ! swapon --show | grep -q "swap"; then
    RAM_SIZE=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)

    if [ "$RAM_SIZE" -lt 1024 ]; then
        # RAM 小于 1G，swap 为 3 倍
        SWAP_SIZE=$((RAM_SIZE * 3))
    else
        # RAM 大于 1G，swap 为 2 倍
        SWAP_SIZE=$((RAM_SIZE * 2))
    fi

    dd if=/dev/zero of=/mnt/swap bs=1M count="$SWAP_SIZE"
    chmod 600 /mnt/swap
    mkswap /mnt/swap
    echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    echo "vm.swappiness = 25" >> /etc/sysctl.conf
    sysctl -w vm.swappiness=25
    swapon -a
fi

# 更新软件包并安装必需的软件
dnf update -y
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin bind-utils tuned zram-generator wget util-linux-user

# 启用并立即启动 Docker 和 Tuned 服务
systemctl enable --now docker
systemctl enable --now tuned

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai

# 修改SSH端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd

# 运行NextTrace安装脚本
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 启用zram
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" | tee /etc/systemd/zram-generator.conf

# 启动dnsproxy并替换系统dns
cd /root/dnsproxy && docker compose pull && docker compose up -d
bash <(curl -L -s https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/dns-change.sh) 127.0.0.1

# 启动proxy
cd /root/proxy && docker compose pull && docker compose up -d

# 启动其他容器
cd /root/plmxs && docker compose pull && docker compose up -d

# 执行内核调优
bash -c "$(curl -Ls https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Other/kernel_optimization.sh)"

# 添加定时任务
(crontab -l 2>/dev/null; echo "1 0 * * * /usr/bin/python3 /root/dnsproxy/rule.py") | crontab -
(crontab -l 2>/dev/null; echo "5 0 * * * dnf update -y") | crontab -

# 安装fish
cd /etc/yum.repos.d/
wget https://download.opensuse.org/repositories/shells:fish:release:3/CentOS-9_Stream/shells:fish:release:3.repo
dnf install fish -y
echo /usr/local/bin/fish | sudo tee -a /etc/shells
chsh -s $(which fish)

echo "所有任务完成！请重新连接 SSH 以启用 fish shell。"
