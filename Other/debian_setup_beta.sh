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
SCRIPT_VERSION="1.7.2"

# --- 文件路径 ---
STATUS_FILE="/var/lib/system-deploy-status.json" # 存储部署状态的文件
# Fish 官方源 GPG Key 推荐存放路径 (.gpg 结尾，Systemd >= 248 支持)
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
    fi
}

# run_cmd <命令> [参数...] - 执行命令并检查退出状态 (非致命版本 except for core tools check)
run_cmd() {
    "$@"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        # 特殊处理 apt upgrade 的退出码，因为有时可能是部分升级失败 (如 100)，不需中断
        if [ "$1" = "apt" ] && ([ "$2" = "upgrade" ] || [ "$2" = "full-upgrade" ]) && [ "$exit_status" -eq 100 ]; then
             log "命令 '$*' 返回退出码 100 (部分升级可能失败)，继续执行." "warn"
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
    log "警告: 此脚本为 Debian 12 优化。当前系统版本 $(cat /etc/debian_version)." "warn"
    read -p "确定要继续吗? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi

# --- 步骤 1: 网络与基础工具检查 ---
step_start 1 "网络与基础工具检查"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络不稳定，可能影响安装." "warn"
    read -p "确定要继续吗? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi
# 确保必要工具可用，这里使用 step_fail 保证安装基础工具成功
for cmd in curl wget apt gpg; do # 确保 gpg 提前安装，用于 Fish Key
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
    run_cmd apt upgrade -y # 这里 run_cmd 允许 apt upgrade 100 错误通过
else
    log "首次运行: 执行完整的系统升级." "info"
    run_cmd apt full-upgrade -y # 首次运行推荐 full-upgrade
fi
PKGS_TO_INSTALL=()
# 核心软件包列表 (不含 fish 和 systemd-timesyncd)
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    # 检查软件包是否未安装
    if ! dpkg -s "$pkg" &>/dev/null; then
         PKGS_TO_INSTALL+=($pkg)
    fi
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的核心软件包: ${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}" # 这里 run_cmd 会在安装失败时报错并返回1
    if [ $? -ne 0 ]; then
         step_fail 2 "核心软件包安装失败."
    fi
else
    log "所有核心软件包已安装!" "info"
fi
HNAME=$(hostname)
# 确保主机名正确映射到 /etc/hosts 中的 127.0.1.1
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
    # 安装前确保 APT 源已更新
    if run_cmd apt update; then
        if run_cmd apt install -y zram-tools; then # 这里 run_cmd 检查安装是否成功
            log "zram-tools 安装成功." "info"
            # 检查服务状态
            if check_and_start_service zramswap.service; then
                 ZRAM_SWAP_STATUS="已启用且活跃"
            else
                 log "警告: zramswap.service 检查失败，请手动验证." "warn"
                 ZRAM_SWAP_STATUS="已安装但服务不活跃/失败"
            fi
        else
            # zram-tools 安装失败不中断整个脚本
            log "错误: zram-tools 安装失败." "error"
            ZRAM_SWAP_STATUS="安装失败"
        fi
    else
        log "apt update 失败，跳过 zram-tools 安装." "error"
        ZRAM_SWAP_STATUS="apt update 失败，安装跳过"
    fi
else
    log "zram-tools 已安装." "info"
    # 检查 Zram Swap 是否活跃
    if swapon --show | grep -q "/dev/zram"; then
        log "Zram Swap 已活跃." "info"
        ZRAM_SWAP_STATUS="已启用且活跃 ($(swapon --show | grep "/dev/zram" | awk '{print $3 "/" $4}'))"
    else
        log "zram-tools 已安装，但 Zram Swap 不活跃。尝试启动服务..." "warn"
        if check_and_start_service zramswap.service; then
             ZRAM_SWAP_STATUS="启动后已启用且活跃"
        else
             log "警告: zramswap.service 启动失败。Zram Swap 可能不活跃." "warn"
             ZRAM_SWAP_STATUS="已安装但服务不活跃/失败"
        fi
    fi
fi
log "注意: 此脚本不自动处理旧的 Swap 文件或分区，请手动管理." "info"
step_end 3 "Zram Swap 配置完成"

# --- 步骤 4: 从官方源安装 Fish Shell 并设置默认 Shell ---
step_start 4 "从官方源安装 Fish Shell 并设置默认 Shell"
FISH_INSTALL_STATUS="未安装" # 初始化 Fish 安装状态

fish_path=$(command -v fish)
if [ -n "$fish_path" ]; then
    log "Fish Shell 已安装 (路径: $fish_path)." "info"
    FISH_INSTALL_STATUS="已安装"
else
    log "未检测到 Fish Shell。尝试从官方源安装..." "warn"
    FISH_INSTALL_SUCCESS=false # 标记 Fish 官方源安装是否成功

    # 添加 Fish 官方 APT 源
    log "添加 Fish 官方 APT 源: $FISH_APT_URL" "info"
    if echo "$FISH_APT_URL" | sudo tee "$FISH_APT_LIST_PATH" > /dev/null; then
        log "Fish 官方 APT 源行已添加至 $FISH_APT_LIST_PATH." "info"
        # 添加 Fish 官方 GPG 密钥到 trusted.gpg.d
        log "添加 Fish 官方 GPG 密钥到 $FISH_GPG_KEY_PATH..." "info"
        # curl 失败、gpg 失败或 tee 失败都算失败
        if run_cmd curl -fsSL "$FISH_KEY_URL" | run_cmd gpg --dearmor -o "$FISH_GPG_KEY_PATH"; then
            log "Fish GPG 密钥导入成功." "info"
             log "为确保 key 文件可读，设置权限..." "info"
             run_cmd chmod a+r "$FISH_GPG_KEY_PATH" || log "Warning: Failed to set read permissions on Fish GPG key." "warn" # 非致命错误
        else
            log "错误: 导入 Fish GPG 密钥失败. 跳过 Fish 安装." "error"
            FISH_INSTALL_STATUS="导入密钥失败"
            # 清理可能残留的源文件
            [ -f "$FISH_APT_LIST_PATH" ] && run_cmd rm "$FISH_APT_LIST_PATH" && log "已清理 Fish APT 源文件因导入密钥失败." "warn"
        fi
    else
        log "错误: 添加 Fish 官方 APT 源失败. 跳过 Fish 安装." "error"
        FISH_INSTALL_STATUS="添加源失败"
    fi

    # 只有当源和密钥都似乎成功添加后，才尝试 apt update 和 install
    if [ "$FISH_INSTALL_STATUS" = "未安装" ] || [ "$FISH_INSTALL_STATUS" = "导入密钥失败" ]; then
        log "由于前期错误，跳过 Fish 的 apt update 和 install 步骤." "warn"
    else
        # 更新 APT 缓存 (只更新 Fish 的源如果可能，否则全局更新)
        log "更新 APT 缓存..." "warn"
        # 尝试只更新新添加的源，如果失败则进行全局 update
        if ! run_cmd apt update -o Dir::Etc::sourcelist="$FISH_APT_LIST_PATH" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="no"; then
             log "警告: 只更新 Fish 源失败 (可能源本身问题或语法错误)。尝试全局 apt update..." "warn"
             if ! run_cmd apt update; then
                  log "严重错误: 全局 apt update 也失败. Fish 安装可能无法进行." "error"
                  FISH_INSTALL_STATUS="APT更新失败"
             fi
        fi

        if [ "$FISH_INSTALL_STATUS" != "APT更新失败" ]; then
            # 安装 Fish 软件包
            log "安装 Fish 软件包..." "warn"
            if run_cmd apt install -y fish; then # 这里 run_cmd 会检查安装是否成功
                log "Fish Shell 软件包安装成功." "info"
                FISH_INSTALL_STATUS="已安装"
                fish_path=$(command -v fish) # 更新 fish_path
            else
                log "错误: 安装 Fish Shell 软件包失败." "error"
                FISH_INSTALL_STATUS="安装软件包失败"
            fi
        fi
    fi
fi

# 设置 Fish Shell 为默认 (如果已安装且用户同意)
if [ -n "$fish_path" ]; then
     # Add fish path to /etc/shells if not already present
    if ! grep -q "^$fish_path$" /etc/shells; then
        echo "$fish_path" | tee -a /etc/shells > /dev/null && log "已将 Fish 路径添加到 /etc/shells." "warn" || log "添加 Fish 路径失败." "error" # 非致命错误
    fi

    if [ "$SHELL" != "$fish_path" ]; then
        if $RERUN_MODE; then
            log "Fish 已安装但非当前默认 Shell ($SHELL). 重运行模式下不自动更改." "info"
            read -p "设置 Fish ($fish_path) 为默认 Shell? (y/n): " change_shell
            [ "$change_shell" = "y" ] && chsh -s "$fish_path" && log "Fish 已设为默认 Shell (需重登录)." "warn" || log "未更改默认 Shell." "info"
        else
            log "Fish 已安装 ($fish_path) 但非当前默认 Shell ($SHELL). 设置 Fish 为默认 Shell..." "warn"
            chsh -s "$fish_path" && log "Fish 已设为默认 Shell (需重登录)." "warn" || log "设置默认 Shell 失败." "error" # 非致命错误
        fi
    else
        log "Fish ($fish_path) 已是当前默认 Shell." "info"
    fi
fi
step_end 4 "Fish Shell 安装与设置完成 (状态: $FISH_INSTALL_STATUS)" # 在摘要中记录 Fish 状态

# --- 步骤 5: 安装 Docker 和 NextTrace ---
step_start 5 "安装 Docker 和 NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
# 使用 get.docker.com 脚本安装 Docker (符合原始脚本逻辑)
if ! command -v docker &>/dev/null; then
    log "未检测到 Docker。使用 get.docker.com 脚本安装..." "warn"
    # run_cmd 将检查 curl 和 bash 的退出状态
    if run_cmd bash -c "$(run_cmd curl -fsSL https://get.docker.com)"; then
        log "Docker 安装成功." "info"
        check_and_start_service docker.service || log "Warning: Failed to enable/start Docker service automatically." "warn" # 非致命错误
    else
        log "错误: Docker 安装失败." "error" # 非致命错误，继续脚本
    fi
else
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)
    log "Docker 已安装 (版本: ${docker_version:-未知})." "info"
    check_and_start_service docker.service || log "Docker 服务检查/启动失败." "error" # 非致命错误
