#!/bin/bash

# 脚本版本和重运行检测
SCRIPT_VERSION="1.1"
RERUN_MODE=false
if [ -f "/var/lib/system-deploy-status.json" ]; then
    RERUN_MODE=true
    echo "检测到之前的部署记录，进入更新模式"
fi

# 日志函数 - 增强版
log() { 
    local color="\033[0;32m"  # 默认绿色
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
        "title") color="\033[1;35m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# 步骤管理
step_start() { log "▶ 步骤$1: $2..." "title"; }
step_end() { log "✓ 步骤$1完成: $2" "info"; echo; }
step_fail() { log "✗ 步骤$1失败: $2" "error"; exit 1; }
step_skip() { log "⏭ 步骤$1跳过: $2" "warn"; echo; }

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
run_cmd apt update
if $RERUN_MODE; then
    log "更新模式: 仅更新软件包，不进行完整升级" "info"
    run_cmd apt upgrade -y
else
    log "首次运行: 执行完整系统更新" "info"
    run_cmd apt upgrade -y
fi

PKGS_TO_INSTALL=""
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    if ! dpkg -l | grep -q "^ii\s*$pkg\s"; then
        PKGS_TO_INSTALL="$PKGS_TO_INSTALL $pkg"
    fi
done

if [ -n "$PKGS_TO_INSTALL" ]; then
    log "安装缺少的软件包:$PKGS_TO_INSTALL" "info"
    run_cmd apt install -y $PKGS_TO_INSTALL || step_fail 2 "基础软件安装失败"
else
    log "所有基础软件包已安装" "info"
fi
step_end 2 "系统已更新，基础软件安装成功"

# =================== Fish 安装替换版 ===================
step_start 2.5 "检测并安装最新Fish Shell"

# 检查是否已安装fish
if command -v fish >/dev/null 2>&1; then
    fish_version=$(fish --version | awk '{print $3}')
    log "Fish已安装 (版本: $fish_version)" "info"
else
    log "Fish未安装，开始配置官方源并安装..." "warn"
    FISH_SRC_LIST="/etc/apt/sources.list.d/shells:fish:release:4.list"
    FISH_GPG="/etc/apt/trusted.gpg.d/shells_fish_release_4.gpg"
    FISH_APT_LINE="deb http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_12/ /"
    FISH_KEY_URL="https://download.opensuse.org/repositories/shells:fish:release:4/Debian_12/Release.key"

    # 检查是否已经存在Fish source
    if ! grep -qs "^${FISH_APT_LINE}" "$FISH_SRC_LIST" 2>/dev/null; then
        echo "$FISH_APT_LINE" > "$FISH_SRC_LIST" || step_fail 2.5 "写入fish源失败"
        log "已写入Fish官方APT源" "info"
    else
        log "Fish APT源已存在，跳过写入" "info"
    fi

    # 添加GPG密钥(如没有)
    if [ ! -s "$FISH_GPG" ]; then
        curl -fsSL "$FISH_KEY_URL" | gpg --dearmor > "$FISH_GPG" || step_fail 2.5 "导入Fish GPG密钥失败"
        log "已导入Fish官方GPG密钥" "info"
    else
        log "Fish GPG密钥已存在，跳过导入" "info"
    fi

    # 安装Fish
    run_cmd apt update -y
    run_cmd apt install -y fish || step_fail 2.5 "Fish安装失败"
    log "Fish安装完成" "info"
fi
step_end 2.5 "Fish Shell检测与安装"

# =================== Fish 安装段结束 ===================

# 步骤3: 安装Docker和NextTrace
step_start 3 "安装Docker和NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')

# Docker安装
if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    log "Docker已安装 (版本: $DOCKER_VERSION)" "info"
    if ! systemctl is-active docker &>/dev/null; then
        log "Docker服务未运行，尝试启动..." "warn"
        systemctl start docker
        systemctl enable docker
    fi
    if [ $MEM_TOTAL -lt 1024 ]; then
        if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
            log "低内存环境，应用Docker优化" "warn"
            mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
            systemctl restart docker
        else
            log "Docker低内存优化已应用" "info"
        fi
    fi
else
    log "Docker未检测到，正在安装..." "warn"
    if ! curl -fsSL https://get.docker.com | bash; then
        log "Docker安装失败" "error"
    else
        systemctl enable --now docker
        if [ $MEM_TOTAL -lt 1024 ]; then
            log "低内存环境，应用Docker优化" "warn"
            mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
            systemctl restart docker
        fi
    fi
fi

