#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署与优化脚本
# 版本: X.X (修复 Bug，集成 Zram，强化 Fish 安装鲁棒性)
# 适用系统: Debian 12
# 功能概述: 包含 Fish Shell, Docker, Zram, 网络优化, SSH 加固, 自动更新等功能。
# 脚本特性: 幂等可重复执行，确保 Cron 定时任务唯一性。
#
# 作者: LucaLin233
# 贡献者/优化: Linux AI Buddy
# -----------------------------------------------------------------------------

# --- 脚本版本 ---
# 请根据实际修改版本号
# 修复 check_and_start_service 函数语法错误的版本
SCRIPT_VERSION="1.7.4"

# --- 文件路径 ---
STATUS_FILE="/var/lib/system-deploy-status.json" # 存储部署状态的文件
# Fish 官方源文件和密钥路径
FISH_GPG_KEY_PATH="/etc/apt/trusted.gpg.d/shells_fish_release_4.gpg"
FISH_APT_LIST_PATH="/etc/apt/sources.list.d/shells_fish_release_4.list"
FISH_APT_URL="deb http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_12/ /"
FISH_KEY_URL="https://download.opensuse.org/repositories/shells:fish:release:4/Debian_12/Release.key"
CONTAINER_DIRS=(/root /root/proxy /root/vmagent) # 包含 docker-compose 文件的目录

# --- 日志函数 ---
# log <消息> [级别] - 打印带颜色日志
log() {
    local color="\033[0;32m"
    case "$2" in
        "warn")  color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info")  color="\033[0;36m" ;;
        "title") color="\033[1;35m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

# step_start <编号> <描述> - 步骤开始
step_start() { log "▶ 步骤 $1: $2..." "title"; }
# step_end <编号> <描述> - 步骤完成
step_end() { log "✓ 步骤 $1 完成: $2" "info"; echo; }
# step_fail <编号> <描述> - 步骤失败并退出
step_fail() { log "✗ 步骤 $1 失败: $2" "error"; exit 1; }

# check_and_start_service <服务> - 检查并启动 Systemd 服务 (非致命)
# 修复了之前的语法错误
check_and_start_service() {
    local service_name="$1"
    # 检查服务文件是否存在
    if ! systemctl list-unit-files --type=service | grep -q "^${service_name}\s"; then
        log "$service_name 服务文件不存在，跳过检查和启动." "info"
        return 0 # 不存在不是错误，只是跳过
    fi

    log "检查并确保服务运行: $service_name" "info"
    if systemctl is-active "$service_name" &>/dev/null; then
        log "$service_name 服务已运行." "info"
        return 0
    fi

    if systemctl is-enabled "$service_name" &>/dev/null; then
        log "$service_name 服务未运行，但已启用。尝试启动..." "warn"
        systemctl start "$service_name" && log "$service_name 启动成功." "info" && return 0 || log "$service_name 启动失败." "error" && return 1
    else
        log "$service_name 服务未启用。尝试启用并启动..." "warn"
        systemctl enable --now "$service_name" && log "$service_name 已启用并启动成功." "info" && return 0 || log "$service_name 启用并启动失败." "error" && return 1
    fi # <-- 修正: if/else 块的结束 fi 在这里
} # <-- 修正: 函数定义的结束 } 在这里，紧跟着上面的 fi

# run_cmd <命令> [参数...] - 执行命令并检查退出状态 (非致命 except step 步骤 1 tools)
run_cmd() {
    "$@"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        # 特殊处理 apt upgrade 的退出码 100 (部分升级失败)
        if [ "$1" = "apt" ] && ([ "$2" = "upgrade" ] || [ "$2" = "full-upgrade" ]) && [ "$exit_status" -eq 100 ]; then
             log "命令 '$*' 返回退出码 100，继续执行." "warn"
             return 0
        fi
        # 对于其他非 sysctl 命令失败，记录错误但不中断
        if [ "$1" != "sysctl" ]; then
            log "执行命令失败: '$*'. 退出状态: $exit_status" "error"
            return 1
        fi
    fi
    return 0
}

# --- 脚本初始化 ---
RERUN_MODE=false
if [ -f "$STATUS_FILE" ]; then
    RERUN_MODE=true
    log "检测到之前的部署记录 ($STATUS_FILE)。以更新/重运行模式执行." "info"
fi

if [ "$(id -u)" != "0" ]; then
    log "此脚本必须以 root 用户身份运行." "error"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    log "此脚本仅适用于 Debian 系统." "error"
    exit 1
fi

debian_version=$(cut -d. -f1 < /etc/debian_version)
if [ "$debian_version" -lt 12 ]; then
    log "警告: 此脚本为 Debian 12 优化。当前版本 $(cat /etc/debian_version)." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi

