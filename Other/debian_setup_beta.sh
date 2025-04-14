#!/bin/bash

# 彩色输出函数
green() { echo -e "\033[32m$1\033[0m"; }  # 绿色用于步骤公告
yellow() { echo -e "\033[33m$1\033[0m"; }  # 黄色用于结果消息
red() { echo -e "\033[31m$1\033[0m"; }     # 红色用于错误

# 错误处理函数
check_error() {
    if [ $? -ne 0 ]; then
        red "错误: $1 执行失败"
        exit 1
    fi
}

# 命令执行封装 (修正版)
run_cmd() {
    "$@"
    local status=$?
    if [ $status -ne 0 ] && [ "$1" != "sysctl" ]; then
        check_error "$*"
    fi
    return $status
}

# SWAP设置函数 (增加错误恢复机制)
setup_swap() {
    green "创建1G SWAP文件..."
    run_cmd dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    if [ $? -ne 0 ]; then
        red "SWAP创建失败，清理残留文件..."
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
        return 1
    fi
    
    run_cmd chmod 600 /swapfile
    run_cmd mkswap /swapfile
    run_cmd swapon /swapfile
    
    if [ $? -ne 0 ]; then
        red "SWAP启用失败，清理残留文件..."
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
        return 1
    fi
    
    if ! grep -q "^/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 步骤0: 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    red "此脚本必须以root用户运行"
    exit 1
fi

# 添加网络连通性检测
green "初始检查: 网络连通性测试..."
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    red "警告: 网络连接不稳定，这可能影响安装过程"
    read -p "是否继续? (y/n): " continue_install
    [ "$continue_install" != "y" ] && exit 1
fi
yellow "网络连接正常，继续安装..."

# 检查依赖组件
green "初始检查: 验证必要组件..."
for cmd in curl wget apt; do
    if ! command -v $cmd &>/dev/null; then
        red "缺少必要组件: $cmd 未找到，尝试安装..."
        apt-get update && apt-get install -y $cmd || { red "安装 $cmd 失败，请手动安装后重试"; exit 1; }
    fi
done
yellow "所有必要组件已就绪..."

# 步骤1: 更新系统并安装所有基础软件
green "步骤1: 更新系统并安装基础软件..."
yellow "开始执行更新和安装..."
run_cmd apt update
run_cmd apt upgrade -y
run_cmd apt install -y dnsutils wget curl rsync chrony cron fish tuned
yellow "步骤1完成: 更新和安装成功。"

# 步骤2: 内存检查和SWAP设置
green "步骤2: 检查内存和SWAP..."
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

# 改进: 只在内存小于2G且SWAP小于100M时创建SWAP
if [ $MEM_TOTAL -lt 2048 ] && [ $SWAP_TOTAL -lt 100 ]; then
    yellow "内存小于2G且SWAP不足，创建1G SWAP..."
    setup_swap
    if [ $? -eq 0 ]; then
        yellow "步骤2完成: SWAP设置已应用。"
    else
        red "步骤2警告: SWAP设置失败，但将继续执行后续步骤。"
    fi
else
    yellow "内存配置满足要求或SWAP已存在，跳过SWAP设置。"
fi
yellow "步骤2完成: 内存检查结束。"

# 步骤3: 检查并安装Docker和NextTrace
green "步骤3: 检查并安装Docker和NextTrace..."
if ! command -v docker &>/dev/null; then
    yellow "Docker未检测到，正在安装..."
    run_cmd curl -fsSL https://get.docker.com | bash
    run_cmd systemctl enable --now docker
    
    # 添加低内存优化
    if [ $MEM_TOTAL -lt 1024 ]; then
        yellow "检测到低内存环境，应用Docker内存优化..."
        mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
        systemctl restart docker
    fi
    
    yellow "Docker安装完成。"
else
    yellow "Docker已安装，跳过安装步骤。"
    
    # 即使Docker已安装，也检查是否需要低内存优化
    if [ $MEM_TOTAL -lt 1024 ]; then
        if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
            yellow "检测到低内存环境，应用Docker内存优化..."
            mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
            systemctl restart docker
        fi
    fi
fi

if ! command -v nexttrace &>/dev/null; then
    yellow "NextTrace未检测到，正在安装..."
    run_cmd bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
    yellow "NextTrace安装完成。"
else
    yellow "NextTrace已安装，跳过安装步骤。"
fi
yellow "步骤3完成: Docker和NextTrace检查结束。"

# 步骤4: 启动容器 (改进版 - 修正了多compose文件处理)
green "步骤4: 启动容器..."
SUCCESSFUL_STARTS=0
FAILED_DIRS=""

# 使用数组存储目录列表
CONTAINER_DIRS=(/root /root/proxy /root/vmagent)

# 首先检测可用的 compose 命令
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    red "未检测到 docker-compose 或 docker compose 命令，跳过容器启动"
    COMPOSE_CMD=""
fi

if [ -n "$COMPOSE_CMD" ]; then
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            yellow "检查目录 $dir 中的容器..."
            
            # 优先查找 docker-compose.yml，其次是 compose.yaml
            COMPOSE_FILE=""
            if [ -f "$dir/docker-compose.yml" ]; then
                COMPOSE_FILE="docker-compose.yml"
            elif [ -f "$dir/compose.yaml" ]; then
                COMPOSE_FILE="compose.yaml"
            fi
            
            if [ -n "$COMPOSE_FILE" ]; then
                yellow "检测到Compose文件 $COMPOSE_FILE，正在尝试启动目录 $dir 中的容器..."
                if cd "$dir" && $COMPOSE_CMD -f "$COMPOSE_FILE" up -d; then
                    yellow "成功启动容器在 $dir"
                    SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + 1))
                else
                    red "错误: 在 $dir 中启动容器失败！请检查Docker配置或文件。"
                    FAILED_DIRS="$FAILED_DIRS $dir"
                fi
            else
                red "错误: 在 $dir 中未找到有效的Docker Compose文件 (如 docker-compose.yml 或 compose.yaml)！"
                FAILED_DIRS="$FAILED_DIRS $dir"
            fi
        else
            yellow "目录 $dir 不存在，跳过容器启动。"
        fi
    done
    yellow "步骤4完成: 容器启动检查结束。成功启动: $SUCCESSFUL_STARTS 个。"
