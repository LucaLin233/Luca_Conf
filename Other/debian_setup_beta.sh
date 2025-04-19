#!/bin/bash
# ---------------------------------------------------------
# 系统一键部署与优化脚本（增强极简&实用版）
# 适用环境：Debian 12（兼容低版本但提示）
# 功能涵盖：基础环境、官方Fish Shell、Docker、NextTrace、网络优化、SSH安全、定时更新等
# 幂等重复执行、配置备份（仅首份）、可选Bbr优化、端口安全增强
# 作者：LucaLin233 & 优化 - Linux AI Buddy
# ---------------------------------------------------------

SCRIPT_VERSION="1.2"

# 全局常量
STATUS_FILE="/var/lib/system-deploy-status.json"
FISH_SRC_LIST="/etc/apt/sources.list.d/shells:fish:release:4.list"
FISH_GPG="/usr/share/keyrings/fish.gpg"
FISH_APT_LINE="deb [signed-by=$FISH_GPG] http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_12/ /"
FISH_KEY_URL="https://download.opensuse.org/repositories/shells:fish:release:4/Debian_12/Release.key"
CONTAINER_DIRS=(/root /root/proxy /root/vmagent)

# ---------------- 日志显示函数 ----------------------
log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
        "title") color="\033[1;35m" ;;
    esac
    echo -e "${color}$1\033[0m"
}
step_start() { log "▶ 步骤$1: $2..." "title"; }
step_end() { log "✓ 步骤$1完成: $2" "info"; echo; }
step_fail() { log "✗ 步骤$1失败: $2" "error"; exit 1; }
run_cmd() {
    "$@"
    if [ $? -ne 0 ] && [ "$1" != "sysctl" ]; then
        log "错误: 执行 '$*' 失败" "error"
        return 1
    fi
    return 0
}

# 幂等检测
RERUN_MODE=false
if [ -f "$STATUS_FILE" ]; then
    RERUN_MODE=true
    echo "检测到之前的部署记录，进入更新模式"
fi

# 必须以root身份运行
if [ "$(id -u)" != "0" ]; then
    log "此脚本必须以root用户运行" "error"; exit 1
fi

# 系统版本检测
if [ ! -f /etc/debian_version ]; then
    log "此脚本仅适用于Debian系统" "error"; exit 1
fi
debian_version=$(cut -d. -f1 < /etc/debian_version)
if [ "$debian_version" -lt 12 ]; then
    log "警告: 此脚本为Debian 12优化，当前版本 $(cat /etc/debian_version)" "warn"
    read -p "是否继续? (y/n): " continue_install
    [ "$continue_install" != "y" ] && exit 1
fi

# 步骤1 — 网络与基础工具
step_start 1 "检测网络与基础工具"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络连接不稳定，这可能影响安装过程" "warn"
    read -p "是否继续? (y/n): " continue_install
    [ "$continue_install" != "y" ] && exit 1
fi
for cmd in curl wget apt; do
    if ! command -v $cmd &>/dev/null; then
        log "安装必要工具: $cmd" "warn"
        apt-get update -qq && apt-get install -y -qq $cmd || { log "安装 $cmd 失败" "error"; exit 1; }
    fi
done
step_end 1 "网络与必要工具可用"

# 步骤2 — 系统更新与基础组件
step_start 2 "系统更新与组件安装"
run_cmd apt update
if $RERUN_MODE; then
    log "更新模式: 仅更新软件包（不dist-upgrade）" "info"
    run_cmd apt upgrade -y
else
    log "首次运行: 执行完整系统升级" "info"
    run_cmd apt upgrade -y
fi
# 包待安装数组
PKGS_TO_INSTALL=()
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    dpkg -l | grep -q "^ii\s*$pkg\s" || PKGS_TO_INSTALL+=($pkg)
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的软件包:${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}" || step_fail 2 "基础软件安装失败"
else
    log "所有基础软件包已安装!" "info"
fi
# 主机名到hosts
HNAME=$(hostname)
if grep -q "^127.0.1.1" /etc/hosts; then
    grep "^127.0.1.1" /etc/hosts | grep -wq "$HNAME" || {
        cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d)
        sed -i "/^127.0.1.1/ s/\$/ $HNAME/" /etc/hosts
        log "已将主机名 $HNAME 添加进现有 127.0.1.1 行" "warn"
    }
else
    echo "127.0.1.1 $HNAME" >> /etc/hosts
    log "已追加主机名 $HNAME 到 /etc/hosts" "warn"
