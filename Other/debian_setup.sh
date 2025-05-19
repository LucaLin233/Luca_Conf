#!/bin/bash
# -----------------------------------------------------------------------------
# Debian 系统部署与优化脚本
# 版本: X.X (修复 Bug，集成 Zram，强化 Fish 安装鲁棒性)
# 适用系统: Debian 12
# 功能概述: 包含 Fish Shell, Docker, Zram, 网络优化, SSH 加固, 自动更新等功能。
# 脚本特性: 幂等可重复执行，确保 Cron 定时任务唯一性。
#
# 作者: LucaLin233
# 贡献者/优化: Linux AI Buddy (Zram 配置优化 - 使用 PERCENT)
# -----------------------------------------------------------------------------

# --- 脚本版本 ---
# 请根据实际修改版本号
# 修复 check_and_start_service 函数语法错误的版本
# 集成 Zram with zstd/PERCENT=50 的版本
SCRIPT_VERSION="1.7.6" # 更新版本号以反映 Zram 的优化

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
check_and_start_service() {
    local service_name="$1"
    if ! systemctl list-unit-files --type=service | grep -q "^${service_name}\s"; then
        log "$service_name 服务文件不存在，跳过检查和启动." "info"
        return 0
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

# run_cmd <命令> [参数...] - 执行命令并检查退出状态
run_cmd() {
    "$@"
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        if [ "$1" = "apt" ] && ([ "$2" = "upgrade" ] || [ "$2" = "full-upgrade" ]) && [ "$exit_status" -eq 100 ]; then
             log "命令 '$*' 返回退出码 100，继续执行." "warn"
             return 0
        fi
        # 对于非致命命令，记录警告；对于其他命令，记录错误并可能返回失败
        case "$1" in
            sysctl|/bin/cp|/bin/rm|sed|tee|chmod|chsh|mkdir) # 扩展非致命命令列表
                log "执行命令警告 (非致命): '$*'. 退出状态: $exit_status" "warn"
                return 0 # 即使这些命令失败，也允许脚本继续
                ;;
            *)
                log "执行命令失败: '$*'. 退出状态: $exit_status" "error"
                return 1
                ;;
        esac
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

# MEM_TOTAL 在需要时获取，避免过早获取导致后续free命令不准确（如果脚本运行时间较长）
MEM_TOTAL="" # 初始化

# --- 步骤 1: 网络与基础工具检查 ---
step_start 1 "网络与基础工具检查"
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
    log "警告: 网络不稳定，可能影响安装." "warn"
    read -p "确定继续? (y/n): " continue_install
    if [ "$continue_install" != "y" ]; then
        exit 1
    fi
fi
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
    run_cmd apt upgrade -y
else
    log "首次运行: 执行完整的系统升级." "info"
    run_cmd apt full-upgrade -y
fi
PKGS_TO_INSTALL=()
for pkg in dnsutils wget curl rsync chrony cron tuned; do
    if ! dpkg -s "$pkg" &>/dev/null; then
         PKGS_TO_INSTALL+=($pkg)
    fi
done
if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    log "安装缺少的核心软件包: ${PKGS_TO_INSTALL[*]}" "info"
    run_cmd apt install -y "${PKGS_TO_INSTALL[@]}" || step_fail 2 "核心软件包安装失败."
else
    log "所有核心软件包已安装!" "info"
fi
HNAME=$(hostname)
if grep -q "^127.0.1.1" /etc/hosts; then
    if ! grep "^127.0.1.1" /etc/hosts | grep -wq "$HNAME"; then
        run_cmd cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S) # 更精确的备份文件名
        run_cmd sed -i "/^127.0.1.1/ s/\$/ $HNAME/" /etc/hosts
        log "已将主机名 $HNAME 添加到 127.0.1.1 行." "warn"
    fi
else
    echo "127.0.1.1 $HNAME" | run_cmd tee -a /etc/hosts > /dev/null
    log "已将 127.0.1.1 和主机名 $HNAME 追加到 /etc/hosts." "warn"
fi
step_end 2 "系统更新与核心软件包就绪"

# --- 步骤 3: 配置并启用 Zram Swap (使用 zstd 压缩，物理内存一半通过 PERCENT) ---
step_start 3 "配置并启用 Zram Swap (使用 zstd 压缩，物理内存一半通过 PERCENT)"
ZRAM_SWAP_STATUS="未配置/检查失败"
ZRAM_CONFIG_FILE="/etc/default/zramswap"