# --- 步骤 1: 网络与基础工具检查 ---
step_start 1 "网络与基础工具检查"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络不稳定，可能影响安装." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi
# 确保必要工具可用 (包括 gpg 用于 Fish Key)
for cmd in curl wget apt gpg; do
    if ! command -v $cmd &>/dev/null; then
        log "安装必要工具: $cmd" "warn"
        apt-get update -qq && apt-get install -y -qq $cmd || step_fail 1 "安装基础工具 $cmd 失败."
    fi
done
step_end 1 "网络与基础工具可用"

# --- 步骤 2: 系统更新与核心软件包安装 (不含 systemd-timesyncd 和 Fish) ---
step_start 2 "执行系统更新并安装核心软件包"
run_cmd apt update
if $RERUN_MODE; then
    log "更新模式: 执行软件包升级." "info"
    run_cmd apt upgrade -y # run_cmd 允许退出码 100
else
    log "首次运行: 执行完整的系统升级." "info"
    run_cmd apt full-upgrade -y
fi
PKGS_TO_INSTALL=()
# 核心软件包列表 (不含 fish 和 systemd-timesyncd)
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    if ! dpkg -s "$pkg" &>/dev/null; then
         PKGS_TO_INSTALL+=($pkg)
    fi
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的核心软件包: ${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}"
    if [ $? -ne 0 ]; then
         step_fail 2 "核心软件包安装失败."
    fi
else
    log "所有核心软件包已安装!" "info"
fi
HNAME=$(hostname)
# 确保主机名正确映射到 127.0.1.1
if grep -q "^127.0.1.1" /etc/hosts; then
    if ! grep "^127.0.1.1" /etc/hosts | grep -wq "$HNAME"; then
        cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d)
        sed -i "/^127.0.1.1/ s/\$/ $HNAME/" /etc/hosts
        log "已将主机名 $HNAME 添加到 127.0.1.1 行." "warn"
    fi
else
    echo "127.0.1.1 $HNAME" >> /etc/hosts
    log "已将 127.0.1.1 和主机名 $HNAME 追加到 /etc/hosts." "warn"
fi
step_end 2 "系统更新与核心软件包就绪"

# --- 步骤 3: 配置并启用 Zram Swap ---
step_start 3 "配置并启用 Zram Swap"
ZRAM_SWAP_STATUS="未配置"
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "未检测到 zram-tools。正在安装..." "warn"
    if run_cmd apt update; then
        if run_cmd apt install -y zram-tools; then
            log "zram-tools 安装成功." "info"
            check_and_start_service zramswap.service || log "警告: zramswap.service 检查失败，请手动验证." "warn"
            ZRAM_SWAP_STATUS="已启用且活跃" # 假设成功启用，如果服务检查失败则会在 check_and_start_service 中报错
        else
            log "错误: zram-tools 安装失败." "error"
            ZRAM_SWAP_STATUS="安装失败"
        fi
    else
        log "apt update 失败，跳过 zram-tools 安装." "error"
        ZRAM_SWAP_STATUS="apt update 失败，安装跳过"
    fi
else
    log "zram-tools 已安装." "info"
    if swapon --show | grep -q "/dev/zram"; then
        log "Zram Swap 已活跃." "info"
        ZRAM_SWAP_STATUS="已启用且活跃 ($(swapon --show | grep "/dev/zram" | awk '{print $3 "/" $4}'))"
    else
        log "zram-tools 已安装，但 Zram Swap 不活跃。尝试启动服务..." "warn"
        check_and_start_service zramswap.service || log "警告: zramswap.service 启动失败。Zram Swap 可能不活跃." "warn"
        ZRAM_SWAP_STATUS="已安装但服务不活跃/失败"
    fi
fi
log "注意: 此脚本不自动处理旧 Swap 文件/分区，请手动管理." "info"
step_end 3 "Zram Swap 配置完成"

# --- 步骤 4: 从官方源安装 Fish Shell 并设置默认 Shell ---
step_start 4 "从官方源安装 Fish Shell 并设置默认 Shell"
FISH_INSTALL_STATUS="未安装或检查失败" # 初始化 Fish 安装状态

fish_path=$(command -v fish 2>/dev/null || true) # 检查 fish 是否已安装
if [ -n "$fish_path" ]; then
    log "Fish Shell 已安装 (路径: $fish_path)." "info"
    FISH_INSTALL_STATUS="已安装"
