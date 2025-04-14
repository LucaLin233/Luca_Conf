#!/bin/bash

# 日志函数
log() { local color="\033[0;32m"; [[ "$2" == "warn" ]] && color="\033[0;33m"; [[ "$2" == "error" ]] && color="\033[0;31m"; echo -e "${color}$1\033[0m"; }

# 步骤管理
step_start() { log "步骤$1: $2..." "info"; }
step_end() { log "步骤$1完成: $2" "warn"; }
step_fail() { log "步骤$1失败: $2" "error"; exit 1; }

# 命令执行器
run_cmd() {
    "$@"
    if [ $? -ne 0 ] && [ "$1" != "sysctl" ]; then
        log "错误: 执行 '$*' 失败" "error"
        return 1
    fi
    return 0
}

# 检查是否为root
if [ "$(id -u)" != "0" ]; then
    log "此脚本必须以root用户运行" "error"
    exit 1
fi

# 检查系统版本
if [ ! -f /etc/debian_version ]; then
    log "此脚本仅适用于Debian系统" "error"
    exit 1
fi

debian_version=$(cat /etc/debian_version | cut -d. -f1)
if [ "$debian_version" -lt 12 ]; then
    log "警告: 此脚本为Debian 12优化，当前版本 $(cat /etc/debian_version)" "warn"
    read -p "是否继续? (y/n): " continue_install
    [ "$continue_install" != "y" ] && exit 1
fi

# 步骤1: 网络检查
step_start 1 "网络连通性测试"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络连接不稳定，这可能影响安装过程" "warn"
    read -p "是否继续? (y/n): " continue_install
    [ "$continue_install" != "y" ] && exit 1
fi

# 检查基础工具
for cmd in curl wget apt; do
    if ! command -v $cmd &>/dev/null; then
        log "安装必要工具: $cmd" "warn"
        apt-get update -qq && apt-get install -y -qq $cmd || { log "安装 $cmd 失败" "error"; exit 1; }
    fi
done
step_end 1 "网络正常，必要工具已就绪"

# 步骤2: 系统更新与安装
step_start 2 "更新系统并安装基础软件"
run_cmd apt update && run_cmd apt upgrade -y && \
run_cmd apt install -y dnsutils wget curl rsync chrony cron fish tuned || step_fail 2 "基础软件安装失败"
step_end 2 "系统已更新，基础软件安装成功"

# 步骤3: 安装Docker和NextTrace
step_start 3 "安装Docker和NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')

# Docker安装
if ! command -v docker &>/dev/null; then
    log "Docker未检测到，正在安装..." "warn"
    if ! curl -fsSL https://get.docker.com | bash; then
        log "Docker安装失败" "error"
    else
        systemctl enable --now docker
    
        # 低内存优化
        if [ $MEM_TOTAL -lt 1024 ]; then
            log "低内存环境，应用Docker优化" "warn"
            mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
            systemctl restart docker
        fi
    fi
elif [ $MEM_TOTAL -lt 1024 ]; then
    # 检查已有Docker是否需要优化
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        log "低内存环境，应用Docker优化" "warn"
        mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
        systemctl restart docker
    fi
fi

# NextTrace安装
if ! command -v nexttrace &>/dev/null; then
    log "安装NextTrace..." "warn"
    bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)" || log "NextTrace安装失败" "error"
fi
step_end 3 "Docker和NextTrace检查完成"

# 步骤4: 启动容器
step_start 4 "启动容器"
SUCCESSFUL_STARTS=0
FAILED_DIRS=""
CONTAINER_DIRS=(/root /root/proxy /root/vmagent)

# 检测compose命令
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi

if [ -z "$COMPOSE_CMD" ]; then
    log "跳过容器启动: 未找到Docker Compose" "warn"
else
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            # 检查compose文件
            COMPOSE_FILE=""
            for file in docker-compose.yml compose.yaml; do
                if [ -f "$dir/$file" ]; then
                    COMPOSE_FILE="$file"
                    break
                fi
            done
            
            if [ -n "$COMPOSE_FILE" ]; then
                log "正在启动 $dir 中的容器..." "warn"
                if cd "$dir" && $COMPOSE_CMD -f "$COMPOSE_FILE" up -d; then
                    SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + 1))
                else
                    FAILED_DIRS+=" $dir"
                fi
            else
                log "目录 $dir 中无Compose文件" "warn"
            fi
        fi
    done
    log "成功启动容器: $SUCCESSFUL_STARTS 个" "warn"