fi
# 低内存环境优化 Docker 日志
if [ "$MEM_TOTAL" -lt 1024 ]; then
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        log "低内存环境detected. 优化 Docker 日志配置..." "warn"
        mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' > /etc/docker/daemon.json
        log "重启 Docker 服务应用日志优化..." "warn"
        systemctl restart docker || log "警告: 重启 Docker 服务失败." "warn" # 非致命错误
    else
        log "Docker 日志优化配置已存在." "info"
    fi
fi
# 安装 NextTrace (检查是否已安装)
if command -v nexttrace &>/dev/null; then
    log "NextTrace 已安装." "info"
else
    log "未检测到 NextTrace。正在部署..." "warn"
    # run_cmd 检查 curl 和 bash 的退出状态
    if run_cmd bash -c "$(run_cmd curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"; then
        log "NextTrace 安装成功." "info"
    else
        log "警告: NextTrace 安装失败." "error" # 非致命错误
    fi
fi
step_end 5 "Docker 和 NextTrace 部署完成"

# --- 步骤 6: 检查并启动 Docker Compose 容器 ---
step_start 6 "检查并启动 Docker Compose 定义的容器"
SUCCESSFUL_RUNNING_CONTAINERS=0 # 统计在 configured_dirs 中成功运行的容器总数
FAILED_DIRS="" # 存放 Compose 启动失败的目录列表