# 1. 安装 zram-tools (如果尚未安装)
if ! dpkg -l | grep -q "^ii\s*zram-tools\s"; then
    log "未检测到 zram-tools。正在安装..." "warn"
    if run_cmd apt update; then
        if run_cmd apt install -y zram-tools; then
            log "zram-tools 安装成功." "info"
            ZRAM_SWAP_STATUS="已安装，待配置"
        else
            log "错误: zram-tools 安装失败." "error"
            ZRAM_SWAP_STATUS="安装失败"
            step_fail 3 "安装 zram-tools 失败."
        fi
    else
        log "apt update 失败，无法安装 zram-tools." "error"
        ZRAM_SWAP_STATUS="apt更新失败，安装跳过"
        step_fail 3 "安装 zram-tools 前 apt update 失败."
    fi
else
    log "zram-tools 已安装." "info"
    ZRAM_SWAP_STATUS="已安装，检查配置"
fi

# 只有当 zram-tools 成功安装后，才进行配置和启动
if echo "$ZRAM_SWAP_STATUS" | grep -q "已安装"; then
    log "配置 $ZRAM_CONFIG_FILE (ALGO=zstd, PERCENT=50)..." "warn"

    # 备份原始配置文件 (如果存在且与默认不同或未备份过)
    ZRAM_BACKUP_FILE="$ZRAM_CONFIG_FILE.bak.orig.$SCRIPT_VERSION"
    if [ -f "$ZRAM_CONFIG_FILE" ] && [ ! -f "$ZRAM_BACKUP_FILE" ]; then
        # 简单的检查，避免覆盖重要用户配置，实际可更复杂
        if grep -q "ALGO=zstd" "$ZRAM_CONFIG_FILE" && grep -q "PERCENT=50" "$ZRAM_CONFIG_FILE"; then
            log "$ZRAM_CONFIG_FILE 已包含期望配置，跳过备份和覆盖." "info"
        else
            run_cmd /bin/cp "$ZRAM_CONFIG_FILE" "$ZRAM_BACKUP_FILE" && log "已备份 $ZRAM_CONFIG_FILE 为 $ZRAM_BACKUP_FILE." "info"
        fi
    elif [ ! -f "$ZRAM_CONFIG_FILE" ]; then
        log "$ZRAM_CONFIG_FILE 不存在，将创建新文件." "info"
    fi

    # 写入配置，确保幂等性
    {
        echo "# Configuration for zram-tools (managed by deployment script v$SCRIPT_VERSION)"
        echo "# Compression algorithm: zstd"
        echo "ALGO=zstd"
        echo "# Percentage of RAM for zram: 50%"
        echo "PERCENT=50"
        # 保留或设置默认的 PRIORITY (如果需要)
        echo "# Priority for zram swap devices"
        echo "PRIORITY=100" # 默认优先级
    } | run_cmd tee "$ZRAM_CONFIG_FILE" > /dev/null

    if [ $? -eq 0 ]; then
        log "已将 ALGO=zstd 和 PERCENT=50 (及 PRIORITY=100) 写入 $ZRAM_CONFIG_FILE." "info"
    else
        log "写入 $ZRAM_CONFIG_FILE 失败." "error"
        ZRAM_SWAP_STATUS="配置文件写入失败 (zstd, 50%)"
        # 不在此处 step_fail，让服务重启尝试，但状态会反映问题
    fi

    # 重启/启动 zramswap.service 应用配置
    log "重启 zramswap.service 应用新配置..." "warn"
    if systemctl list-unit-files --type=service | grep -q "^zramswap.service\s"; then
         run_cmd systemctl stop zramswap.service # 尝试停止，忽略错误
         if run_cmd systemctl daemon-reload && \
            run_cmd systemctl enable zramswap.service && \
            run_cmd systemctl start zramswap.service; then
             log "zramswap.service start 命令成功." "info"
             sleep 3
             if systemctl is-active zramswap.service >/dev/null 2>&1; then
                 log "zramswap.service 服务已活跃." "info"
                 if swapon --show | grep -q "/dev/zram"; then
                     ZRAM_DEVICE_INFO=$(swapon --show | grep "/dev/zram" | awk '{print $1 " (Size: " $3 ", Used: " $4 ", Prio: " $5 ")"}')
                     ZRAM_SWAP_STATUS="已启用 (zstd, 50% RAM) - ${ZRAM_DEVICE_INFO}"
                     log "Zram Swap 已活跃: ${ZRAM_DEVICE_INFO}" "info"
                 else
                     log "警告: zramswap.service 报告活跃，但 'swapon --show' 未显示 /dev/zram. Zram Swap 可能未正确挂载." "warn"
                     ZRAM_SWAP_STATUS="服务活跃但Swap未显示Zram (zstd, 50% RAM)"
                 fi
             else
                 log "错误: zramswap.service start 后未报告活跃。" "error"
                 ZRAM_SWAP_STATUS="服务启动失败/不活跃 (zstd, 50% RAM)"
             fi
         else
             log "错误: systemctl daemon-reload/enable/start zramswap.service 命令失败." "error"
             ZRAM_SWAP_STATUS="systemd命令失败，配置未应用 (zstd, 50% RAM)"
         fi
    else
        log "未找到 zramswap.service 文件。跳过服务管理。" "warn"
        ZRAM_SWAP_STATUS="配置已写，但服务文件缺失 (zstd, 50% RAM)"
    fi