# NextTrace安装
if command -v nexttrace &>/dev/null; then
    log "NextTrace已安装" "info"
    # 可选：检查更新逻辑
    if $RERUN_MODE; then
        log "检查NextTrace更新..." "info"
        bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
    fi
else
    log "安装NextTrace..." "warn"
    bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)" || log "NextTrace安装失败" "error"
fi
step_end 3 "Docker和NextTrace检查完成"

# 步骤4: 启动容器
step_start 4 "启动容器"
SUCCESSFUL_STARTS=0
TOTAL_CONTAINERS=0
FAILED_DIRS=""
CONTAINER_DIRS=(/root /root/proxy /root/vmagent)

COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi

if [ -z "$COMPOSE_CMD" ]; then
    log "跳过容器启动: 未找到Docker Compose" "warn"
else
    log "检查所有目录的Compose配置..." "warn"
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            COMPOSE_FILE=""
            for file in docker-compose.yml compose.yaml; do
                if [ -f "$dir/$file" ]; then
                    COMPOSE_FILE="$file"
                    break
                fi
            done
            if [ -n "$COMPOSE_FILE" ]; then
                cd "$dir"
                DIR_CONTAINER_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps -q 2>/dev/null | wc -l)
                EXPECTED_CONTAINERS=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services | wc -l)
                TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + EXPECTED_CONTAINERS))
                if [ "$DIR_CONTAINER_COUNT" -eq "$EXPECTED_CONTAINERS" ]; then
                    RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps | grep -i "running" | wc -l)
                    if [ "$RUNNING_COUNT" -eq "$EXPECTED_CONTAINERS" ]; then
                        log "目录 $dir: 所有 $EXPECTED_CONTAINERS 个容器已运行，跳过操作" "info"
                        SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + EXPECTED_CONTAINERS))
                        continue
                    fi
                fi
                log "目录 $dir: 找到 $COMPOSE_FILE，尝试启动容器" "warn"
                if cd "$dir" && $COMPOSE_CMD -f "$COMPOSE_FILE" up -d; then
                    NEW_CONTAINER_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps -q | wc -l)
                    log "✓ 成功启动 $dir 中的容器" "info"
                    SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + NEW_CONTAINER_COUNT))
                else
                    log "✗ 目录 $dir 中容器启动失败" "error"
                    FAILED_DIRS+=" $dir"
                fi
            else
                log "目录 $dir: 未找到Compose文件 (docker-compose.yml/compose.yaml)" "warn"
            fi
        else
            log "目录 $dir 不存在，已跳过" "warn"
        fi
    done
    ACTUAL_RUNNING_CONTAINERS=$(docker ps -q | wc -l)
    log "容器启动结果: 实际运行 $ACTUAL_RUNNING_CONTAINERS 个，处理成功 $SUCCESSFUL_STARTS 个" "warn"
    [ -n "$FAILED_DIRS" ] && log "失败目录: $FAILED_DIRS" "error"
fi
step_end 4 "容器启动检查完成"

# 步骤5: 设置定时任务
step_start 5 "设置定时更新任务"
CRON_CMD="5 0 * * 0 apt update -y > /var/log/auto-update.log 2>&1"
if crontab -l 2>/dev/null | grep -q "apt update"; then
    log "定时更新任务已存在" "info"
else
    if $RERUN_MODE; then
        log "添加缺少的定时更新任务" "warn"
    fi
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    log "已添加每周日凌晨0:05的自动更新任务" "warn"
fi
step_end 5 "定时任务已设置"

# 步骤6: 启用进阶服务
step_start 6 "系统服务优化"
# Tuned 优化：强制profile
if systemctl enable --now tuned; then
    log "✓ Tuned服务启动成功" "info"
    # 检查当前profile
    CURR_PROFILE=$(tuned-adm active | grep 'Current active profile:' | awk -F': ' '{print $2}')
    if [ "$CURR_PROFILE" != "latency-performance" ]; then
        if tuned-adm profile latency-performance; then
            log "Tuned已切换到 latency-performance profile" "warn"
        else
            log "✗ 切换 tuned profile到 latency-performance 失败" "error"
        fi
    else
        log "✓ 当前已是 latency-performance profile" "info"
    fi
else
    log "✗ Tuned服务启动失败" "error"
fi