# 判断正确的 docker compose 命令 (插件 vs 独立命令)
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
        for file in compose.yaml docker-compose.yml; do # 优先 yaml
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
                    # 重创以处理配置变更，非致命错误
                    if $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate; then
                        sleep 5 # 短暂等待启动
                        NEW_RUNNING_COUNT=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                        log "目录 '$dir' 启动/重创尝试成功. $NEW_RUNNING_COUNT 个容器正在运行." "info"
                        SUCCESSFUL_RUNNING_CONTAINERS=$((SUCCESSFUL_RUNNING_CONTAINERS + NEW_RUNNING_COUNT))
                    else
                        log "错误: Compose 启动失败目录: '$dir'." "error" # 非致命错误
                        FAILED_DIRS+=" $dir"
                    fi
                fi
                cd - >/dev/null
            else
                log "错误: 无法进入目录 '$dir'。跳过." "error" # 非致命错误
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
# 确保 tuned 服务已启用并启动
if systemctl list-unit-files --type=service | grep -q tuned.service; then
    check_and_start_service tuned.service || log "警告: tuned 服务启动失败." "warn" # 非致命错误
else
    log "未检测到 tuned 服务. 跳过调优配置." "warn"
fi
# 设置系统时区为亚洲/上海
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        log "设置时区为亚洲/上海..." "warn"
        timedatectl set-timezone Asia/Shanghai && log "时区成功设置为亚洲/上海." "info" || log "timedatectl 设置时区失败." "error" # 非致命错误
    else
        log "时区已是亚洲/上海." "info"
    fi
