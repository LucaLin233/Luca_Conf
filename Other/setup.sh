#!/bin/bash

# 检测并安装所需的指令
check_and_install() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 未安装，正在安装..."
        apt-get install -y $1
    else
        echo "$1 已安装，跳过安装。"
    fi
}

# 更新系统
echo "更新系统..."
apt-get update && apt-get full-upgrade -y

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install dnsutils

# 安装 Docker
echo "安装 Docker..."
wget -qO- https://get.docker.com | bash -s docker

# 开启 TCP Fast Open (TFO)
echo "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 内核调优
echo "进行内核调优..."
wget https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Other/kernel_optimization.sh
chmod +x kernel_optimization.sh
bash kernel_optimization.sh

# 设置时区
echo "设置时区为 Asia/Shanghai..."
sudo timedatectl set-timezone Asia/Shanghai

# 路由测试工具
echo "安装路由测试工具 nexttrace..."
bash -c "$(wget -qO- https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 开启 tuned 并设置网络性能优化
echo "开启 tuned 并设置网络性能优化配置..."
check_and_install tuned
systemctl enable tuned.service
systemctl start tuned.service
tuned-adm profile network-throughput

# 在 /root 目录下创建 kernel 文件夹并进入
echo "创建 /root/kernel 目录并进入..."
mkdir -p /root/kernel
cd /root/kernel

# 下载和安装内核包
echo "下载内核包..."
wget -q -O - https://api.github.com/repos/love4taylor/linux-self-use-deb/releases/latest | \
    jq -r '.assets[] | select(.name | contains ("deb")) | select(.name | contains ("cloud")) | .browser_download_url' | \
    xargs wget -q --show-progress

# 安装内核包
echo "安装内核包..."
dpkg -i linux-headers-*-egoist-cloud_*.deb
dpkg -i linux-image-*-egoist-cloud_*.deb

# 修改 SSH 端口为 9399
echo "修改 SSH 端口为 9399..."
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd

# 安装 Node.js 19.x
echo "安装 Node.js 19.x..."
curl -fsSL https://deb.nodesource.com/setup_19.x | bash -
apt-get install -y nodejs

echo "所有步骤完成！"