fi
step_end 2 "系统更新与基础组件已就绪"

# 步骤2.5 — Fish Shell 官方最新版安装
step_start 2.5 "Fish Shell官方安装"
if ! command -v fish >/dev/null 2>&1; then
    log "Fish未安装，将配置官方源并自动安装…" "warn"
    echo "$FISH_APT_LINE" > "$FISH_SRC_LIST" || step_fail 2.5 "写入Fish源失败"
    log "已写入Fish官方APT源，并指定keyring" "info"
    if [ ! -s "$FISH_GPG" ]; then
        curl -fsSL "$FISH_KEY_URL" | gpg --dearmor -o "$FISH_GPG" || step_fail 2.5 "导入Fish GPG密钥失败"
        log "已导入Fish官方GPG密钥" "info"
    else
        log "Fish GPG密钥已存在，跳过导入" "info"
    fi
    run_cmd apt update
    run_cmd apt install -y fish || step_fail 2.5 "Fish安装失败"
    log "Fish安装完成" "info"
else
    fish_version=$(fish --version | awk '{print $3}')
    log "Fish已安装 (版本: $fish_version)" "info"
fi
step_end 2.5 "Fish Shell官方版已安装"

# 步骤3 — Docker与NextTrace
step_start 3 "安装Docker与NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
if ! command -v docker &>/dev/null; then
    log "Docker未检测到，自动安装…" "warn"
    if ! curl -fsSL https://get.docker.com | bash; then
        log "Docker安装失败" "error"
    else
        systemctl enable --now docker
    fi
fi
DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "")
if [ -n "$DOCKER_VERSION" ]; then
    log "Docker已安装 (版本: $DOCKER_VERSION)" "info"
    systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }
    if [ $MEM_TOTAL -lt 1024 ]; then
        if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
            log "低内存环境，优化Docker日志" "warn"
            mkdir -p /etc/docker
            echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
            systemctl restart docker
        fi
    fi
fi
# NextTrace自动装/更新
if command -v nexttrace &>/dev/null; then
    log "NextTrace已安装" "info"
    $RERUN_MODE && bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
else
    log "NextTrace未安装，正在部署…" "warn"
    bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)" || log "NextTrace安装失败" "error"
fi
step_end 3 "Docker与NextTrace部署完成"

# 步骤4 — Docker Compose容器自动启动
step_start 4 "检查并启动Docker Compose容器"
SUCCESSFUL_STARTS=0
FAILED_DIRS=""
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi
if [ -z "$COMPOSE_CMD" ]; then
    log "未检测到Docker Compose，跳过容器启动" "warn"
else
    for dir in "${CONTAINER_DIRS[@]}"; do
        [ -d "$dir" ] || { log "目录 $dir 不存在，已跳过" "warn"; continue; }
        COMPOSE_FILE=""
        for file in docker-compose.yml compose.yaml; do
            [ -f "$dir/$file" ] && COMPOSE_FILE="$file" && break
        done
        if [ -n "$COMPOSE_FILE" ]; then
            cd "$dir"
            DIR_CONTAINER_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps -q 2>/dev/null | wc -l)
            EXPECTED_CONTAINERS=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services | wc -l)
            if [ "$DIR_CONTAINER_COUNT" -eq "$EXPECTED_CONTAINERS" ]; then
                RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps | grep -i "running" | wc -l)
                if [ "$RUNNING_COUNT" -eq "$EXPECTED_CONTAINERS" ]; then
                    log "目录 $dir: $EXPECTED_CONTAINERS 个容器均已运行，跳过" "info"
                    SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + EXPECTED_CONTAINERS))
                    continue
                fi
            fi
            log "目录 $dir: 启动/重启Compose容器…" "warn"
            if $COMPOSE_CMD -f "$COMPOSE_FILE" up -d; then
                NEW_CONTAINER_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps -q | wc -l)
                log "成功启动 $dir ($NEW_CONTAINER_COUNT 容器)" "info"
                SUCCESSFUL_STARTS=$((SUCCESSFUL_STARTS + NEW_CONTAINER_COUNT))
            else
                log "目录 $dir 启动失败" "error"
                FAILED_DIRS+=" $dir"
            fi
        else
            log "目录 $dir: 未找到Compose文件" "warn"
        fi
    done
    ACTUAL_RUNNING_CONTAINERS=$(docker ps -q | wc -l)
    log "容器检查: 实际运行 $ACTUAL_RUNNING_CONTAINERS 个, 本轮启动 $SUCCESSFUL_STARTS 个" "warn"
    [ -n "$FAILED_DIRS" ] && log "启动失败目录: $FAILED_DIRS" "error"