else
    log "未检测到 timedatectl 命令。跳过时区设置." "warn"
fi
# 确保 systemd-timesyncd 已启动 (如果存在) - 脚本不强制安装，但确保已安装的在运行
check_and_start_service systemd-timesyncd.service || log "systemd-timesyncd 服务检查失败或不存在." "info"
# 如果使用 chrony，确保 chrony 服务已启动 (如果存在) - 脚本不强制安装，但检查已安装的
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
             SKIP_SYSCTL_CONFIG=true # 如果确定 BBR 模块不可用，则跳过 sysctl 配置
        fi
    fi

    if [ "$SKIP_SYSCTL_CONFIG" != true ]; then
        [ ! -f /etc/sysctl.conf.bak.orig ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.orig && log "已备份 /etc/sysctl.conf." "info"
        log "配置 sysctl 参数 for BBR and $QDISC_TYPE..." "info"

        # 使用 sed 查找并删除所有现有的，包括注释掉的行，然后追加新的。使用 '|' 作为分隔符。
        # net.ipv4.tcp_congestion_control
        sed -i '\| *#\? *net\.ipv4\.tcp_congestion_control=|d' /etc/sysctl.conf && log "已移除旧的 net.ipv4.tcp_congestion_control 行." "info" || log "移除旧的 net.ipv4.tcp_congestion_control 行失败或不存在旧行." "info"
        echo "net.ipv4.tcp_congestion_control=bbr" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.ipv4.tcp_congestion_control=bbr." "info" || log "追加 net.ipv4.tcp_congestion_control 失败." "error" # 非致命错误

        # net.core.default_qdisc
        sed -i '\| *#\? *net\.core\.default_qdisc=|d' /etc/sysctl.conf && log "已移除旧的 net.core.default_qdisc 行." "info" || log "移除旧的 net.core.default_qdisc 行失败或不存在旧行." "info"
        echo "net.core.default_qdisc=fq_codel" | run_cmd tee -a /etc/sysctl.conf > /dev/null && log "已追加 net.core.default_qdisc=fq_codel." "info" || log "追加 net.core.default_qdisc 失败." "error" # 非致命错误

        log "应用 sysctl 配置..." "warn"
        # `sysctl -p` 如果失败可能只是部分参数问题，不强制脚本失败
        run_cmd sysctl -p || log "警告: 'sysctl -p' 失败. 检查配置语法." "warn" # 非致命错误

        # 验证当前设置 (即使 sysctl -p 失败也尝试获取)
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
CHANGE_PORT_REQUESTED=false # 标记用户是否尝试更改端口

if [ -n "$new_port_input" ]; then
    CHANGE_PORT_REQUESTED=true
    # 验证输入的端口号是否为有效数字且在指定范围内
    if ! [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
        log "输入无效，端口未更改." "error" # 非致命错误
    elif [ "$new_port_input" -lt 1024 ] || [ "$new_port_input" -gt 65535 ]; then
        log "端口号无效，端口未更改." "error" # 非致命错误
    # 检查新的端口是否已被占用
    elif ss -tuln | grep -q ":$new_port_input\b"; then
        log "警告: 端口 $new_port_input 已被占用. 端口未更改." "warn" # 非致命错误
    else
        log "正在更改 SSH 端口为 $new_port_input..." "warn"
        # 移除旧的 Port 行并添加新行
        # 使用 sed 查找并删除所有现有的 Port 行，包括注释掉的。使用 '|' 作为分隔符。
        sed -i '\| *#\? *Port |d' /etc/ssh/sshd_config && log "已移除旧的 Port 行." "info" || log "移除旧的 Port 行失败或不存在旧行." "info"
        echo "Port $new_port_input" >> /etc/ssh/sshd_config && log "已添加 Port $new_port_input 到 sshd_config." "info" || log "添加 Port 行到 sshd_config 失败." "error" # 非致命错误

        log "重启 SSH 服务应用新端口..." "warn"
        if systemctl restart sshd; then
            log "SSH 服务重启成功. 新端口 $new_port_input 已生效." "info"
            NEW_SSH_PORT_SET="$new_port_input" # 更新变量，标记端口更改成功
        else
            log "错误: SSH 服务重启失败! 新端口可能未生效. 请手动检查!" "error" # 非致命错误
            NEW_SSH_PORT_SET="Failed to restart/$new_port_input" # 在变量中标记失败，用于摘要
        fi
    fi
fi
step_end 9 "SSH 端口管理完成"

# --- 步骤 10: 部署自动更新脚本和 Cron 任务 ---
step_start 10 "部署自动更新脚本和 Crontab 任务"
UPDATE_SCRIPT="/root/auto-update.sh"
# 写入自动更新脚本内容
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
# -----------------------------------------------------------------------------
# 自动化系统更新与内核重启脚本
# 更新软件包，检查新内核，并在必要时重启。
# -----------------------------------------------------------------------------

# --- 配置 ---
LOGFILE="/var/log/auto-update.log"
APT_OPTIONS="-y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""

# --- 自动更新脚本内部日志函数 ---
log_update() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S (%Z)')] $1" >>"$LOGFILE"
}

# --- 主逻辑 ---
log_update "启动自动化系统更新."

log_update "运行 apt update..."
apt update $APT_OPTIONS >>"$LOGFILE" 2>&1
UPDATE_EXIT_STATUS=$?
if [ $UPDATE_EXIT_STATUS -ne 0 ]; then
    log_update "警告: apt update 失败，退出状态码 $UPDATE_EXIT_STATUS."
fi

log_update "运行 apt upgrade..."
DEBIAN_FRONTEND=noninteractive apt upgrade $APT_OPTIONS >>"$LOGFILE" 2>&1
UPGRADE_EXIT_STATUS=$?
if [ $UPGRADE_EXIT_STATUS -ne 0 ]; then
     log_update "警告: apt upgrade 失败，退出状态码 $UPGRADE_EXIT_STATUS."
fi

# 检查是否有新内核需要重启
RUNNING_KERNEL="$(uname -r)"
# 查找最新安装的非 meta 内核包
INSTALLED_KERNEL_PKG="$(dpkg --list 'linux-image-*' | awk '/^ii/{print $2}' | grep -v -E '^linux-image-(amd64|cloud-amd64|.+?-cloud-amd64)$' | sort -V | tail -n1 || true)"

log_update "当前运行内核: $RUNNING_KERNEL"
log_update "最新安装内核包: ${INSTALLED_KERNEL_PKG:-未找到}"

INSTALLED_KERNEL_VERSION=""
if [ -n "$INSTALLED_KERNEL_PKG" ]; then
    INSTALLED_KERNEL_VERSION="$(echo "$INSTALLED_KERNEL_PKG" | sed 's/linux-image-//')"
fi

if [ -n "$INSTALLED_KERNEL_VERSION" ] && [ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL_VERSION" ]; then
    log_update "检测到新内核 ($INSTALLED_KERNEL_VERSION) 与运行内核 ($RUNNING_KERNEL) 不同."
    # 重启前检查并尝试启动 sshd
    if ! systemctl is-active sshd >/dev/null 2>&1; then
         log_update "SSHD 服务未运行，尝试启动..."
         systemctl restart sshd >>"$LOGFILE" 2>&1 || log_update "警告: SSHD 启动失败!" # 非致命错误
    fi
    log_update "因新内核需要重启系统..."
    reboot
else
    log_update "无需重启，内核已是最新."
fi
log_update "自动更新脚本执行完毕."
EOF

chmod +x "$UPDATE_SCRIPT" && log "自动更新脚本已创建并可执行." "info" || log "设置脚本可执行失败." "error" # 非致命错误

# 配置 Crontab 条目 (每周日 00:05) 并去重
CRON_CMD="5 0 * * 0 $UPDATE_SCRIPT"
# 移除旧的包含 auto-update.log 重定向的行，并添加新行
(crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "auto-update.log"; echo "$CRON_CMD") | sort -u | crontab -
log "Crontab 已配置每周日 00:05 执行，并确保唯一性." "info"

step_end 10 "自动更新脚本与 Crontab 任务部署完成"

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

# Fish 安装状态 (使用步骤 4 中设置的变量)
show_info "Fish Shell 状态" "$FISH_INSTALL_STATUS"
fish_path=$(command -v fish 2>/dev/null || true)
[ -n "$fish_path" ] && show_info "Fish Shell 路径" "$fish_path"

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

# NextTrace 状态 (增加过滤 [API])
# 使用 sed 移除可能的 "[API]" 字符串
NEXTTRACE_VER_SUMMARY=$(nexttrace -V 2>/dev/null | awk '{print $2}' | tr -d ',' | sed 's/\[API\]//g' || echo '未安装')
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
    log "警告: 无法创建状态文件 $STATUS_FILE." "error" # 非致命错误
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