else
    log "未检测到 Fish Shell。尝试从官方源安装..." "warn"

    # 添加 Fish 官方 APT 源和密钥 (即使失败也不中断)
    log "添加 Fish 官方 APT 源和密钥..." "info"
    # 添加源行
    if echo "$FISH_APT_URL" | sudo tee "$FISH_APT_LIST_PATH" > /dev/null; then
        log "Fish 源行已添加." "info"
         # 下载并导入 GPG 密钥
        # curl 失败、gpg 失败或 tee 失败都算失败
        if run_cmd curl -fsSL "$FISH_KEY_URL" | run_cmd gpg --dearmor -o "$FISH_GPG_KEY_PATH"; then
            log "Fish GPG 密钥导入成功." "info"
             log "为确保 key 文件可读，设置权限..." "info"
             run_cmd chmod a+r "$FISH_GPG_KEY_PATH" || log "警告: 设置密钥文件权限失败." "warn" # 非致命错误
        else
            log "错误: 导入 Fish GPG 密钥失败. 可能无法安装 Fish." "error"
            # 失败后清理可能残留的源文件
            [ -f "$FISH_APT_LIST_PATH" ] && run_cmd rm "$FISH_APT_LIST_PATH" && log "已清除 Fish 源文件因导入密钥失败." "warn"
        fi
    else
        log "错误: 添加 Fish 官方 APT 源失败. 可能无法安装 Fish." "error"
    fi

    # 尝试 apt update 并安装 Fish (非致命)
    # 只有当源文件存在时才尝试安装
    if [ -f "$FISH_APT_LIST_PATH" ] && [ -s "$FISH_GPG_KEY_PATH" ]; then # 简单的检查文件是否存在且非空
         log "更新 APT 缓存以包含 Fish 源..." "warn"
         # 尝试只更新新添加的源，如果失败则进行全局 update
         if ! run_cmd apt update -o Dir::Etc::sourcelist="$FISH_APT_LIST_PATH" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="no"; then
             log "警告: 只更新 Fish 源失败.尝试全局 apt update..." "warn"
             if ! run_cmd apt update; then
                  log "错误: 全局 apt update 也失败. Fish 安装可能无法进行." "error"
                  FISH_INSTALL_STATUS="APT更新失败"
             fi
         fi

        if [ "$FISH_INSTALL_STATUS" != "APT更新失败" ]; then
            log "安装 Fish 软件包..." "warn"
            if run_cmd apt install -y fish; then
                log "Fish Shell 软件包安装成功." "info"
                FISH_INSTALL_STATUS="已安装"
                fish_path=$(command -v fish) #g 再次获取 fish 路径
            else
                log "错误: 安装 Fish Shell 软件包失败." "error"
                FISH_INSTALL_STATUS="安装软件包失败"
            fi
        fi
    else
        log "因源或密钥文件缺失/错误，跳过 Fish Apt 安装." "warn"
        FISH_INSTALL_STATUS="源或密钥问题跳过安装"
    fi
fi

# 设置 Fish Shell 为默认 (如果已安装)
if [ -n "$fish_path" ]; then
     if ! grep -q "^$fish_path$" /etc/shells; then
        echo "$fish_path" | tee -a /etc/shells > /dev/null && log "已将 Fish 路径添加到 /etc/shells." "info" || log "添加 Fish 失败." "error"
    fi
    if [ "$SHELL" != "$fish_path" ]; then
        if $RERUN_MODE; then
            log "Fish 已安装但非默认 ($SHELL). 重运行模式不自动更改." "info"
            read -p "设置 Fish ($fish_path) 为默认 Shell? (y/n): " change_shell
            [ "$change_shell" = "y" ] && chsh -s "$fish_path" && log "Fish 已设为默认 (需重登录)." "warn" || log "未更改默认 Shell." "info"
        else
            log "Fish 已安装 ($fish_path) 但非默认 ($SHELL). 设置 Fish 为默认..." "warn"
            chsh -s "$fish_path" && log "Fish 已设为默认 (需重登录)." "warn" || log "设置默认 Shell 失败." "error"
        fi
    else
        log "Fish ($fish_path) 已是默认 Shell." "info"
    fi
fi
step_end 4 "Fish Shell 安装与设置完成 (状态: $FISH_INSTALL_STATUS)"

# --- 步骤 5: 安装 Docker 和 NextTrace ---
step_start 5 "安装 Docker 和 NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
# 使用 get.docker.com 脚本安装 Docker
if ! command -v docker &>/dev/null; then
    log "未检测到 Docker。使用 get.docker.com 安装..." "warn"
    if run_cmd bash -c "$(run_cmd curl -fsSL https://get.docker.com)"; then
        log "Docker 安装成功." "info"
        check_and_start_service docker.service || log "警告: 启用/启动 Docker 服务失败." "warn"
    else
        log "错误: Docker 安装失败." "error"
    fi
else
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)
    log "Docker 已安装 (版本: ${docker_version:-未知})." "info"
    check_and_start_service docker.service || log "Docker 服务检查/启动失败." "error"
fi
# 低内存环境优化 Docker 日志
if [ "$MEM_TOTAL" -lt 1024 ]; then
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        log "低内存环境. 优化 Docker 日志配置..." "warn"
        mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
        log "重启 Docker 应用日志优化..." "warn"
        systemctl restart docker || log "警告: 重启 Docker 服务失败." "warn"
    else
        log "Docker 日志优化配置已存在." "info"
    fi