fi
step_end 4 "Docker Compose容器检查完成"

# 步骤5 — 定时任务管理
step_start 5 "添加每周自动系统升级任务"
CRON_CMD="5 0 * * 0 apt update -y && apt upgrade -y > /var/log/auto-update.log 2>&1"
if crontab -l 2>/dev/null | grep -q "apt upgrade"; then
    log "定时升级任务已存在" "info"
else
    (crontab -l 2>/dev/null || echo "") | { cat; echo "$CRON_CMD"; } | crontab -
    log "已添加每周日0:05自动系统升级任务" "warn"
fi
step_end 5 "定时维护任务配置完成"

# 步骤6 — 服务与性能优化
step_start 6 "服务与性能优化"
if systemctl enable --now tuned; then
    log "Tuned服务已启动" "info"
else
    log "Tuned服务启动失败" "error"
fi
fish_path=$(command -v fish)
if [ -n "$fish_path" ]; then
    grep -q "$fish_path" /etc/shells || {
        echo "$fish_path" >> /etc/shells
        log "已将Fish添加到shell列表" "warn"
    }
    if [ "$SHELL" != "$fish_path" ]; then
        if $RERUN_MODE; then
            log "重复执行默认不自动变更shell" "warn"
            read -p "是否设置Fish为默认shell? (y/n): " change_shell
            [ "$change_shell" = "y" ] && chsh -s "$fish_path" && log "Fish已设为默认shell(需重登录)" "warn"
        else
            chsh -s "$fish_path" && log "Fish已设为默认shell(需重登录)" "warn"
        fi
    else
        log "Fish已为默认shell" "info"
    fi
else
    log "Fish未安装，无法设置为默认shell" "error"
fi
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        log "设置时区为上海…" "warn"
        timedatectl set-timezone Asia/Shanghai && log "时区已设为上海" "info" || log "时区设置失败" "error"
    else
        log "时区已为上海" "info"
    fi
else
    log "未检测到 timedatectl，略过时区设置" "warn"
fi
step_end 6 "服务与系统性能优化完成"