else
    log "zram-tools 安装失败或跳过，Zram Swap 配置已跳过." "warn"
fi

log "注意: 此脚本不自动处理旧 Swap 文件/分区，请手动管理." "info"
step_end 3 "Zram Swap 配置完成 (状态: $ZRAM_SWAP_STATUS)"

# --- 步骤 4: 从官方源安装 Fish Shell 并设置默认 Shell ---
step_start 4 "从官方源安装 Fish Shell 并设置默认 Shell"
FISH_INSTALL_STATUS="未安装或检查失败"

fish_path=$(command -v fish 2>/dev/null || true)
if [ -n "$fish_path" ]; then
    log "Fish Shell 已安装 (路径: $fish_path)." "info"
    FISH_INSTALL_STATUS="已安装"
else
    log "未检测到 Fish Shell。尝试从官方源安装..." "warn"
    log "添加 Fish 官方 APT 源和密钥..." "info"
    if echo "$FISH_APT_URL" | run_cmd tee "$FISH_APT_LIST_PATH" > /dev/null; then
        log "Fish 源行已添加." "info"
        if run_cmd curl -fsSL "$FISH_KEY_URL" | run_cmd gpg --dearmor -o "$FISH_GPG_KEY_PATH"; then
            log "Fish GPG 密钥导入成功." "info"
            run_cmd chmod a+r "$FISH_GPG_KEY_PATH"
        else
            log "错误: 导入 Fish GPG 密钥失败. 可能无法安装 Fish." "error"
            [ -f "$FISH_APT_LIST_PATH" ] && run_cmd rm "$FISH_APT_LIST_PATH" && log "已清除 Fish 源文件因导入密钥失败." "warn"
        fi
    else
        log "错误: 添加 Fish 官方 APT 源失败. 可能无法安装 Fish." "error"
    fi

    if [ -f "$FISH_APT_LIST_PATH" ] && [ -s "$FISH_GPG_KEY_PATH" ]; then
         log "更新 APT 缓存以包含 Fish 源..." "warn"
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
                fish_path=$(command -v fish)
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

if [ -n "$fish_path" ]; then
     if ! grep -q "^$fish_path$" /etc/shells; then
        echo "$fish_path" | run_cmd tee -a /etc/shells > /dev/null && log "已将 Fish 路径添加到 /etc/shells." "info"
    fi
    if [ "$SHELL" != "$fish_path" ]; then
        if $RERUN_MODE; then
            log "Fish 已安装但非默认 ($SHELL). 重运行模式不自动更改." "info"
            read -p "设置 Fish ($fish_path) 为默认 Shell? (y/n): " change_shell
            [ "$change_shell" = "y" ] && run_cmd chsh -s "$fish_path" && log "Fish 已设为默认 (需重登录)." "warn" || log "未更改默认 Shell." "info"
        else
            log "Fish 已安装 ($fish_path) 但非默认 ($SHELL). 设置 Fish 为默认..." "warn"
            run_cmd chsh -s "$fish_path" && log "Fish 已设为默认 (需重登录)." "warn"
        fi
    else
        log "Fish ($fish_path) 已是默认 Shell." "info"
    fi
fi
step_end 4 "Fish Shell 安装与设置完成 (状态: $FISH_INSTALL_STATUS)"

# --- 步骤 5: 安装 Docker 和 NextTrace ---
step_start 5 "安装 Docker 和 NextTrace"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}') # 在这里获取内存，用于Docker优化
if ! command -v docker &>/dev/null; then
    log "未检测到 Docker。使用 get.docker.com 安装..." "warn"
    if run_cmd bash -c "$(run_cmd curl -fsSL https://get.docker.com)"; then
        log "Docker 安装成功." "info"
        check_and_start_service docker.service
    else
        log "错误: Docker 安装失败." "error" # Docker安装失败是比较严重的问题
    fi
else
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)
    log "Docker 已安装 (版本: ${docker_version:-未知})." "info"
    check_and_start_service docker.service