fi
step_end 4 "容器启动检查完成"

# 步骤5: 设置定时任务
step_start 5 "设置定时更新任务"
CRON_CMD="5 0 * * 0 apt update && apt upgrade -y > /var/log/auto-update.log 2>&1"
if ! (crontab -l 2>/dev/null | grep -q "apt update && apt upgrade"); then
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    log "已添加每周日凌晨0:05的自动更新任务" "warn" 
fi
step_end 5 "定时任务已设置"

# 步骤6: 启用进阶服务
step_start 6 "系统服务优化"
# Tuned
if ! systemctl is-active tuned &>/dev/null; then
    systemctl enable --now tuned
    log "tuned服务已启用" "warn"
fi

# Fish
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    if ! grep -q "$fish_path" /etc/shells; then
        echo "$fish_path" >> /etc/shells
    fi
    
    if [ "$SHELL" != "$fish_path" ]; then
        chsh -s "$fish_path"
        log "Fish设为默认shell，重新登录后生效" "warn"
    fi
fi

# 时区
timedatectl set-timezone Asia/Shanghai
log "时区已设置为上海" "warn"
step_end 6 "系统服务优化完成"

# 步骤7: 网络优化
step_start 7 "网络优化设置"
# 检查内核是否支持BBR
if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    log "当前系统不支持BBR" "warn"
else
    # 备份配置
    cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d)
    
    # 配置网络优化
    if ! grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    
    # 应用设置
    sysctl -p
    
    # 验证
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    CURR_QDISC=$(sysctl -n net.core.default_qdisc)
    
    if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "fq" ]; then
        log "BBR和FQ设置成功" "warn"
    else
        log "BBR/FQ设置可能不完整: $CURR_CC/$CURR_QDISC" "warn"
    fi
fi
step_end 7 "网络优化设置完成"

# 步骤8: SSH安全设置
step_start 8 "SSH安全设置"
# 备份配置
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)

# 获取当前端口
CURRENT_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=22
fi

read -p "当前SSH端口为 $CURRENT_SSH_PORT, 是否修改? (y/n): " change_port
if [ "$change_port" = "y" ]; then
    read -p "请输入新的SSH端口 [默认9399]: " new_port
    new_port=${new_port:-9399}
    
    # 验证端口
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        log "端口无效，使用默认9399" "warn"
        new_port=9399
    fi
    
    # 检查端口是否被占用
    if ss -tuln | grep -q ":$new_port "; then
        log "端口 $new_port 已被使用，请选择其他端口" "error"
        read -p "请输入新的SSH端口: " new_port
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
            log "端口无效，使用默认9399" "warn"
            new_port=9399
        fi
    fi
    
    # 修改配置
    sed -i "s/^#\?Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    if ! grep -q "^Port $new_port" /etc/ssh/sshd_config; then
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    
    # 重启服务
    run_cmd systemctl restart sshd
    log "SSH端口已更改为 $new_port，请使用新端口连接" "warn"
else
    log "SSH端口未修改，保持 $CURRENT_SSH_PORT" "warn"
fi
step_end 8 "SSH安全设置完成"

# 步骤9: 系统信息汇总
step_start 9 "系统信息汇总"
log "====== 系统部署完成 =======" "warn"
{
    echo "系统版本: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')"
    echo "内核版本: $(uname -r)"
    echo "CPU核心: $(nproc)"
    echo "内存大小: $(free -h | grep Mem | awk '{print $2}')"
    echo "磁盘使用: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    echo "SSH端口: $(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1 || echo "22 (默认)")"
    echo "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
    echo "容器数量: $(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"
    echo "网络优化: BBR($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")), FQ($(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置"))"
    echo "时区: $(timedatectl | grep "Time zone" | awk '{print $3}')"
    echo "默认Shell: $SHELL"
    [ -n "$FAILED_DIRS" ] && echo "警告: 下列容器启动失败: $FAILED_DIRS"
} | while read line; do log "$line" "warn"; done
log "=============================" "warn"
step_end 9 "系统信息汇总完成"

log "\n所有步骤已执行完毕！" "warn"
if [ "$change_port" = "y" ]; then
    log "重要提示: 请使用新SSH端口 $new_port 连接服务器" "warn"
    log "示例: ssh -p $new_port user@your-server-ip" "warn"
fi