# 步骤7 — 网络优化与BBR (用户可选)
step_start 7 "TCP性能与Qdisc网络优化"
QDISC_TYPE="fq_codel"
read -p "是否启用 BBR + $QDISC_TYPE 网络拥塞控制? (y/n): " bbr_choice
if [ "$bbr_choice" = "y" ]; then
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr" || {
        log "加载BBR模块…" "warn"
        modprobe tcp_bbr && echo "tcp_bbr" >> /etc/modules-load.d/modules.conf && log "BBR模块加载成功" "info"
    }
    # 仅备份一次
    [ ! -f /etc/sysctl.conf.bak.orig ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.orig
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "^net.core.default_qdisc=$QDISC_TYPE" /etc/sysctl.conf || echo "net.core.default_qdisc=$QDISC_TYPE" >> /etc/sysctl.conf
    log "应用网络内核tcp优化…" "warn"
    sysctl -p
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
    CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")
    if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
        log "BBR与$QDISC_TYPE配置成功" "info"
    elif [ "$CURR_CC" = "bbr" ]; then
        log "BBR已启用，Qdisc未完全生效（$CURR_QDISC）" "warn"
    elif [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
        log "$QDISC_TYPE已启用，BBR未完全生效（$CURR_CC）" "warn"
    else
        log "BBR和$QDISC_TYPE均未生效: CC=$CURR_CC, QDISC=$CURR_QDISC" "error"
    fi
else
    log "跳过BBR + $QDISC_TYPE配置，未做TCP拥塞优化" "warn"
fi
step_end 7 "网络性能参数配置完成"

# 步骤8 — SSH安全端口加固（只保留首份备份，完全依据输入）
step_start 8 "SSH安全端口管理"
[ ! -f /etc/ssh/sshd_config.bak.orig ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.orig
CURRENT_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=22
log "当前SSH端口为 $CURRENT_SSH_PORT" "warn"
if $RERUN_MODE; then
    read -p "SSH端口是否需要修改? 当前为 $CURRENT_SSH_PORT (y/n): " change_port
else
    read -p "是否需要修改SSH端口? (y/n): " change_port
fi
if [ "$change_port" = "y" ]; then
    read -p "请输入新的SSH端口（1024~65535，仅数字）: " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        log "端口无效，未修改SSH端口，请回头手动配置！" "error"
    elif ss -tuln | grep -q ":$new_port "; then
        log "端口 $new_port 已被占用，请手动选择其它端口并在sshd_config中自行修改。" "error"
    else
        # 只替换首个Port，无Port时追加
        if grep -q "^Port " /etc/ssh/sshd_config; then
            sed -i "0,/^Port /s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
        else
            echo "Port $new_port" >> /etc/ssh/sshd_config
        fi
        log "重启SSH服务以应用新端口…" "warn"
        if systemctl restart sshd; then
            log "SSH端口更改为 $new_port" "info"
        else
            log "SSH重启失败，端口变更可能未生效" "error"
        fi
    fi
else
    log "SSH端口保持为 $CURRENT_SSH_PORT" "warn"
fi
step_end 8 "SSH端口加固完成"

# 步骤9 — 状态与信息汇总
step_start 9 "系统部署信息摘要"
log "\n╔═════════════════════════════════╗" "title"
log "║       系统部署完成摘要          ║" "title"
log "╚═════════════════════════════════╝" "title"
show_info() { log " • $1: $2" "info"; }
show_info "部署模式" "$(if $RERUN_MODE; then echo "重运行/更新"; else echo "首次运行"; fi)"
show_info "脚本版本" "$SCRIPT_VERSION"
show_info "系统版本" "$(grep 'PRETTY_NAME' /etc/os-release |cut -d= -f2 | tr -d '"')"
show_info "内核版本" "$(uname -r)"
show_info "CPU核心数" "$(nproc)"
show_info "内存大小" "$(free -h | grep Mem | awk '{print $2}')"
show_info "磁盘使用" "$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$SSH_PORT" ] && SSH_PORT="22 (默认)"
show_info "SSH端口" "$SSH_PORT"
show_info "Docker版本" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未安装')"
show_info "活跃容器数" "$(docker ps -q 2>/dev/null | wc -l || echo '未检测到Docker')"
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")
show_info "网络优化" "BBR($CURR_CC), Qdisc($CURR_QDISC)"
if command -v timedatectl >/dev/null 2>&1; then
    show_info "时区设置" "$(timedatectl | grep "Time zone" | awk '{print $3}')"
fi
show_info "默认shell" "$SHELL"
TUNED_PROFILE_SUMMARY=$(tuned-adm active | grep 'Current active profile:' | awk -F': ' '{print $2}')
[ -z "$TUNED_PROFILE_SUMMARY" ] && TUNED_PROFILE_SUMMARY="(未检测到)"
show_info "Tuned Profile" "$TUNED_PROFILE_SUMMARY"
[ "$SUCCESSFUL_STARTS" -gt 0 ] && show_info "容器启动" "成功启动 $SUCCESSFUL_STARTS 个" || log " • 容器启动: 没有容器被启动" "error"
[ -n "$FAILED_DIRS" ] && log " • 启动失败目录: $FAILED_DIRS" "error"
log "\n──────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S')" "info"
log "──────────────────────────────────\n" "title"
step_end 9 "信息汇总完成"

# 状态保存（record首次部署时间、ssh_port等）
echo '{
  "script_version": "'$SCRIPT_VERSION'",
  "last_run": "'$(date '+%Y-%m-%d %H:%M:%S')'",
  "ssh_port": "'$SSH_PORT'",
  "system": "Debian '$(cat /etc/debian_version)'",
  "container_status": {
    "successful": '$SUCCESSFUL_STARTS',
    "failed_dirs": "'$FAILED_DIRS'"
  }
}' > "$STATUS_FILE"

# 结尾提示区
log "✅ 所有配置步骤已执行完毕！" "title"
if [ "$change_port" = "y" ]; then
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
        log "⚠️  重要提示: 请使用新SSH端口 $new_port 连接服务器" "warn"
        log "   示例: ssh -p $new_port 用户名@服务器IP" "warn"
    fi
fi
if $RERUN_MODE; then
    log "📝 本脚本为重复执行，已自动跳过/更新已部署项" "info"
else
    log "🎉 初始部署完成！再次运行会进入自动维护模式" "info"
fi
log "🔄 可随时重新运行此脚本以维护或更新系统" "info"