fi
if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -lt 1024 ]; then
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        log "低内存环境. 优化 Docker 日志配置..." "warn"
        run_cmd mkdir -p /etc/docker
        echo '{"storage-driver": "overlay2", "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' | run_cmd tee /etc/docker/daemon.json > /dev/null
        log "重启 Docker 应用日志优化..." "warn"
        systemctl restart docker || log "警告: 重启 Docker 服务失败 (日志优化)." "warn"
    else
        log "Docker 日志优化配置已存在." "info"
    fi
fi
if command -v nexttrace &>/dev/null; then
    log "NextTrace 已安装." "info"
else
    log "未检测到 NextTrace。正在部署..." "warn"
    if run_cmd bash -c "$(run_cmd curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"; then
        log "NextTrace 安装成功." "info"
    else
        log "警告: NextTrace 安装失败." "warn" # NextTrace安装失败通常不影响核心功能
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
        for file in compose.yaml docker-compose.yml docker-compose.yaml; do # 添加 docker-compose.yaml
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
                    # 使用 run_cmd 来执行 docker-compose up，这样如果失败会记录但脚本继续
                    if $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate; then # docker-compose up 通常不适合 run_cmd 因为它的输出和错误处理比较复杂
                        sleep 5
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
if systemctl list-unit-files --type=service | grep -q tuned.service; then
    check_and_start_service tuned.service
else
    log "未检测到 tuned 服务. 跳过调优配置." "warn"
fi
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
check_and_start_service systemd-timesyncd.service # 通常会存在
# chrony 是可选安装的，如果安装了，它会禁用 systemd-timesyncd
if dpkg -s chrony &>/dev/null; then
    check_and_start_service chrony.service
fi
step_end 7 "系统服务与性能优化完成"

# --- 步骤 8: 配置 TCP 性能 (BBR) 和 Qdisc (fq_codel) ---
step_start 8 "配置 TCP 性能 (BBR) 和 Qdisc (fq_codel)"
QDISC_TYPE="fq_codel" # Debian 11+ 默认可能是 fq_codel，但明确设置确保一致
read -p "启用 BBR + $QDISC_TYPE 网络拥塞控制? (Y/n): " bbr_choice
bbr_choice="${bbr_choice:-y}"

if [[ ! "$bbr_choice" =~ ^[nN]$ ]]; then
    log "用户选择启用 BBR + $QDISC_TYPE." "info"
    SKIP_SYSCTL_CONFIG=false
    if ! /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1 || ! run_cmd /sbin/modprobe tcp_bbr; then
        log "警告: 未找到或无法加载 'tcp_bbr' 模块." "warn"
        if [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y || zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m); then
             log "'tcp_bbr' 模块已编译或可用，但加载失败 (可能已内建或冲突)." "info"
        else
             log "严重警告: 内核可能不支持 BBR. 无法启用." "error"
             SKIP_SYSCTL_CONFIG=true
        fi
    else
        log "tcp_bbr 模块已加载." "info"
    fi

    if [ "$SKIP_SYSCTL_CONFIG" != true ]; then
        SYSCTL_CONF_BACKUP="/etc/sysctl.conf.bak.orig.$SCRIPT_VERSION"
        [ ! -f "$SYSCTL_CONF_BACKUP" ] && [ -f "/etc/sysctl.conf" ] && run_cmd cp /etc/sysctl.conf "$SYSCTL_CONF_BACKUP" && log "已备份 /etc/sysctl.conf 为 $SYSCTL_CONF_BACKUP." "info"

        log "配置 sysctl 参数 for BBR and $QDISC_TYPE..." "info"
        # 使用 awk 确保只添加一次或更新现有行，更健壮
        run_cmd awk '!/^net\.ipv4\.tcp_congestion_control=|^net\.core\.default_qdisc=/' /etc/sysctl.conf > /tmp/sysctl.conf.tmp
        echo "net.ipv4.tcp_congestion_control=bbr" >> /tmp/sysctl.conf.tmp
        echo "net.core.default_qdisc=$QDISC_TYPE" >> /tmp/sysctl.conf.tmp
        run_cmd mv /tmp/sysctl.conf.tmp /etc/sysctl.conf

        log "应用 sysctl 配置..." "warn"
        if ! run_cmd sysctl -p; then # sysctl -p 失败通常是配置问题
            log "警告: 'sysctl -p' 失败. 请检查 /etc/sysctl.conf 语法." "warn"
        fi

        CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败")
        CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败")
        log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
        if [ "$CURR_CC" = "bbr" ] && [ "$CURR_QDISC" = "$QDISC_TYPE" ]; then
            log "BBR 和 $QDISC_TYPE 参数已生效." "info"
        else
            log "警告: 网络参数验证可能不匹配 (当前 CC: $CURR_CC, Qdisc: $CURR_QDISC). 可能需要重启或手动检查." "warn"
        fi
    else
        log "因 BBR 模块问题，跳过 sysctl 配置." "warn"
    fi