else
    yellow "步骤4跳过: 未找到 Docker Compose 工具。"
fi

# 步骤5: 设置定时更新任务
green "步骤5: 设置定时更新任务..."
CRON_CMD="5 0 * * 0 apt update && apt upgrade -y > /var/log/auto-update.log 2>&1"
if ! (crontab -l 2>/dev/null | grep -q "apt update && apt upgrade"); then
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    yellow "已添加每周日凌晨0:05的自动更新任务"
else
    yellow "自动更新任务已存在，跳过设置"
fi
yellow "步骤5完成: 定时任务设置结束。"

# 步骤6: 启用tuned服务
green "步骤6: 启用tuned服务..."
if ! systemctl is-active tuned &>/dev/null; then
    run_cmd systemctl enable --now tuned
    yellow "tuned服务已启用"
else
    yellow "tuned服务已在运行"
fi
yellow "步骤6完成: tuned服务状态更新。"

# 步骤7: 设置Fish为默认shell
green "步骤7: 设置Fish为默认shell..."
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    if ! grep -q "$fish_path" /etc/shells; then
        echo "$fish_path" >> /etc/shells
    fi
    
    if [ "$SHELL" != "$fish_path" ]; then
        run_cmd chsh -s "$fish_path"
        yellow "Fish已成功设置为默认shell，重新登录后生效"
    else
        yellow "Fish已是默认shell，无需修改"
    fi
else
    red "Fish未成功安装，跳过设置默认shell"
fi
yellow "步骤7完成: Fish shell设置结束。"