# Fish shell配置
fish_path=$(which fish)
if [ -n "$fish_path" ]; then
    if ! grep -q "$fish_path" /etc/shells; then
        echo "$fish_path" >> /etc/shells
        log "已将Fish添加到支持的shell列表" "warn"
    else
        log "Fish已在支持的shell列表中" "info"
    fi
    if [ "$SHELL" != "$fish_path" ]; then
        if $RERUN_MODE; then
            log "检测到重新运行，不自动修改默认shell" "warn"
            read -p "是否设置Fish为默认shell? (y/n): " change_shell
            if [ "$change_shell" = "y" ]; then
                if chsh -s "$fish_path"; then
                    log "Fish已设为默认shell，重新登录后生效" "warn"
                else
                    log "Fish设置为默认shell失败" "error"
                fi
            fi
        else
            if chsh -s "$fish_path"; then
                log "Fish已设为默认shell，重新登录后生效" "warn"
            else
                log "Fish设置为默认shell失败" "error"
            fi
        fi
    else
        log "✓ Fish已是默认shell" "info"
    fi
else
    log "✗ Fish未安装成功，无法设置为默认shell" "error"
fi

# 时区
CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [ "$CURRENT_TZ" = "Asia/Shanghai" ]; then
    log "✓ 时区已是上海" "info"
else
    log "设置时区为上海..." "warn"
    if timedatectl set-timezone Asia/Shanghai; then
        log "✓ 时区已设置为上海" "info"
    else
        log "✗ 时区设置失败" "error"
    fi
fi
step_end 6 "系统服务优化完成"

# 步骤7: 网络优化
step_start 7 "网络优化设置"
QDISC_TYPE="fq_codel"  # 只需改这里就切qdisc类型

# 检查内核是否支持BBR
BBR_AVAILABLE=false
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    BBR_AVAILABLE=true
    log "✓ 系统支持BBR" "info"
else
    log "✗ 当前系统没有开启BBR支持，检查原因..." "error"
    if ! lsmod | grep -q "tcp_bbr"; then
        log "尝试加载BBR模块..." "warn"
        modprobe tcp_bbr && \
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf && \
        log "✓ BBR模块加载成功" "info" || \
        log "✗ BBR模块加载失败" "error"
    fi
fi

CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")

if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
    log "✓ BBR和$QDISC_TYPE已配置" "info"
else
    if ! $RERUN_MODE || [ ! -f /etc/sysctl.conf.bak.orig ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d)
        if ! $RERUN_MODE; then
            cp /etc/sysctl.conf /etc/sysctl.conf.bak.orig
        fi
    fi
    BBR_CONFIGURED=false
    QDISC_CONFIGURED=false
    if grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        BBR_CONFIGURED=true
        log "BBR配置已存在" "info"
    fi
    if grep -q "^net.core.default_qdisc=$QDISC_TYPE" /etc/sysctl.conf; then
        QDISC_CONFIGURED=true
        log "$QDISC_TYPE 配置已存在" "info"
    fi
    if ! $BBR_CONFIGURED; then
        if grep -q "^#\s*net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            sed -i 's/^#\s*net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
            log "启用已存在但被注释的BBR配置" "warn"
        else
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            log "添加BBR拥塞控制设置" "warn"
        fi
    fi
    if ! $QDISC_CONFIGURED; then
        if grep -q "^#\s*net.core.default_qdisc=$QDISC_TYPE" /etc/sysctl.conf; then
            sed -i "s/^#\s*net.core.default_qdisc=$QDISC_TYPE/net.core.default_qdisc=$QDISC_TYPE/" /etc/sysctl.conf
            log "启用已存在但被注释的$QDISC_TYPE配置" "warn"
        else
            echo "net.core.default_qdisc=$QDISC_TYPE" >> /etc/sysctl.conf
            log "添加$QDISC_TYPE队列调度设置" "warn"
        fi
    fi
fi

# 应用设置
log "应用网络优化设置..." "warn"
sysctl -p

CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")

if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
    log "✓ BBR和$QDISC_TYPE设置成功" "info"
elif [ "$CURR_CC" = "bbr" ]; then
    log "部分成功: BBR已启用，但$QDISC_TYPE未成功设置($CURR_QDISC)" "warn"