else
    log "跳过 BBR + $QDISC_TYPE 配置." "warn"
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败")
    CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败")
    log "当前活动 CC: $CURR_CC, Qdisc: $CURR_QDISC" "info"
fi
step_end 8 "网络性能参数配置完成"

# --- 步骤 9: 管理 SSH 安全端口 ---
step_start 9 "管理 SSH 服务端口"
SSHD_CONFIG_BACKUP="/etc/ssh/sshd_config.bak.orig.$SCRIPT_VERSION"
[ ! -f "$SSHD_CONFIG_BACKUP" ] && [ -f "/etc/ssh/sshd_config" ] && run_cmd cp /etc/ssh/sshd_config "$SSHD_CONFIG_BACKUP" && log "已备份 /etc/ssh/sshd_config 为 $SSHD_CONFIG_BACKUP." "info"

CURRENT_SSH_PORT=$(grep -i "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1) # Ignore case for Port
[ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT="22" && log "未找到 Port 配置，假定默认 22." "info" || log "当前配置 SSH 端口为 $CURRENT_SSH_PORT." "info"

if $RERUN_MODE; then
    read -p "当前 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input
else
    read -p "默认 SSH 端口为 $CURRENT_SSH_PORT。输入新端口或 Enter 跳过 (1024-65535): " new_port_input # 首次运行时提示更明确
fi

NEW_SSH_PORT_SET="$CURRENT_SSH_PORT"
CHANGE_PORT_REQUESTED=false

if [ -n "$new_port_input" ]; then
    CHANGE_PORT_REQUESTED=true
    if ! [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
        log "输入无效，端口未更改." "error"
    elif [ "$new_port_input" -lt 1024 ] || [ "$new_port_input" -gt 65535 ]; then
        log "端口号无效 ($new_port_input)，必须在 1024-65535 之间。端口未更改." "error"
    elif ss -tuln | grep -q ":$new_port_input\b"; then
        log "警告: 端口 $new_port_input 已被占用. 端口未更改." "warn"
    else
        log "正在更改 SSH 端口为 $new_port_input..." "warn"
        # 使用 awk 确保只更新或添加 Port 行
        awk -v port="$new_port_input" '
            BEGIN { port_set=0 }
            /^#? *Port / {
                if (!port_set) { print "Port " port; port_set=1 }
                next
            }
            { print }
            END { if (!port_set) print "Port " port }
        ' /etc/ssh/sshd_config > /tmp/sshd_config.tmp && run_cmd mv /tmp/sshd_config.tmp /etc/ssh/sshd_config

        if [ $? -eq 0 ]; then
            log "已更新 /etc/ssh/sshd_config 中的 Port 为 $new_port_input." "info"
            log "重启 SSH 服务应用新端口..." "warn"
            if systemctl restart sshd; then # sshd 重启失败是严重问题
                log "SSH 服务重启成功. 新端口 $new_port_input 已生效." "info"
                NEW_SSH_PORT_SET="$new_port_input"
            else
                log "错误: SSH 服务重启失败! 新端口可能未生效. 请检查 'systemctl status sshd' 和 'journalctl -xeu sshd'." "error"
                NEW_SSH_PORT_SET="Failed to restart/$CURRENT_SSH_PORT (tried $new_port_input)" # 回退到旧端口或标记失败
                # 尝试恢复备份
                if [ -f "$SSHD_CONFIG_BACKUP" ]; then
                    run_cmd cp "$SSHD_CONFIG_BACKUP" /etc/ssh/sshd_config && systemctl restart sshd && log "已从备份恢复 SSH 配置并重启服务." "warn"
                fi
            fi
        else
            log "更新 /etc/ssh/sshd_config 文件失败。" "error"
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
>"$LOGFILE"

log_update "启动自动化系统更新 (修复版 v1.6 - 日志覆盖 + pseudo-TTY)."

log_update "运行 /usr/bin/apt-get update..."
# 添加 DEBIAN_FRONTEND=noninteractive 避免可能的交互提示
DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update -o APT::ListChanges::Frontend=none >>"$LOGFILE" 2>&1
UPDATE_EXIT_STATUS=$?
if [ $UPDATE_EXIT_STATUS -ne 0 ]; then
    log_update "警告: /usr/bin/apt-get update 失败， exits $UPDATE_EXIT_STATUS."
    # 不退出，尝试继续升级
fi

# 运行前清理旧的 script 输出文件
/bin/rm -f "$SCRIPT_OUTPUT_DUMMY"

log_update "运行 /usr/bin/apt-get dist-upgrade (尝试通过 'script' 命令模拟 TTY)..."
COMMAND_TO_RUN="DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get dist-upgrade $APT_GET_OPTIONS"
# script 命令自身也可能产生错误输出到 stderr，将其也重定向到日志
/usr/bin/script -q -c "$COMMAND_TO_RUN" "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE" 2>&1
UPGRADE_EXIT_STATUS=$? # 这是 script 命令的退出状态

# 检查 script 命令是否成功执行了内部命令
# 通常如果内部命令失败，script 自身可能仍然返回 0，所以需要检查 SCRIPT_OUTPUT_DUMMY 中的内容或内部命令的特定输出
# 此处简化，主要依赖 script 命令的退出码，但更复杂的检查可以加入

if [ -f "$SCRIPT_OUTPUT_DUMMY" ]; then
    log_update "--- Output captured by 'script' command (from $SCRIPT_OUTPUT_DUMMY) ---"
    /bin/cat "$SCRIPT_OUTPUT_DUMMY" >> "$LOGFILE"
    log_update "--- End of 'script' command output ---"
    # /bin/rm -f "$SCRIPT_OUTPUT_DUMMY" # 可以取消注释以删除临时文件
else
    log_update "警告: 未找到 'script' 命令的输出文件 $SCRIPT_OUTPUT_DUMMY"
fi

# 根据 script 命令的退出码判断（虽然不完美，但比没有好）
if [ $UPGRADE_EXIT_STATUS -eq 0 ]; then
    log_update "apt-get dist-upgrade (via script) 命令执行完成 (script 命令退出码 0)."

    RUNNING_KERNEL="$(/bin/uname -r)"
    log_update "当前运行内核: $RUNNING_KERNEL"

    # 查找最新安装的 linux-image 包（通常是最高版本号）
    LATEST_INSTALLED_KERNEL_PKG=$(/usr/bin/dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image-[0-9]*.[0-9]*.[0-9]*-[0-9]*-*' 'linux-image-generic*' 'linux-image-cloud*' 2>/dev/null | /usr/bin/sort -k2 -V | /usr/bin/tail -n1 | /usr/bin/awk '{print $1}' || true)

    if [ -z "$LATEST_INSTALLED_KERNEL_PKG" ]; then
        log_update "未找到已安装的特定版本内核包。无法比较。"
        INSTALLED_KERNEL_VERSION=""
    else
        log_update "检测到的最新安装内核包: $LATEST_INSTALLED_KERNEL_PKG"
        # 从包名提取版本号，这可能需要更复杂的 sed 或 awk
        # 示例：linux-image-5.10.0-18-amd64 -> 5.10.0-18-amd64
        INSTALLED_KERNEL_VERSION=$(echo "$LATEST_INSTALLED_KERNEL_PKG" | /bin/sed -n 's/^linux-image-\([0-9\.-]*[^ ]*\)/\1/p' || true)
        if [ -z "$INSTALLED_KERNEL_VERSION" ]; then # 备用提取方法
            INSTALLED_KERNEL_VERSION=$(/usr/bin/dpkg-query -W -f='${Version}' "$LATEST_INSTALLED_KERNEL_PKG" 2>/dev/null | sed 's/^[0-9]*://' || true) # 去除 epoch
        fi
        log_update "提取到的最新内核版本字符串: $INSTALLED_KERNEL_VERSION"
    fi

    # 比较内核版本（需要注意版本字符串格式的一致性）
    # 简单的字符串比较可能不总是准确，但对于标准 Debian 内核命名通常有效
    if [ -n "$INSTALLED_KERNEL_VERSION" ] && [[ "$RUNNING_KERNEL" != *"$INSTALLED_KERNEL_VERSION"* ]] && [[ "$INSTALLED_KERNEL_VERSION" != *"$RUNNING_KERNEL"* ]]; then
        # 更可靠的比较是查看 /boot 下的 vmlinuz 文件，并与 uname -r 匹配
        # 但这里为了简单，继续使用基于包名的比较
        log_update "检测到新内核版本 ($INSTALLED_KERNEL_VERSION) 与运行内核 ($RUNNING_KERNEL) 可能不同。"

        if ! /bin/systemctl is-active sshd >/dev/null 2>&1; then
             log_update "SSHD 服务未运行，尝试启动..."
             /bin/systemctl restart sshd >>"$LOGFILE" 2>&1 || log_update "警告: SSHD 启动失败! 重启可能导致无法连接。"
        fi

        log_update "因新内核需要重启系统..."
        log_update "执行 /sbin/reboot ..."
        /sbin/reboot >>"$LOGFILE" 2>&1
        /bin/sleep 15 # 等待重启命令生效
        log_update "警告: 重启命令已发出，但脚本仍在运行？这不应该发生。" # 如果脚本还能记录，说明重启失败

    else
        log_update "内核已是最新 ($RUNNING_KERNEL 与 $INSTALLED_KERNEL_VERSION 匹配或无法确定新内核)，无需重启。"
    fi

else
    log_update "错误: apt-get dist-upgrade (via script) 未成功完成 (script 命令退出码: $UPGRADE_EXIT_STATUS). 跳过内核检查和重启。"
    log_update "请检查上面由 'script' 命令捕获的具体输出，以了解内部错误。"
fi

log_update "自动更新脚本执行完毕."
exit 0
EOF

run_cmd chmod +x "$UPDATE_SCRIPT" && log "自动更新脚本已创建并可执行." "info"

CRON_CMD="5 0 * * 0 $UPDATE_SCRIPT" # 每周日 00:05
(crontab -l 2>/dev/null | grep -vF "$UPDATE_SCRIPT" | grep -vF "auto-update.log"; echo "$CRON_CMD") | sort -u | crontab -
log "Crontab 已配置每周日 00:05 执行 '$UPDATE_SCRIPT'，并确保唯一性." "info"

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

MEM_TOTAL_HUMAN=$(free -h | grep Mem | awk '{print $2}' || echo '未知')
show_info "总内存大小" "$MEM_TOTAL_HUMAN"

DISK_USAGE_ROOT="未知"
df -h / >/dev/null 2>&1 && DISK_USAGE_ROOT=$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" "$5" ")"}')
show_info "磁盘使用 (/)" "$DISK_USAGE_ROOT"

show_info "Zram Swap 状态" "$ZRAM_SWAP_STATUS"

show_info "Fish Shell 状态" "$FISH_INSTALL_STATUS"
fish_path_summary=$(command -v fish 2>/dev/null || true)
[ -n "$fish_path_summary" ] && show_info "Fish Shell 路径" "$fish_path_summary"

DISPLAY_SSH_PORT_SUMMARY="$NEW_SSH_PORT_SET"
SSH_PORT_WARNING=""
if echo "$NEW_SSH_PORT_SET" | grep -q "Failed to restart"; then
    # NEW_SSH_PORT_SET might be "Failed to restart/22 (tried 2222)"
    ATTEMPTED_PORT=$(echo "$NEW_SSH_PORT_SET" | sed -n 's/.*(tried \([0-9]*\)).*/\1/p')
    CURRENT_EFFECTIVE_PORT=$(echo "$NEW_SSH_PORT_SET" | sed 's/\/.*//' | sed 's/Failed to restart//')
    DISPLAY_SSH_PORT_SUMMARY="$CURRENT_EFFECTIVE_PORT"
    SSH_PORT_WARNING=" (警告: SSH 服务重启失败，尝试端口 $ATTEMPTED_PORT 失败)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ] && [ "$CHANGE_PORT_REQUESTED" = true ]; then
    SSH_PORT_WARNING=" (尝试更改失败/端口被占用/无效)"
elif [ "$NEW_SSH_PORT_SET" = "$CURRENT_SSH_PORT" ]; then
     SSH_PORT_WARNING=" (未更改)"
else
     SSH_PORT_WARNING=" (已成功更改)"
fi
show_info "SSH 端口" "$DISPLAY_SSH_PORT_SUMMARY$SSH_PORT_WARNING"

DOCKER_VER_SUMMARY="未安装"
ACTIVE_CONTAINERS_COUNT="N/A"
if command -v docker >/dev/null 2>&1; then
    DOCKER_VER_SUMMARY=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '检查失败')
    ACTIVE_CONTAINERS_COUNT=$(docker ps -q 2>/dev/null | wc -l || echo '检查失败')
fi
show_info "Docker 版本" "$DOCKER_VER_SUMMARY"
show_info "活跃 Docker 容器数" "$ACTIVE_CONTAINERS_COUNT"

NEXTTRACE_VER_SUMMARY="未安装"
if command -v nexttrace >/dev/null 2>&1; then
    NEXTTRACE_FULL_OUTPUT=$(nexttrace -V 2>&1 || true)
    NEXTTRACE_VER_LINE=$(echo "$NEXTTRACE_FULL_OUTPUT" | grep -v '\[API\]' | head -n 1)
    if [ -n "$NEXTTRACE_VER_LINE" ]; then
        NEXTTRACE_VER_SUMMARY=$(echo "$NEXTTRACE_VER_LINE" | awk '{print $2}' | tr -d ',' || echo "提取失败")
    else # If only API line or empty
        NEXTTRACE_VER_SUMMARY="已安装 (版本提取失败)"
    fi
fi
[ -z "$NEXTTRACE_VER_SUMMARY" ] && NEXTTRACE_VER_SUMMARY="未安装" # Final check
show_info "NextTrace 版本" "$NEXTTRACE_VER_SUMMARY"

CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "获取失败")
CURR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "获取失败")
show_info "网络参数 (sysctl)" "CC=$CURR_CC, Qdisc=$CURR_QDISC"