fi
# 安装 NextTrace
if command -v nexttrace &>/dev/null; then
    log "NextTrace 已安装." "info"
else
    log "未检测到 NextTrace。正在部署..." "warn"
    if run_cmd bash -c "$(run_cmd curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"; then
        log "NextTrace 安装成功." "info"
    else
        log "警告: NextTrace 安装失败." "error"
    fi
fi
step_end 5 "Docker 和 NextTrace 部署完成"

# --- 步骤 6: 检查并启动 Docker Compose 容器 ---
step_start 6 "检查并启动 Docker Compose 定义的容器"
SUCCESSFUL_RUNNING_CONTAINERS=0
FAILED_DIRS=""
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi

if [ -z "$COMPOSE_CMD" ]; then
    log "未检测到 Docker Compose。跳过容器启动." "warn"
else
    log "使用 Docker Compose 命令: '$COMPOSE_CMD'" "info"
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            log "目录 '$dir' 不存在。跳过." "warn"
            continue
        fi
        COMPOSE_FILE=""
        for file in compose.yaml docker-compose.yml; do
            if [ -f "$dir/$file" ]; then
                COMPOSE_FILE="$file"
                break
            fi
        done
        if [ -n "$COMPOSE_FILE" ]; then
            log "进入目录 '$dir' 检查 Compose 文件 '$COMPOSE_FILE'." "info"
            if cd "$dir"; then
                EXPECTED_SERVICES=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services 2>/dev/null | wc -l)
                if [ "$EXPECTED_SERVICES" -eq 0 ]; then
                    log "目录 '$dir': Compose 文件 '$COMPOSE_FILE' 未定义服务。跳过." "warn"
                    cd - >/dev/null
                    continue
                fi
                CURRENT_RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                if [ "$CURRENT_RUNNING_COUNT" -ge "$EXPECTED_SERVICES" ]; then
                     log "目录 '$dir': 已检测到至少 $EXPECTED_SERVICES 个容器运行中。跳过启动." "info"
                     SUCCESSFUL_RUNNING_CONTAINERS=$((SUCCESSFUL_RUNNING_CONTAINERS + CURRENT_RUNNING_COUNT))
                else
                    log "目录 '$dir': $CURRENT_RUNNING_COUNT 个容器运行中 (预期至少 $EXPECTED_SERVICES)。尝试启动/重创..." "warn"
                    if $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate; then
                        sleep 5 # 短暂等待启动
                        NEW_RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                        log "目录 '$dir' 启动/重创尝试成功. $NEW_RUNNING_COUNT 个容器正在运行." "info"
                        SUCCESSFUL_RUNNING_CONTAINERS=$((SUCCESSFUL_RUNNING_CONTAINERS + NEW_RUNNING_COUNT))
                    else
                        log "错误: Compose 启动失败目录: '$dir'." "error"
                        FAILED_DIRS+=" $dir"
                    fi
                fi
                cd - >/dev/null
            else
                log "错误: 无法进入目录 '$dir'。跳过." "error"
                FAILED_DIRS+=" $dir"
            fi
        else
            log "目录 '$dir': 未找到 Compose 文件。跳过." "warn"
        fi
    done
    ACTUAL_TOTAL_RUNNING=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    log "容器检查汇总: 系统上实际运行容器总数: $ACTUAL_TOTAL_RUNNING." "info"
    if [ -n "$FAILED_DIRS" ]; then
        log "警告: 以下目录的 Compose 启动可能失败: $FAILED_DIRS" "error"
    fi
fi
step_end 6 "Docker Compose 容器检查完成"

# --- 步骤 7: 系统服务与性能优化 ---
step_start 7 "系统服务与性能优化 (时区, Tuned, Timesync)"
# 确保 tuned 已启用并启动 (非致命)
if systemctl list-unit-files --type=service | grep -q tuned.service; then
    check_and_start_service tuned.service || log "警告: tuned 服务启动失败." "warn"
else
    log "未检测到 tuned 服务. 跳过调优配置." "warn"
fi
# 设置系统时区为亚洲/上海 (非致命)
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        log "设置时区为亚洲/上海..." "warn"
        timedatectl set-timezone Asia/Shanghai && log "时区成功设置为亚洲/上海." "info" || log "timedatectl 设置时区失败." "error"
    else
        log "时区已是亚洲/上海." "info"
    fi
else
    log "未检测到 timedatectl 命令。跳过时区设置." "warn"
fi
# 确保 systemd-timesyncd 已启动 (如果存在) (非致命)
check_and_start_service systemd-timesyncd.service || log "systemd-timesyncd 服务检查失败或不存在." "info"
# 确保 chrony 已启动 (如果存在) (非致命)
# check_and_start_service chrony.service || log "chrony 服务检查失败或不存在." "info"

step_end 7 "系统服务与性能优化完成"

