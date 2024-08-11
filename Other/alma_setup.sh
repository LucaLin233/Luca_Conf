#!/bin/bash

# 更新软件包
dnf update -y

# 安装Docker和Docker Compose
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai

# 修改SSH端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd

# 运行NextTrace安装脚本
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 设置BBR+FQ
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 安装dnsutils
dnf install -y bind-utils

echo "所有任务完成！"