BBR_MODULE_STATUS="未知"
if lsmod | grep -q "^tcp_bbr\s"; then # Check if loaded
    BBR_MODULE_STATUS="模块已加载"
elif /sbin/modprobe -n -q tcp_bbr >/dev/null 2>&1; then # Check if loadable
    BBR_MODULE_STATUS="模块可用 (但当前未加载)"
elif [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=y ); then
     BBR_MODULE_STATUS="编译进内核 (内建)"
elif [ -f "/proc/config.gz" ] && (zcat /proc/config.gz | grep -q CONFIG_TCP_BBR=m ); then
     BBR_MODULE_STATUS="编译为模块 (但当前不可用/未找到)"
else
     BBR_MODULE_STATUS="模块不存在或内核不支持"
fi
show_info "BBR 内核模块状态" "$BBR_MODULE_STATUS"

TIMEZONE_SUMMARY="未知"
command -v timedatectl >/dev/null 2>&1 && TIMEZONE_SUMMARY=$(timedatectl | grep "Time zone" | awk '{print $3" "$4" "$5}')
show_info "系统时区设置" "$TIMEZONE_SUMMARY"

show_info "当前脚本 Shell" "$SHELL"
ROOT_LOGIN_SHELL=$(getent passwd root | cut -d: -f7 || echo "获取失败")
show_info "Root 用户默认登录 Shell" "$ROOT_LOGIN_SHELL"

