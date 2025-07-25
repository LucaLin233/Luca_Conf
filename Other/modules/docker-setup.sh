#!/bin/bash
# Docker 容器化平台配置模块 v2.1.0 (优化版)
# 功能: 安装Docker, 配置优化, 容器管理, 安全加固
# 严格模式
set -euo pipefail
# 模块配置
MODULE_NAME="docker-setup"
DOCKER_CONFIG_DIR="/etc/docker"
DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"
COMPOSE_DIRS=(/root /root/proxy /root/vmagent /opt/docker-apps)
BACKUP_DIR="/var/backups/docker-setup"
# 集成主脚本日志系统
log() {
    local message="$1"
    local level="${2:-info}"
    
    if declare -f log >/dev/null 2>&1 && [ "${MODULE_LOG_FILE:-}" ]; then
        echo "[$MODULE_NAME] $message" | tee -a "${MODULE_LOG_FILE}"
    else
        local colors=(
            ["info"]=$'\033[0;36m'
            ["warn"]=$'\033[0;33m'
            ["error"]=$'\033[0;31m'
            ["success"]=$'\033[0;32m'
        )
        local color="${colors[$level]:-$'\033[0;32m'}"
        echo -e "${color}[$MODULE_NAME] $message\033[0m"
    fi
}
debug_log() {
    if [ "${MODULE_DEBUG_MODE:-false}" = "true" ]; then
        log "[DEBUG] $1" "info"
    fi
}
# 检查系统要求
check_system_requirements() {
    log "检查系统要求..." "info"
    
    # 检查内核版本 (Docker需要3.10+)
    local kernel_version=$(uname -r | cut -d. -f1,2)
    local required_version="3.10"
    
    if ! command -v bc &>/dev/null; then
        # 简单版本比较
        local major=$(echo "$kernel_version" | cut -d. -f1)
        local minor=$(echo "$kernel_version" | cut -d. -f2)
        if [ "$major" -lt 3 ] || ([ "$major" -eq 3 ] && [ "$minor" -lt 10 ]); then
            log "内核版本过低: $kernel_version (需要 >= $required_version)" "error"
            return 1
        fi
    else
        if (( $(echo "$kernel_version < $required_version" | bc -l) )); then
            log "内核版本过低: $kernel_version (需要 >= $required_version)" "error"
            return 1
        fi
    fi
    
    debug_log "内核版本检查通过: $(uname -r)"
    
    # 检查系统架构
    local arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64|armv7l)
            debug_log "系统架构支持: $arch"
            ;;
        *)
            log "不支持的系统架构: $arch" "warn"
            ;;
    esac
    
    # 检查磁盘空间 (至少需要2GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=2097152  # 2GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "磁盘空间不足: $((available_space/1024))MB (建议 >= 2GB)" "warn"
    else
        debug_log "磁盘空间充足: $((available_space/1024))MB"
    fi
    
    # 检查内存
    local total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    if [ "$total_mem" -lt 512 ]; then
        log "内存较低: ${total_mem}MB，将启用内存优化配置" "warn"
        export ENABLE_MEMORY_OPTIMIZATION=true
    else
        debug_log "内存充足: ${total_mem}MB"
        export ENABLE_MEMORY_OPTIMIZATION=false
    fi
    
    # 创建必要目录
    mkdir -p "$DOCKER_CONFIG_DIR" "$BACKUP_DIR"
    
    return 0
}
# 备份现有配置
backup_existing_config() {
    log "备份现有Docker配置..." "info"
    
    local backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/backup_$backup_timestamp"
    
    mkdir -p "$backup_path"
    
    # 备份Docker配置
    if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
        cp "$DOCKER_DAEMON_CONFIG" "$backup_path/"
        debug_log "已备份: $DOCKER_DAEMON_CONFIG"
    fi
    
    # 备份systemd配置
    if [ -d "/etc/systemd/system/docker.service.d" ]; then
        cp -r "/etc/systemd/system/docker.service.d" "$backup_path/"
        debug_log "已备份: /etc/systemd/system/docker.service.d"
    fi
    
    # 清理旧备份 (保留最近5个)
    find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" -type d | \
        sort -r | tail -n +6 | xargs rm -rf 2>/dev/null || true
    
    debug_log "配置备份完成: $backup_path"
}
# 安全的Docker安装
install_docker_safely() {
    log "开始安装Docker..." "info"
    
    # 检查是否已安装
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | tr -d ',' || echo "未知")
        log "Docker 已安装 (版本: $docker_version)" "info"
        return 0
    fi
    
    # 更新软件包列表
    log "更新软件包列表..." "info"
    if ! apt-get update -qq; then
        log "软件包列表更新失败" "error"
        return 1
    fi
    
    # 安装必要的包
    local required_packages=(
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
        "software-properties-common"
    )
    
    log "安装依赖包..." "info"
    for package in "${required_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$package"; then
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package"; then
                log "依赖包 $package 安装失败" "error"
                return 1
            fi
            debug_log "已安装依赖: $package"
        fi
    done
    
    # 添加Docker官方GPG密钥
    log "添加Docker官方GPG密钥..." "info"
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        log "GPG密钥添加失败，尝试备用安装方法..." "warn"
        return install_docker_fallback
    fi
    
    # 添加Docker官方软件源
    log "添加Docker官方软件源..." "info"
    local debian_codename=$(lsb_release -cs)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $debian_codename stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 更新软件包列表
    if ! apt-get update -qq; then
        log "Docker软件源更新失败，使用备用方法..." "warn"
        return install_docker_fallback
    fi
    
    # 安装Docker
    log "安装Docker CE..." "info"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
        log "Docker 安装成功" "success"
        return 0
    else
        log "官方源安装失败，尝试备用方法..." "warn"
        return install_docker_fallback
    fi
}
# 备用安装方法 (便利脚本)
install_docker_fallback() {
    log "使用Docker便利脚本安装..." "warn"
    
    # 下载安装脚本
    local install_script="/tmp/get-docker.sh"
    if ! curl -fsSL https://get.docker.com -o "$install_script"; then
        log "下载Docker安装脚本失败" "error"
        return 1
    fi
    
    # 验证脚本 (简单检查)
    if ! grep -q "docker" "$install_script"; then
        log "Docker安装脚本验证失败" "error"
        rm -f "$install_script"
        return 1
    fi
    
    # 执行安装
    log "执行Docker安装脚本..." "info"
    if bash "$install_script"; then
        log "Docker 安装成功" "success"
        rm -f "$install_script"
        return 0
    else
        log "Docker 安装失败" "error"
        rm -f "$install_script"
        return 1
    fi
}
# 配置Docker服务
configure_docker_service() {
    log "配置Docker服务..." "info"
    
    # 启用Docker服务
    if systemctl list-unit-files --type=service | grep -q "docker.service"; then
        if ! systemctl is-enabled docker.service &>/dev/null; then
            systemctl enable docker.service
            debug_log "已启用Docker服务"
        fi
        
        if ! systemctl is-active docker.service &>/dev/null; then
            systemctl start docker.service
            debug_log "已启动Docker服务"
        fi
        
        # 等待服务完全启动
        local retry_count=0
        local max_retries=30
        
        while ! docker info &>/dev/null && [ $retry_count -lt $max_retries ]; do
            sleep 1
            ((retry_count++))
            debug_log "等待Docker服务启动... ($retry_count/$max_retries)"
        done
        
        if docker info &>/dev/null; then
            log "Docker 服务启动成功" "success"
        else
            log "Docker 服务启动超时" "error"
            return 1
        fi
    else
        log "未找到Docker服务单元" "error"
        return 1
    fi
    
    # 配置用户组 (可选)
    if [ "${ADD_USER_TO_DOCKER_GROUP:-false}" = "true" ] && [ -n "${SUDO_USER:-}" ]; then
        if ! groups "$SUDO_USER" | grep -q docker; then
            usermod -aG docker "$SUDO_USER"
            log "已将用户 $SUDO_USER 添加到docker组" "info"
        fi
    fi
    
    return 0
}
# --- Docker配置优化 ---
optimize_docker_configuration() {
    log "优化Docker配置..." "info"
    
    # 备份现有配置
    if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
        cp "$DOCKER_DAEMON_CONFIG" "${DOCKER_DAEMON_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        debug_log "已备份现有daemon.json"
    fi
    
    # 检测系统资源
    local total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    local cpu_cores=$(nproc)
    local storage_driver="overlay2"
    
    # 检测存储驱动支持
    if ! grep -q overlay /proc/filesystems; then
        log "overlay2存储驱动不支持，使用默认驱动" "warn"
        storage_driver="devicemapper"
    fi
    
    # 构建daemon.json配置
    local daemon_config=""
    
    # 基础配置
    daemon_config=$(cat << EOF
{
  "storage-driver": "$storage_driver",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "$([ "$total_mem" -lt 1024 ] && echo "10m" || echo "50m")",
    "max-file": "$([ "$total_mem" -lt 1024 ] && echo "3" || echo "5")"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
EOF
    )
    
    # 内存优化配置
    if [ "$ENABLE_MEMORY_OPTIMIZATION" = "true" ]; then
        log "应用内存优化配置..." "info"
        daemon_config+=',
  "default-shm-size": "64m",
  "default-runtime": "runc",
  "experimental": false'
    else
        daemon_config+=',
  "default-shm-size": "128m",
  "experimental": false'
    fi
    
    # 安全配置
    daemon_config+=',
  "userland-proxy": false,
  "live-restore": true,
  "no-new-privileges": true'
    
    # 网络配置
    daemon_config+=',
  "bridge": "docker0",
  "fixed-cidr": "172.17.0.0/16",
  "default-address-pools": [
    {
      "base": "172.80.0.0/12",
      "size": 24
    }
  ]'
    
    # 性能优化
    if [ "$cpu_cores" -gt 2 ]; then
        daemon_config+=',
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 5'
    else
        daemon_config+=',
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 2'
    fi
    
    # 关闭配置
    daemon_config+='
}'
    
    # 写入配置文件
    echo "$daemon_config" > "$DOCKER_DAEMON_CONFIG"
    
    # 验证JSON格式
    if ! python3 -m json.tool "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1; then
        if ! jq . "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1; then
            log "daemon.json格式验证失败，恢复备份" "error"
            if [ -f "${DOCKER_DAEMON_CONFIG}.backup."* ]; then
                cp "${DOCKER_DAEMON_CONFIG}.backup."* "$DOCKER_DAEMON_CONFIG"
            fi
            return 1
        fi
    fi
    
    log "Docker配置文件已更新" "success"
    debug_log "配置内容: $(cat "$DOCKER_DAEMON_CONFIG")"
    
    # 重启Docker服务应用配置
    log "重启Docker服务以应用配置..." "info"
    if systemctl restart docker.service; then
        # 等待服务重启完成
        sleep 5
        if docker info &>/dev/null; then
            log "Docker服务重启成功，配置已生效" "success"
        else
            log "Docker服务重启后无法连接，检查配置..." "error"
            return 1
        fi
    else
        log "Docker服务重启失败" "error"
        return 1
    fi
    
    return 0
}
# --- 镜像加速配置 ---
configure_registry_mirrors() {
    log "配置Docker镜像加速..." "info"
    
    # 国内镜像源列表
    local mirror_registries=(
        "https://docker.mirrors.ustc.edu.cn"
        "https://hub-mirror.c.163.com"
        "https://mirror.baidubce.com"
    )
    
    # 检测网络环境
    local use_mirrors=false
    
    # 简单检测是否在中国大陆
    if curl -s --connect-timeout 5 --max-time 10 "http://ip-api.com/json" | grep -q '"country":"China"'; then
        use_mirrors=true
        log "检测到中国大陆网络环境，启用镜像加速" "info"
    elif ! curl -s --connect-timeout 5 --max-time 10 "https://registry-1.docker.io" >/dev/null; then
        log "Docker Hub连接缓慢，建议启用镜像加速" "warn"
        if [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否启用Docker镜像加速? (y/N): " enable_mirrors
            [[ "$enable_mirrors" =~ ^[Yy]$ ]] && use_mirrors=true
        fi
    fi
    
    if [ "$use_mirrors" = "true" ]; then
        # 测试镜像源可用性
        local working_mirrors=()
        
        for mirror in "${mirror_registries[@]}"; do
            if curl -s --connect-timeout 3 --max-time 5 "$mirror" >/dev/null 2>&1; then
                working_mirrors+=("$mirror")
                debug_log "镜像源可用: $mirror"
            else
                debug_log "镜像源不可用: $mirror"
            fi
        done
        
        if [ ${#working_mirrors[@]} -gt 0 ]; then
            # 更新daemon.json添加镜像源
            local temp_config=$(mktemp)
            
            if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
                # 使用jq或python处理JSON
                if command -v jq >/dev/null 2>&1; then
                    jq --argjson mirrors "$(printf '%s\n' "${working_mirrors[@]}" | jq -R . | jq -s .)" \
                       '.["registry-mirrors"] = $mirrors' "$DOCKER_DAEMON_CONFIG" > "$temp_config"
                else
                    # 备用方法：手动添加
                    python3 -c "
import json
import sys
with open('$DOCKER_DAEMON_CONFIG', 'r') as f:
    config = json.load(f)
config['registry-mirrors'] = $(printf '%s\n' "${working_mirrors[@]}" | python3 -c 'import sys, json; print(json.dumps([line.strip() for line in sys.stdin]))')
with open('$temp_config', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null || {
                        log "JSON处理失败，跳过镜像源配置" "warn"
                        rm -f "$temp_config"
                        return 0
                    }
                fi
                
                # 验证并应用配置
                if python3 -m json.tool "$temp_config" >/dev/null 2>&1; then
                    mv "$temp_config" "$DOCKER_DAEMON_CONFIG"
                    log "已配置 ${#working_mirrors[@]} 个镜像加速源" "success"
                    
                    # 重启Docker应用配置
                    systemctl restart docker.service
                    sleep 3
                else
                    log "镜像源配置格式错误，跳过" "warn"
                    rm -f "$temp_config"
                fi
            fi
        else
            log "没有可用的镜像加速源" "warn"
        fi
    else
        debug_log "跳过镜像加速配置"
    fi
}
# --- NextTrace工具安装优化 ---
install_nexttrace_enhanced() {
    log "检查并安装NextTrace..." "info"
    
    # 检查是否已安装
    if command -v nexttrace &>/dev/null; then
        local version=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' || echo "未知")
        log "NextTrace 已安装 (版本: $version)" "info"
        return 0
    fi
    
    # 检测系统架构
    local arch=$(uname -m)
    local download_arch=""
    
    case "$arch" in
        x86_64) download_arch="amd64" ;;
        aarch64) download_arch="arm64" ;;
        armv7l) download_arch="armv7" ;;
        *)
            log "不支持的架构: $arch，跳过NextTrace安装" "warn"
            return 0
            ;;
    esac
    
    log "为架构 $arch 安装NextTrace..." "info"
    
    # 方法1: 使用官方安装脚本
    if install_nexttrace_official; then
        return 0
    fi
    
    # 方法2: 手动下载二进制文件
    log "官方脚本失败，尝试手动安装..." "warn"
    if install_nexttrace_manual "$download_arch"; then
        return 0
    fi
    
    log "NextTrace 安装失败" "warn"
    return 1
}
install_nexttrace_official() {
    local install_script="/tmp/nt_install.sh"
    
    # 下载安装脚本
    if ! curl -fsSL --connect-timeout 10 --max-time 30 \
         "https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh" \
         -o "$install_script"; then
        debug_log "NextTrace官方脚本下载失败"
        return 1
    fi
    
    # 简单验证脚本内容
    if ! grep -q "nexttrace" "$install_script"; then
        debug_log "NextTrace脚本验证失败"
        rm -f "$install_script"
        return 1
    fi
    
    # 执行安装
    if bash "$install_script" 2>/dev/null; then
        rm -f "$install_script"
        if command -v nexttrace &>/dev/null; then
            log "NextTrace 安装成功" "success"
            return 0
        fi
    fi
    
    rm -f "$install_script"
    return 1
}
install_nexttrace_manual() {
    local arch="$1"
    local version="latest"
    local binary_url="https://github.com/sjlleo/nexttrace/releases/latest/download/nexttrace_linux_${arch}"
    local install_path="/usr/local/bin/nexttrace"
    
    # 下载二进制文件
    log "下载NextTrace二进制文件..." "info"
    if curl -fsSL --connect-timeout 15 --max-time 60 \
            "$binary_url" -o "/tmp/nexttrace"; then
        
        # 验证文件
        if [ -s "/tmp/nexttrace" ] && file "/tmp/nexttrace" | grep -q "ELF"; then
            # 安装到系统路径
            chmod +x "/tmp/nexttrace"
            mv "/tmp/nexttrace" "$install_path"
            
            # 验证安装
            if command -v nexttrace &>/dev/null; then
                log "NextTrace 手动安装成功" "success"
                return 0
            fi
        else
            debug_log "NextTrace二进制文件验证失败"
        fi
    else
        debug_log "NextTrace二进制文件下载失败"
    fi
    
    rm -f "/tmp/nexttrace"
    return 1
}
# --- Docker Compose检测和安装 ---
ensure_docker_compose() {
    log "检查Docker Compose..." "info"
    
    local compose_cmd=""
    local compose_version=""
    
    # 检测Docker Compose V2 (推荐)
    if docker compose version &>/dev/null; then
        compose_cmd="docker compose"
        compose_version=$(docker compose version --short 2>/dev/null || echo "v2.x")
        log "检测到Docker Compose V2 (版本: $compose_version)" "info"
    # 检测Docker Compose V1 (传统)
    elif command -v docker-compose &>/dev/null; then
        compose_cmd="docker-compose"
        compose_version=$(docker-compose --version | awk '{print $3}' | tr -d ',' || echo "v1.x")
        log "检测到Docker Compose V1 (版本: $compose_version)" "info"
    else
        log "未检测到Docker Compose，尝试安装..." "warn"
        if install_docker_compose; then
            # 重新检测
            if docker compose version &>/dev/null; then
                compose_cmd="docker compose"
            elif command -v docker-compose &>/dev/null; then
                compose_cmd="docker-compose"
            fi
        else
            log "Docker Compose 安装失败，跳过容器管理" "warn"
            return 1
        fi
    fi
    
    export DETECTED_COMPOSE_CMD="$compose_cmd"
    debug_log "使用Compose命令: $compose_cmd"
    return 0
}
install_docker_compose() {
    log "安装Docker Compose..." "info"
    
    # 方法1: 通过Docker插件安装 (推荐)
    if install_compose_plugin; then
        return 0
    fi
    
    # 方法2: 手动下载安装
    log "插件安装失败，尝试手动安装..." "warn"
    if install_compose_standalone; then
        return 0
    fi
    
    return 1
}
install_compose_plugin() {
    # 检查是否已安装compose插件
    if docker compose version &>/dev/null; then
        debug_log "Docker Compose插件已安装"
        return 0
    fi
    
    # 通过apt安装
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin 2>/dev/null; then
        log "Docker Compose 插件安装成功" "success"
        return 0
    fi
    
    return 1
}
install_compose_standalone() {
    local arch=$(uname -m)
    local compose_arch=""
    
    case "$arch" in
        x86_64) compose_arch="x86_64" ;;
        aarch64) compose_arch="aarch64" ;;
        armv7l) compose_arch="armv7" ;;
        *)
            log "不支持的架构: $arch" "warn"
            return 1
            ;;
    esac
    
    # 获取最新版本号
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/docker/compose/releases/latest" | \
                    grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null || echo "v2.20.0")
    
    local download_url="https://github.com/docker/compose/releases/download/${latest_version}/docker-compose-linux-${compose_arch}"
    local install_path="/usr/local/bin/docker-compose"
    
    log "下载Docker Compose ${latest_version}..." "info"
    if curl -fsSL --connect-timeout 15 --max-time 120 \
            "$download_url" -o "/tmp/docker-compose"; then
        
        if [ -s "/tmp/docker-compose" ] && file "/tmp/docker-compose" | grep -q "ELF"; then
            chmod +x "/tmp/docker-compose"
            mv "/tmp/docker-compose" "$install_path"
            
            if command -v docker-compose &>/dev/null; then
                log "Docker Compose standalone 安装成功" "success"
                return 0
            fi
        fi
    fi
    
    rm -f "/tmp/docker-compose"
    return 1
}
# --- 增强的容器发现和管理 ---
discover_and_manage_containers() {
    log "扫描和管理Docker容器..." "info"
    
    if [ -z "${DETECTED_COMPOSE_CMD:-}" ]; then
        log "Docker Compose 不可用，跳过容器管理" "warn"
        return 0
    fi
    
    # 扩展容器搜索目录
    local search_dirs=(
        "/root"
        "/root/proxy" 
        "/root/vmagent"
        "/opt/docker-apps"
        "/home/*/docker"
        "/srv/docker"
    )
    
    # 动态发现包含docker-compose文件的目录
    local discovered_dirs=()
    
    log "搜索Docker Compose项目..." "info"
    for base_dir in "${search_dirs[@]}"; do
        # 处理通配符路径
        for dir in $base_dir; do
            if [ -d "$dir" ]; then
                # 查找compose文件
                find "$dir" -maxdepth 2 -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yaml" 2>/dev/null | \
                while read -r compose_file; do
                    local project_dir=$(dirname "$compose_file")
                    discovered_dirs+=("$project_dir")
                    debug_log "发现项目: $project_dir ($(basename "$compose_file"))"
                done
            fi
        done
    done
    
    # 去重
    local unique_dirs=($(printf '%s\n' "${discovered_dirs[@]}" | sort -u))
    
    if [ ${#unique_dirs[@]} -eq 0 ]; then
        log "未发现Docker Compose项目" "info"
        return 0
    fi
    
    log "发现 ${#unique_dirs[@]} 个Docker Compose项目" "info"
    
    # 处理每个项目
    local total_managed=0
    local total_started=0
    local failed_projects=()
    
    for project_dir in "${unique_dirs[@]}"; do
        if manage_compose_project "$project_dir"; then
            ((total_managed++))
        else
            failed_projects+=("$project_dir")
        fi
    done
    
    # 统计结果
    local running_containers=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    
    log "容器管理完成:" "success"
    log "  • 项目总数: ${#unique_dirs[@]}" "info"
    log "  • 成功管理: $total_managed" "info"
    log "  • 失败项目: ${#failed_projects[@]}" "info"
    log "  • 运行容器: $running_containers" "info"
    
    if [ ${#failed_projects[@]} -gt 0 ]; then
        log "失败的项目:" "warn"
        for failed in "${failed_projects[@]}"; do
            log "  • $failed" "warn"
        done
    fi
}
manage_compose_project() {
    local project_dir="$1"
    
    if [ ! -d "$project_dir" ]; then
        debug_log "项目目录不存在: $project_dir"
        return 1
    fi
    
    # 确定compose文件
    local compose_file=""
    for file in "compose.yaml" "docker-compose.yml" "docker-compose.yaml"; do
        if [ -f "$project_dir/$file" ]; then
            compose_file="$file"
            break
        fi
    done
    
    if [ -z "$compose_file" ]; then
        debug_log "未找到compose文件: $project_dir"
        return 1
    fi
    
    log "管理项目: $project_dir ($compose_file)" "info"
    
    # 切换到项目目录
    local original_dir=$(pwd)
    cd "$project_dir" || return 1
    
    # 项目健康检查
    if ! project_health_check "$compose_file"; then
        log "项目健康检查失败: $project_dir" "warn"
        cd "$original_dir"
        return 1
    fi
    
    # 获取项目状态
    local expected_services
    local running_containers
    
    expected_services=$($DETECTED_COMPOSE_CMD -f "$compose_file" config --services 2>/dev/null | wc -l)
    running_containers=$($DETECTED_COMPOSE_CMD -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l)
    
    debug_log "项目状态: $running_containers/$expected_services 服务运行中"
    
    # 决定操作策略
    if [ "$running_containers" -eq "$expected_services" ] && [ "$expected_services" -gt 0 ]; then
        log "项目已正常运行 ($running_containers/$expected_services)" "info"
        cd "$original_dir"
        return 0
    elif [ "$running_containers" -eq 0 ] && [ "$expected_services" -gt 0 ]; then
        log "启动项目容器..." "info"
        if start_compose_project "$compose_file"; then
            log "项目启动成功" "success"
        else
            log "项目启动失败" "error"
            cd "$original_dir"
            return 1
        fi
    else
        log "项目部分运行，尝试修复..." "warn"
        if repair_compose_project "$compose_file"; then
            log "项目修复成功" "success"
        else
            log "项目修复失败" "error"
            cd "$original_dir"
            return 1
        fi
    fi
    
    cd "$original_dir"
    return 0
}
project_health_check() {
    local compose_file="$1"
    
    # 检查compose文件语法
    if ! $DETECTED_COMPOSE_CMD -f "$compose_file" config >/dev/null 2>&1; then
        debug_log "Compose文件语法错误"
        return 1
    fi
    
    # 检查必需的网络和卷
    local networks=($($DETECTED_COMPOSE_CMD -f "$compose_file" config --networks 2>/dev/null))
    local volumes=($($DETECTED_COMPOSE_CMD -f "$compose_file" config --volumes 2>/dev/null))
    
    # 检查外部网络是否存在
    for network in "${networks[@]}"; do
        if [ "$network" != "default" ] && ! docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            debug_log "创建网络: $network"
            docker network create "$network" 2>/dev/null || true
        fi
    done
    
    return 0
}
start_compose_project() {
    local compose_file="$1"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        debug_log "启动尝试 $((retry_count + 1))/$max_retries"
        
        # 拉取最新镜像 (可选)
        if [ "${PULL_LATEST_IMAGES:-false}" = "true" ]; then
            log "拉取最新镜像..." "info"
            $DETECTED_COMPOSE_CMD -f "$compose_file" pull --quiet 2>/dev/null || true
        fi
        
        # 启动容器
        if $DETECTED_COMPOSE_CMD -f "$compose_file" up -d --remove-orphans 2>/dev/null; then
            # 等待容器启动
            sleep 5
            
            # 验证启动状态
            local healthy_containers=$($DETECTED_COMPOSE_CMD -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l)
            local expected_services=$($DETECTED_COMPOSE_CMD -f "$compose_file" config --services 2>/dev/null | wc -l)
            
            if [ "$healthy_containers" -eq "$expected_services" ]; then
                log "所有服务启动成功 ($healthy_containers/$expected_services)" "success"
                return 0
            else
                log "部分服务启动失败 ($healthy_containers/$expected_services)" "warn"
                ((retry_count++))
                sleep 3
            fi
        else
            debug_log "Compose启动命令失败"
            ((retry_count++))
            sleep 2
        fi
    done
    
    return 1
}
repair_compose_project() {
    local compose_file="$1"
    
    log "修复项目容器..." "info"
    
    # 停止所有容器
    $DETECTED_COMPOSE_CMD -f "$compose_file" down --remove-orphans 2>/dev/null || true
    
    # 清理悬挂的容器和网络
    docker container prune -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    
    # 重新启动
    return start_compose_project "$compose_file"
}
# --- Docker系统维护 ---
perform_docker_maintenance() {
    log "执行Docker系统维护..." "info"
    
    # 检查Docker磁盘使用情况
    local docker_size
    docker_size=$(docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}" 2>/dev/null | \
                 awk '/Total/ {print $3}' | head -1 || echo "未知")
    
    log "Docker磁盘使用: $docker_size" "info"
    
    # 清理建议
    local cleanup_needed=false
    
    # 检查悬挂镜像
    local dangling_images=$(docker images -f "dangling=true" -q | wc -l)
    if [ "$dangling_images" -gt 0 ]; then
        log "发现 $dangling_images 个悬挂镜像" "warn"
        cleanup_needed=true
    fi
    
    # 检查停止的容器
    local stopped_containers=$(docker ps -a --filter "status=exited" -q | wc -l)
    if [ "$stopped_containers" -gt 0 ]; then
        log "发现 $stopped_containers 个已停止容器" "warn"
        cleanup_needed=true
    fi
    
    # 检查未使用的网络
    local unused_networks=$(docker network ls --filter "scope=local" --format "{{.Name}}" | \
                           grep -v -E "^(bridge|host|none)$" | wc -l)
    if [ "$unused_networks" -gt 0 ]; then
        log "发现 $unused_networks 个本地网络" "info"
    fi
    
    # 执行清理 (如果需要)
    if [ "$cleanup_needed" = "true" ]; then
        if [ "${AUTO_CLEANUP:-false}" = "true" ] || [ "${BATCH_MODE:-false}" = "true" ]; then
            log "自动执行Docker清理..." "info"
            docker_cleanup
        elif [ "${BATCH_MODE:-false}" != "true" ]; then
            read -p "是否执行Docker清理? (y/N): " do_cleanup
            if [[ "$do_cleanup" =~ ^[Yy]$ ]]; then
                docker_cleanup
            fi
        fi
    else
        log "Docker系统状态良好，无需清理" "info"
    fi
}
docker_cleanup() {
    log "清理Docker系统..." "info"
    
    # 清理停止的容器
    local removed_containers=$(docker container prune -f 2>/dev/null | grep "Total reclaimed space" | awk '{print $(NF-1), $NF}' || echo "0 B")
    log "清理容器: $removed_containers" "info"
    
    # 清理悬挂镜像
    local removed_images=$(docker image prune -f 2>/dev/null | grep "Total reclaimed space" | awk '{print $(NF-1), $NF}' || echo "0 B")
    log "清理镜像: $removed_images" "info"
    
    # 清理未使用网络
    local removed_networks=$(docker network prune -f 2>/dev/null | grep "Total reclaimed space" | awk '{print $(NF-1), $NF}' || echo "0 B")
    log "清理网络: $removed_networks" "info"
    
    # 清理构建缓存 (谨慎)
    if [ "${AGGRESSIVE_CLEANUP:-false}" = "true" ]; then
        log "清理构建缓存..." "info"
        docker builder prune -f >/dev/null 2>&1 || true
    fi
    
    log "Docker清理完成" "success"
}
# --- 生成Docker状态报告 ---
generate_docker_report() {
    log "生成Docker状态报告..." "info"
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    log "🐳 Docker 系统状态报告" "success"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
    
    # 基本信息
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | tr -d ',' || echo "未知")
        local compose_version=""
        
        if [ -n "${DETECTED_COMPOSE_CMD:-}" ]; then
            if [[ "$DETECTED_COMPOSE_CMD" == "docker compose" ]]; then
                compose_version="V2 ($(docker compose version --short 2>/dev/null || echo "未知"))"
            else
                compose_version="V1 ($(docker-compose --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知"))"
            fi
        else
            compose_version="未安装"
        fi
        
        log "📋 版本信息:" "info"
        log "  • Docker Engine: $docker_version" "info"
        log "  • Docker Compose: $compose_version" "info"
        
        # 运行状态
        local running_containers=$(docker ps -q 2>/dev/null | wc -l || echo 0)
        local total_containers=$(docker ps -a -q 2>/dev/null | wc -l || echo 0)
        local total_images=$(docker images -q 2>/dev/null | wc -l || echo 0)
        local total_volumes=$(docker volume ls -q 2>/dev/null | wc -l || echo 0)
        local total_networks=$(docker network ls --format "{{.Name}}" 2>/dev/null | wc -l || echo 0)
        
        log "📊 资源统计:" "info"
        log "  • 运行容器: $running_containers" "info"
        log "  • 总容器数: $total_containers" "info"
        log "  • 镜像数量: $total_images" "info"
        log "  • 数据卷数: $total_volumes" "info"
        log "  • 网络数量: $total_networks" "info"
        
        # 存储使用
        if docker system df >/dev/null 2>&1; then
            log "💾 存储使用:" "info"
            docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}" 2>/dev/null | \
            while IFS=$'\t' read -r type count size reclaimable; do
                if [ "$type" != "TYPE" ]; then
                    log "  • $type: $count 个, $size (可回收: $reclaimable)" "info"
                fi
            done
        fi
        
        # 服务状态
        if systemctl is-active docker.service >/dev/null 2>&1; then
            log "⚙️  服务状态: 运行中" "success"
        else
            log "⚙️  服务状态: 未运行" "error"
        fi
        
        # NextTrace状态
        if command -v nexttrace &>/dev/null; then
            local nt_version=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' || echo "未知")
            log "🔍 NextTrace: 已安装 ($nt_version)" "success"
        else
            log "🔍 NextTrace: 未安装" "warn"
        fi
        
    else
        log "❌ Docker 未安装" "error"
    fi
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "info"
}
# --- 主函数 ---
main() {
    log "开始配置Docker容器化平台..." "info"
    
    # 1. 系统要求检查
    if ! check_system_requirements; then
        log "系统要求检查失败" "error"
        exit 1
    fi
    
    # 2. 备份现有配置
    backup_existing_config
    
    # 3. 安装Docker
    if ! install_docker_safely; then
        log "Docker安装失败" "error"
        exit 1
    fi
    
    # 4. 配置Docker服务
    if ! configure_docker_service; then
        log "Docker服务配置失败" "error"
        exit 1
    fi
    
    # 5. 优化Docker配置
    if ! optimize_docker_configuration; then
        log "Docker配置优化失败，但继续执行" "warn"
    fi
    
    # 6. 配置镜像加速
    configure_registry_mirrors
    
    # 7. 确保Docker Compose可用
    ensure_docker_compose
    
    # 8. 安装NextTrace
    install_nexttrace_enhanced
    
    # 9. 发现和管理容器
    discover_and_manage_containers
    
    # 10. 系统维护
    perform_docker_maintenance
    
    # 11. 生成状态报告
    generate_docker_report
    
    log "🎉 Docker容器化平台配置完成!" "success"
    
    # 使用提示
    if [ "${BATCH_MODE:-false}" != "true" ]; then
        log "💡 使用提示:" "info"
        log "  • 查看容器: docker ps" "info"
        log "  • 查看日志: docker logs <容器名>" "info"
        log "  • 进入容器: docker exec -it <容器名> /bin/bash" "info"
        log "  • 系统清理: docker system prune" "info"
        if command -v nexttrace &>/dev/null; then
            log "  • 网络追踪: nexttrace <目标IP>" "info"
        fi
    fi
    
    exit 0
}
# 执行主函数
main "$@"