# 步骤8: 设置时区
green "步骤8: 设置系统时区为上海..."
run_cmd timedatectl set-timezone Asia/Shanghai
yellow "时区已成功设置为上海"
yellow "步骤8完成: 时区设置结束。"

# 步骤9: 设置BBR和FQ (新增步骤)
green "步骤9: 检查并设置BBR和FQ..."
BBR_ENABLED=0
FQ_ENABLED=0

# 检查是否已启用BBR
if grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    BBR_ENABLED=1
fi

# 检查是否已启用FQ
if grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
    FQ_ENABLED=1
fi

if [ $BBR_ENABLED -eq 0 ] || [ $FQ_ENABLED -eq 0 ]; then
    yellow "BBR或FQ未完全配置，正在设置..."
    
    # 备份配置文件
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    
    # 添加BBR配置
    if [ $BBR_ENABLED -eq 0 ]; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    # 添加FQ配置
    if [ $FQ_ENABLED -eq 0 ]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    
    # 应用修改
    sysctl -p
    
    # 验证设置结果
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    CURR_QDISC=$(sysctl -n net.core.default_qdisc)
    
    if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "fq" ]; then
        yellow "BBR和FQ设置成功！"
    else
        yellow "警告: BBR或FQ设置可能不完整。当前设置:"
        yellow "- 拥塞控制算法: $CURR_CC (应为bbr)"
        yellow "- 默认队列调度: $CURR_QDISC (应为fq)"
    fi
else
    yellow "BBR和FQ已配置，无需修改"
fi
yellow "步骤9完成: BBR和FQ检查与设置结束。"

# 步骤10: 修改SSH端口 (改进版，允许自定义端口)
green "步骤10: 修改SSH端口..."
# 备份SSH配置文件 (移到这里更合理)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

CURRENT_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=22
fi

read -p "当前SSH端口为 $CURRENT_SSH_PORT, 是否需要修改? (y/n): " change_port
if [ "$change_port" = "y" ]; then
    read -p "请输入新的SSH端口 [默认9399]: " new_port
    new_port=${new_port:-9399}  # 如果用户未输入，默认使用9399
    
    # 检查端口是否为有效数字且在合理范围内
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        red "无效端口号! 使用默认端口9399"
        new_port=9399
    fi
    
    # 修改SSH配置
    sed -i "s/^#\?Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    if ! grep -q "^Port $new_port" /etc/ssh/sshd_config; then
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    
    run_cmd systemctl restart sshd
    yellow "SSH端口已更改为 $new_port，请使用新端口连接"
else
    yellow "SSH端口修改已取消，保持原端口 $CURRENT_SSH_PORT"
fi
yellow "步骤10完成: SSH端口修改结束。"

# 步骤11: 系统信息汇总
green "步骤11: 系统信息汇总"
yellow "====== 部署完成，系统信息汇总 ======="
yellow "系统版本: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')"
yellow "内核版本: $(uname -r)"
yellow "CPU核心数: $(nproc)"
yellow "内存情况: $(free -h | grep Mem | awk '{print $2}')"
yellow "SWAP情况: $(free -h | grep Swap | awk '{print $2}')"
yellow "磁盘使用: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
if [ -z "$SSH_PORT" ]; then
    SSH_PORT="22 (默认)"
fi
yellow "SSH端口: $SSH_PORT"
yellow "Docker版本: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
yellow "活跃容器数: $(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"

# 显示BBR和FQ状态
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")
yellow "网络优化: BBR($CURR_CC), FQ($CURR_QDISC)"

if [ -n "$FAILED_DIRS" ]; then
    red "警告: 以下目录中的容器未成功启动: $FAILED_DIRS！请检查并手动修复。"
fi

yellow "时区设置: $(timedatectl | grep "Time zone" | awk '{print $3}')"
yellow "默认shell: $SHELL"
yellow "========================================="
yellow "步骤11完成: 汇总信息已显示。"

yellow "\n所有步骤已成功完成！"
if [ "$change_port" = "y" ]; then
    yellow "提示: SSH端口已更改为 $new_port, 请使用新端口连接"
fi