TUNED_PROFILE_SUMMARY=$(tuned-adm active 2>/dev/null | grep 'Current active profile:' | awk -F': ' '{print $NF}')
[ -z "$TUNED_PROFILE_SUMMARY" ] && TUNED_PROFILE_SUMMARY="(未配置或 tuned 服务未运行)"
show_info "活跃 Tuned Profile" "$TUNED_PROFILE_SUMMARY"

if [ "$SUCCESSFUL_RUNNING_CONTAINERS" -gt 0 ]; then
    show_info "Compose 容器状态" "在配置目录共检测到 $SUCCESSFUL_RUNNING_CONTAINERS 个容器运行中."
elif [ -n "$COMPOSE_CMD" ]; then # Only show if compose was attempted
    log " • Compose 容器状态: 未检测到运行中的 Compose 容器 (或所有预期容器已停止)." "info"
fi
[ -n "$FAILED_DIRS" ] && log " • 警告: Compose 启动失败目录:$FAILED_DIRS" "error" # Removed leading space

log "\n──────────────────────────────────────────────────" "title"
log " 部署完成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')" "info"
log "──────────────────────────────────────────────────\n" "title"

step_end 11 "摘要报告已生成"

# --- 保存部署状态 ---
# 清理 failed_dirs 变量，移除可能的前导空格
CLEANED_FAILED_DIRS=$(echo "$FAILED_DIRS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

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
"$CLEANED_FAILED_DIRS" \
> "$STATUS_FILE"

if [ -f "$STATUS_FILE" ]; then
    log "部署状态已保存至文件: $STATUS_FILE" "info"
else
    log "警告: 无法创建状态文件 $STATUS_FILE." "error"
fi

log "✅ 脚本执行完毕." "title"

if [ "$CHANGE_PORT_REQUESTED" = true ] && [ "$NEW_SSH_PORT_SET" = "$new_port_input" ] && [[ "$new_port_input" =~ ^[0-9]+$ ]]; then
    log "⚠️  重要提示: SSH 端口已更改为 $NEW_SSH_PORT_SET. 请使用新端口重新连接." "warn"
    log "   示例: ssh -p $NEW_SSH_PORT_SET 您的用户名@您的服务器IP地址" "warn"
elif echo "$NEW_SSH_PORT_SET" | grep -q "Failed to restart"; then
    log "⚠️  重要提示: SSH 端口更改尝试失败，SSH 服务可能仍在原端口 ($CURRENT_SSH_PORT) 或无法访问. 请检查 SSH 服务状态." "error"
fi

if $RERUN_MODE; then
    log "➡️  重运行模式: 已按需更新配置和服务." "info"
else
    log "🎉 初始部署完成!" "info"
fi
log "🔄 可随时再次运行此脚本进行维护或更新." "info"
log "手动检查建议: 请验证旧 Swap 文件/配置是否已正确移除，并检查各项服务状态。" "warn"