# --- 步骤 8: 配置 TCP 性能 (BBR) 和 Qdisc (fq_codel) ---
step_start 8 "配置 TCP 性能 (BBR) 和 Qdisc (fq_codel)"
QDISC_TYPE="fq_codel"
read -p "启用 BBR + $QDISC_TYPE 网络拥塞控制? (Y/n): " bbr_choice
bbr_choice="${bbr_choice:-y}"

if [[ ! "$bbr_choice" =~ ^[nN]$ ]]; then
    log "用户选择启用 BBR + $QDISC_TYPE." "info"
    SKIP_SYSCTL_CONFIG=false
    # 检查并加载 tcp_bbr 模块
    if ! /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1 || ! run_cmd /sbin/modprobe tcp_bbr; then
        log "警告: 未找到或无法加载 'tcp_bbr' 模块." "warn"
        if [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m); then
             log "'tcp_bbr' 模块已编译或可用." "info"
        else
             log "严重警告: 内核可能不支持 BBR. 无法启用." "error"
             SKIP_SYSCTL_CONFIG=true
        fi
    fi

    if [ "$SKIP_SYSCTL_CONFIG" != true ]; then
        [ ! -f /etc/sysctl.conf.bak.orig ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.orig && log "已备份 /etc/sysctl.conf." "info"
        log "配置 sysctl 参数 for BBR and $QDISC_TYPE..." "info"

        # 幂等删除旧配置并行，使用 '|' 分隔符，然后追加
        sed -i '\| *#\? *net\.ipv4\.tcp_congestion_control=|d' /etc/sysctl.conf && log "已移除旧的 tcp_congestion_control 行." "info" || true
        echo "net.ipv4.tcp_congestion_control=bbr" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.ipv4.tcp_congestion_control=bbr." "info" || log "追加 tcp_congestion_control 失败." "error"

        sed -i '\| *#\? *net\.core\.default_qdisc=|d' /etc/sysctl.conf && log "已移除旧的 default_qdisc 行." "info" || true
        echo "net.core.default_qdisc=fq_codel" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.core.default_qdisc=fq_codel." "info" || log "追加 default_qdisc 失败." "error"

        log "应用 sysctl 配置..." "warn"
        run_cmd sysctl -p || log "警告: 'sysctl -p' 失败. 检查配置语法." "warn"

        # 验证当前设置
        CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败/未设置")
        CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败/未设置")
        log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
        if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
            log "BBR 和 $QDISC_TYPE 参数已生效." "info"
        else
            log "警告: 网络参数验证可能不匹配." "warn"
        fi
    else
        log "因 BBR 模块问题，跳过 sysctl 配置." "warn"
    fi
else
    log "跳过 BBR + $QDISC_TYPE 配置." "warn"
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败/未设置")
    CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败/未设置")
    log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
fi
step_end 8 "网络性能参数配置完成"

# --- 步骤 9: 管理 SSH 安全端口 ---
step_start 9 "管理 SSH 服务端口"
[ ! -f /etc/ssh/sshd_config.bak.orig ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.orig && log "已备份 /etc/ssh/sshd_config." "info"
# 查找当前 SSH 端口
CURRENT_SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT="22" && log "未找到 Port 配置，假定默认 22." "info" || log "当前配置 SSH 端口为 $CURRENT_SSH_PORT." "info"

# 提示用户修改端口
if $RERUN_MODE; then
    read -p "当前 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input
else
    read -p "当前 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input
fi

NEW_SSH_PORT_SET="$CURRENT_SSH_PORT"
CHANGE_PORT_REQUESTED=false

if [ -n "$new_port_input" ]; then
    CHANGE_PORT_REQUESTED=true
    if ! [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
        log "输入无效，端口未更改." "error"
    elif [ "$new_port_input" -lt 1024 ] || [ "$new_port_input" -gt 65535 ]; then
        log "端口号无效，端口未更改." "error"
    elif ss -tuln | grep -q ":$new_port_input\b"; then
        log "警告: 端口 $new_port_input 已被占用. 端口未更改." "warn"
    else
        log "正在更改 SSH 端口为 $new_port_input..." "warn"
        # 移除旧的 Port 行并添加新行
        sed -i '\| *#\? *Port |d' /etc/ssh/sshd_config && log "已移除旧的 Port 行." "info" || true # 即使失败也 true
        echo "Port $new_port_input" >> /etc/ssh/sshd_config && log "已添加 Port $new_port_input 到 sshd_config." "info" || log "添加 Port 行失败." "error"

        log "重启 SSH 服务应用新端口..." "warn"
        if systemctl restart sshd; then
            log "SSH 服务重启成功. 新端口 $new_port_input 已生效." "info"
            NEW_SSH_PORT_SET="$new_port_input"
        else
            log "错误: SSH 服务重启失败! 新端口可能未生效." "error"
            NEW_SSH_PORT_SET="Failed to restart/$new_port_input"
        fi
    fi
fi
step_end 9 "SSH 端口管理完成"

# --- 步骤 10: 部署自动更新脚本和 Cron 任务 ---
step_start 10 "部署自动更新脚本和 Crontab 任务"
UPDATE_SCRIPT="/root/auto-update.sh"
# 写入自动更新脚本内容 (使用修复后的 v1.6 版本)
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
# -----------------------------------------------------------------------------
# 自动化系统更新与内核重启脚本 (修复版 v1.6 - 日志覆盖 + pseudo-TTY)
# 更新软件包，检查新内核，必要时重启。每次运行时覆盖旧日志。
# 使用 apt-get dist-upgrade. 通过 `script` 命令模拟 TTY 环境运行 apt-get.
# -----------------------------------------------------------------------------

# --- 配置 ---
LOGFILE="/var/log/auto-update.log"
# 为 apt-get dist-upgrade 准备选项
APT_GET_OPTIONS="-y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" -o APT::ListChanges::Frontend=none"
# script 命令需要一个文件来记录输出
SCRIPT_OUTPUT_DUMMY="/tmp/auto_update_script_cmd_output.log"

# --- 自动更新脚本内部日志函数 ---
log_update() {
    # 注意：确保日志函数使用追加模式 '>>'
    echo "[$(date '+%Y-%m-%d %H:%M:%S (%Z)')] $1" >>"$LOGFILE"
}

# --- 主逻辑 ---

# --- 关键修改：覆盖旧日志 ---
# 在记录第一条日志前，清空日志文件
> "$LOGFILE"

log_update "启动自动化系统更新 (修复版 v1.6 - 日志覆盖 + pseudo-TTY)."

log_update "运行 /usr/bin/apt-get update..."
/usr/bin/apt-get update -o APT::ListChanges::Frontend=none >>"$LOGFILE" 2>&1
UPDATE_EXIT_STATUS=$?
if [ $UPDATE_EXIT_STATUS -ne 0 ]; then
    log_update "警告: /usr/bin/apt-get update 失败， exits $UPDATE_EXIT_STATUS."
    # exit 1
fi

# 运行前清理旧的 script 输出文件
/bin/rm -f "$SCRIPT_OUTPUT_DUMMY"

log_update "运行 /usr/bin/apt-get dist-upgrade (尝试通过 'script' 命令模拟 TTY)..."
COMMAND_TO_RUN="DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get dist-upgrade $APT_GET_OPTIONS"
/usr/bin/script -q -c "$COMMAND_TO_RUN" "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE" 2>&1
UPGRADE_EXIT_STATUS=$?

if [ -f "$SCRIPT_OUTPUT_DUMMY" ]; then
    log_update "--- Output captured by 'script' command (from $SCRIPT_OUTPUT_DUMMY) ---"
    /bin/cat "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE"
    log_update "--- End of 'script' command output ---"
    # /bin/rm -f "$SCRIPT_OUTPUT_DUMMY" # 可以取消注释以删除临时文件
else
    log_update "警告: 未找到 'script' 命令的输出文件 $SCRIPT_OUTPUT_DUMMY"
fi

if [ $UPGRADE_EXIT_STATUS -eq 0 ]; then
    log_update "apt-get dist-upgrade (via script) 命令执行完成 (script 命令退出码 0)."

    RUNNING_KERNEL="$(/bin/uname -r)"
    log_update "当前运行内核: $RUNNING_KERNEL"

    LATEST_INSTALLED_KERNEL_PKG=$(/usr/bin/dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image-[0-9]*' 2>/dev/null | /usr/bin/sort -k2 -V | /usr/bin/tail -n1 | /usr/bin/awk '{print $1}' || true)

    if [ -z "$LATEST_INSTALLED_KERNEL_PKG" ]; then
        log_update "未找到已安装的特定版本内核包。无法比较。"
        INSTALLED_KERNEL_VERSION=""
    else
        log_update "检测到的最新安装内核包: $LATEST_INSTALLED_KERNEL_PKG"
        INSTALLED_KERNEL_VERSION="$(echo "$LATEST_INSTALLED_KERNEL_PKG" | /bin/sed 's/^linux-image-//')"
        log_update "提取到的最新内核版本: $INSTALLED_KERNEL_VERSION"
    fi

    if [ -n "$INSTALLED_KERNEL_VERSION" ] && [ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL_VERSION" ]; then
        log_update "检测到新内核版本 ($INSTALLED_KERNEL_VERSION) 与运行内核 ($RUNNING_KERNEL) 不同。"

        if ! /bin/systemctl is-active sshd >/dev/null 2>&1; then
             log_update "SSHD 服务未运行，尝试启动..."
             /bin/systemctl restart sshd >>"$LOGFILE" 2>&1 || log_update "警告: SSHD 启动失败! 重启可能导致无法连接。"
             # exit 1
        fi

        log_update "因新内核需要重启系统..."
        log_update "执行 /sbin/reboot ..."
        /sbin/reboot >>"$LOGFILE" 2>&1
        /bin/sleep 15
        log_update "警告: 重启命令已发出，但脚本仍在运行？"

    else
        log_update "内核已是最新 ($RUNNING_KERNEL) 或无法确定新内核，无需重启。"
    fi

else
    log_update "错误: apt-get dist-upgrade (via script) 未成功完成 (script 命令退出码: $UPGRADE_EXIT_STATUS). 跳过内核检查和重启。"
    log_update "请检查上面由 'script' 命令捕获的具体输出，以了解内部错误。"
fi

log_update "自动更新脚本执行完毕."
exit 0
EOF

# --- 后面的 chmod 和 crontab 设置保持不变 ---
chmod +x "$UPDATE_SCRIPT" && log "自动更新脚本已创建并可执行." "info" || log "设置脚本可执行失败." "error"

CRON_CMD="5 0 * * 0 $UPDATE_SCRIPT"
(crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "auto-update.log"; echo "$CRON_CMD") | sort -u | crontab -
log "Crontab 已配置每周日 00:05 执行，并确保唯一性." "info"

step_end 10 "自动更新脚本与 Crontab 任务部署完成"
# --- 步骤 10 结束 ---

# --- 步骤 11: 系统部署信息摘要 ---
step_start 11 "系统部署信息摘要"
log "\n╔═════════════════════════════════════════╗" "title"
log "║           系统部署完成摘要                ║" "title"
log "╚═════════════════════════════════════════╝" "title"

show_info() { log " • $1: $2" "info"; }

show_info "部署模式" "$(if $RERUN_MODE; then echo "重运行 / 更新"; else echo "首次部署"; fi)"
show_info "脚本版本" "$SCRIPT_VERSION"

OS_PRETTY_NAME="未知 Debian 版本"
[ -f /etc/os-release ] && OS_PRETTY_NAME=$(grep 'PRETTY_NAME' /etc/os-release |cut -d= -f2 | tr -d '"' || echo '未知 Debian 版本')
show_info "操作系统" "$OS_PRETTY_NAME"

show_info "当前运行内核" "$(uname -r)"
show_info "CPU 核心数" "$(nproc)"

MEM_USAGE=$(free -h | grep Mem | awk '{print $2}' || echo '未知')
show_info "总内存大小" "$MEM_USAGE"

DISK_USAGE_ROOT="未知"
df -h / >/dev/null 2>&1 && DISK_USAGE_ROOT=$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" "$5" ")"}')
show_info "磁盘使用 (/)" "$DISK_USAGE_ROOT"

show_info "Zram Swap 状态" "$ZRAM_SWAP_STATUS"

# Fish 安装状态
show_info "Fish Shell 状态" "$FISH_INSTALL_STATUS"
fish_path_summary=$(command -v fish 2>/dev/null || true) # 再次获取 fish 路径 for summary
[ -n "$fish_path_summary" ] && show_info "Fish Shell 路径" "$fish_path_summary"

# SSH 端口状态
DISPLAY_SSH_PORT_SUMMARY="$NEW_SSH_PORT_SET"
SSH_PORT_WARNING=""
if echo "$NEW_SSH_PORT_SET" | grep -q "Failed to restart"; then
    DISPLAY_SSH_PORT_SUMMARY=$(echo "$NEW_SSH_PORT_SET" | sed 's/Failed to restart\///')
    SSH_PORT_WARNING=" (警告: SSH 服务重启失败)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ] && [ "$CHANGE_PORT_REQUESTED" = true ]; then
    SSH_PORT_WARNING=" (尝试更改失败/端口被占用)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ]; then
     SSH_PORT_WARNING=" (未更改)"
else
     SSH_PORT_WARNING=" (已成功更改)"
fi
show_info "SSH 端口" "$DISPLAY_SSH_PORT_SUMMARY$SSH_PORT_WARNING"

# Docker 状态
DOCKER_VER_SUMMARY="未安装"
ACTIVE_CONTAINERS_COUNT="N/A"
command -v docker >/dev/null 2>&1 && DOCKER_VER_SUMMARY=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '未知版本') && ACTIVE_CONTAINERS_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo '检查失败') || true
show_info "Docker 版本" "$DOCKER_VER_SUMMARY"
show_info "活跃 Docker 容器数" "$ACTIVE_CONTAINERS_COUNT"

# NextTrace 状态 (过滤 [API])
NEXTTRACE_FULL_OUTPUT=$(nexttrace -V 2>&1 || true) # 即使命令失败也不中断
# 过滤掉带有 [API] 的行，然后从第一行非空输出中提取版本号
NEXTTRACE_VER_LINE=$(echo "$NEXTTRACE_FULL_OUTPUT" | grep -v '\[API\]' | head -n 1)
NEXTTRACE_VER_SUMMARY="未安装"
if [ -n "$NEXTTRACE_VER_LINE" ]; then
    # 提取第二个字段，并去除可能的逗号
    NEXTTRACE_VER_SUMMARY=$(echo "$NEXTTRACE_VER_LINE" | awk '{print $2}' | tr -d ',' || echo "提取失败")
fi
# 如果提取后仍为空，则显示未安装
[ -z "$NEXTTRACE_VER_SUMMARY" ] && NEXTTRACE_VER_SUMMARY="未安装"

show_info "NextTrace 版本" "$NEXTTRACE_VER_SUMMARY"

# 网络优化参数
CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败")
show_info "网络参数 (sysctl)" "CC=$CURR_CC, Qdisc=$CURR_QDISC"

BBR_MODULE_STATUS="未知"
if /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1; then
    BBR_MODULE_STATUS="模块可用/已加载"
elif [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m); then
     BBR_MODULE_STATUS="编译进内核/可用模块"
else
     BBR_MODULE_STATUS="模块不存在"
fi
show_info "BBR 内核模块状态" "$BBR_MODULE_STATUS"

# 时区设置
TIMEZONE_SUMMARY="未知"
command -v timedatectl >/dev/null 2>&1 && TIMEZONE_SUMMARY=$(timedatectl | grep "Time zone" | awk '{print $3}')
show_info "系统时区设置" "$TIMEZONE_SUMMARY"

# Shell 信息
show_info "当前脚本 Shell" "$SHELL"
ROOT_LOGIN_SHELL=$(getent passwd root | cut -d: -f7 || echo "获取失败")
show_info "Root 用户默认登录 Shell" "$ROOT_LOGIN_SHELL"

# Tuned Profile
TUNED_PROFILE_SUMMARY=$(tuned-adm active 2>/dev/null | grep 'Current active profile:' | awk -F': ' '{print $NF}')
[ -z "$TUNED_PROFILE_SUMMARY" ] && TUNED_PROFILE_SUMMARY="(未检测到活跃 Profile)"
show_info "活跃 Tuned Profile" "$TUNED_PROFILE_SUMMARY"

# Compose 容器状态
if [ "$SUCCESSFUL_RUNNING_CONTAINERS" -gt 0 ]; then
    show_info "Compose 容器状态" "在配置目录共检测到 $SUCCESSFUL_RUNNING_CONTAINERS 个容器运行中."
else
    log " • Compose 容器状态: 未检测到运行中的 Compose 容器." "info"
fi
[ -n "$FAILED_DIRS" ] && log " • 警告: Compose 启动失败目录: $FAILED_DIRS" "error"

log "\n──────────────────────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "info"
log "──────────────────────────────────────────────────\n" "title"

step_end 11 "摘要报告已生成"

# --- 保存部署状态 ---
printf '{
  "script_version": "%s",
  "last_run": "%s",
  "ssh_port": "%s",
  "system": "%s",
  "zram_status": "%s",
  "fish_status": "%s",
  "network_optimization": {
    "tcp_congestion_control": "%s",
    "default_qdisc": "%s"
  },
  "container_status": {
    "successful_running": %d,
    "failed_dirs": "%s"
  }
}\n' \
"$SCRIPT_VERSION" \
"$(date '+%Y-%m-%d %H:%M:%S')" \
"$NEW_SSH_PORT_SET" \
"$OS_PRETTY_NAME" \
"$ZRAM_SWAP_STATUS" \
"$FISH_INSTALL_STATUS" \
"$CURR_CC" \
"$CURR_QDISC" \
"$SUCCESSFUL_RUNNING_CONTAINERS" \
"$FAILED_DIRS" \
> "$STATUS_FILE"

# 验证状态文件创建
if [ -f "$STATUS_FILE" ]; then
    log "部署状态已保存至文件: $STATUS_FILE" "info"
else
    log "警告: 无法创建状态文件 $STATUS_FILE." "error"
fi

# --- 最终提示 ---
log "✅ 脚本执行完毕." "title"

if [ "$CHANGE_PORT_REQUESTED" = true ] && [ "$NEW_SSH_PORT_SET" = "$new_port_input" ] && [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
    log "⚠️  重要提示: 请使用新 SSH 端口 $NEW_SSH_PORT_SET 连接." "warn"
    log "   示例: ssh -p $NEW_SSH_PORT_SET 您的用户名@您的服务器IP地址" "warn"
fi

if $RERUN_MODE; then
    log "➡️  重运行模式: 已按需更新配置和服务." "info"
else
    log "🎉 初始部署完成!" "info"
fi
log "🔄 可随时再次运行此脚本进行维护或更新." "info"

log "手动检查建议: 请验证旧 Swap 文件/配置是否已正确移除." "warn"