elif [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
    log "部分成功: $QDISC_TYPE已启用，但BBR未成功设置($CURR_CC)" "warn"
else
    log "✗ BBR和$QDISC_TYPE设置均未成功: 当前CC=$CURR_CC, QDISC=$CURR_QDISC" "error"
fi
step_end 7 "网络优化设置完成"

# 步骤8: SSH安全设置
step_start 8 "SSH安全设置"
if ! $RERUN_MODE || [ ! -f /etc/ssh/sshd_config.bak.orig ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)
    if ! $RERUN_MODE; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.orig
    fi
fi

CURRENT_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$CURRENT_SSH_PORT" ]; then
    CURRENT_SSH_PORT=22
fi

log "当前SSH端口为 $CURRENT_SSH_PORT" "warn"

if $RERUN_MODE; then
    read -p "SSH端口是否需要修改? 当前为 $CURRENT_SSH_PORT (y/n): " change_port
else
    read -p "是否需要修改SSH端口? (y/n): " change_port
fi

if [ "$change_port" = "y" ]; then
    read -p "请输入新的SSH端口 [默认9399]: " new_port
    new_port=${new_port:-9399}
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        log "端口无效，使用默认9399" "warn"
        new_port=9399
    fi
    if ss -tuln | grep -q ":$new_port "; then
        log "端口 $new_port 已被使用，请选择其他端口" "error"
        read -p "请输入新的SSH端口: " new_port
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
            log "端口无效，使用默认9399" "warn"
            new_port=9399
        fi
    fi
    sed -i "s/^#\?Port [0-9]*/Port $new_port/" /etc/ssh/sshd_config
    if ! grep -q "^Port $new_port" /etc/ssh/sshd_config; then
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    log "重启SSH服务以应用新端口..." "warn"
    if systemctl restart sshd; then
        log "✓ SSH端口已更改为 $new_port" "info"
    else
        log "✗ SSH重启失败！端口更改可能未生效" "error"
    fi
else
    log "SSH端口保持为当前设置: $CURRENT_SSH_PORT" "warn"
fi
step_end 8 "SSH安全设置完成"

# 步骤9: 系统信息汇总
step_start 9 "系统信息汇总"
log "\n╔═════════════════════════════════╗" "title"
log "║       系统部署完成摘要          ║" "title"
log "╚═════════════════════════════════╝" "title"

show_info() {
    log " • $1: $2" "info"
}

show_info "部署模式" "$(if $RERUN_MODE; then echo "重运行/更新"; else echo "首次运行"; fi)"
show_info "脚本版本" "$SCRIPT_VERSION"
show_info "系统版本" "$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')"
show_info "内核版本" "$(uname -r)"
show_info "CPU核心数" "$(nproc)"
show_info "内存大小" "$(free -h | grep Mem | awk '{print $2}')"
show_info "磁盘使用" "$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"

SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
if [ -z "$SSH_PORT" ]; then
    SSH_PORT="22 (默认)"
fi
show_info "SSH端口" "$SSH_PORT"

show_info "Docker版本" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
show_info "活跃容器数" "$(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"

CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")
show_info "网络优化" "BBR($CURR_CC), Qdisc($CURR_QDISC)"

show_info "时区设置" "$(timedatectl | grep "Time zone" | awk '{print $3}')"
show_info "默认shell" "$SHELL"

# 增加 tuned 的 active profile 展示
TUNED_PROFILE_SUMMARY=$(tuned-adm active | grep 'Current active profile:' | awk -F': ' '{print $2}')
if [ -z "$TUNED_PROFILE_SUMMARY" ]; then
    TUNED_PROFILE_SUMMARY="(未检测到)"
fi
show_info "Tuned Profile" "$TUNED_PROFILE_SUMMARY"

if [ "$SUCCESSFUL_STARTS" -gt 0 ]; then
    show_info "容器启动" "成功启动 $SUCCESSFUL_STARTS 个"
else
    log " • 容器启动: 没有容器被启动" "error"
fi

if [ -n "$FAILED_DIRS" ]; then
    log " • 启动失败目录: $FAILED_DIRS" "error"
fi

log "\n──────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S')" "info"
log "──────────────────────────────────\n" "title"
step_end 9 "系统信息汇总完成"

# 保存状态以支持重新运行
echo '{
  "script_version": "'$SCRIPT_VERSION'",
  "last_run": "'$(date '+%Y-%m-%d %H:%M:%S')'",
  "ssh_port": "'$SSH_PORT'",
  "system": "Debian '$(cat /etc/debian_version)'",
  "container_status": {
    "successful": '$SUCCESSFUL_STARTS',
    "failed_dirs": "'$FAILED_DIRS'"
  }
}' > /var/lib/system-deploy-status.json

# 最后的提示
log "✅ 所有配置步骤已执行完毕！" "title"
if [ "$change_port" = "y" ]; then
    log "⚠️  重要提示: 请使用新SSH端口 $new_port 连接服务器" "warn"
    log "   示例: ssh -p $new_port 用户名@服务器IP" "warn"
fi
if $RERUN_MODE; then
    log "📝 这是脚本的重复运行，已更新或跳过已配置项目" "info"
else
    log "🎉 初始部署完成！下次运行会自动进入更新模式" "info"
fi

log "🔄 可随时重新运行此脚本进行维护或更新" "info"
