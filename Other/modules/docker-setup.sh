#!/bin/bash
# Docker 容器化平台配置模块

log() {
    local color="\033[0;32m"
    case "$2" in
        "warn") color="\033[0;33m" ;;
        "error") color="\033[0;31m" ;;
        "info") color="\033[0;36m" ;;
    esac
    echo -e "${color}$1\033[0m"
}

CONTAINER_DIRS=(/root /root/proxy /root/vmagent)

# 安装 Docker
log "检查并安装 Docker..." "info"
if ! command -v docker &>/dev/null; then
    log "安装 Docker..." "info"
    curl -fsSL https://get.docker.com | sh
    if ! command -v docker &>/dev/null; then
        log "Docker 安装失败" "error"
        exit 1
    fi
    log "Docker 安装完成" "info"
else
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',' || echo "未知")
    log "Docker 已安装 (版本: $DOCKER_VERSION)" "info"
fi

# 启动 Docker 服务
if systemctl list-unit-files --type=service | grep -q "docker.service"; then
    systemctl enable --now docker.service
    log "Docker 服务已启动" "info"
fi

# 低内存环境优化
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
if [ "$MEM_TOTAL" -lt 1024 ]; then
    log "检测到低内存环境，优化 Docker 配置..." "info"
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json; then
        cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        systemctl restart docker
        log "Docker 日志配置已优化" "info"
    fi
fi

# 安装 NextTrace
log "检查并安装 NextTrace..." "info"
if ! command -v nexttrace &>/dev/null; then
    log "安装 NextTrace..." "info"
    curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh | bash
    if command -v nexttrace &>/dev/null; then
        log "NextTrace 安装完成" "info"
    else
        log "NextTrace 安装失败" "warn"
    fi
else
    NEXTTRACE_VERSION=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' || echo "未知")
    log "NextTrace 已安装 ($NEXTTRACE_VERSION)" "info"
fi

# 检查并启动 Docker Compose 容器
log "检查 Docker Compose 容器..." "info"

# 确定 Compose 命令
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
fi

if [ -z "$COMPOSE_CMD" ]; then
    log "未检测到 Docker Compose，跳过容器检查" "warn"
else
    log "使用 Docker Compose 命令: $COMPOSE_CMD" "info"
    
    TOTAL_CONTAINERS=0
    for dir in "${CONTAINER_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
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
            log "检查目录: $dir ($COMPOSE_FILE)" "info"
            cd "$dir"
            
            EXPECTED_SERVICES=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services 2>/dev/null | wc -l)
            RUNNING_CONTAINERS=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
            
            if [ "$RUNNING_CONTAINERS" -lt "$EXPECTED_SERVICES" ]; then
                log "启动容器 ($RUNNING_CONTAINERS/$EXPECTED_SERVICES 运行中)" "info"
                $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --force-recreate
                sleep 3
                NEW_RUNNING=$($COMPOSE_CMD -f "$COMPOSE_FILE" ps --filter status=running --quiet 2>/dev/null | wc -l)
                log "容器启动完成 ($NEW_RUNNING 个运行中)" "info"
                TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + NEW_RUNNING))
            else
                log "容器已在运行 ($RUNNING_CONTAINERS/$EXPECTED_SERVICES)" "info"
                TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + RUNNING_CONTAINERS))
            fi
            cd - >/dev/null
        fi
    done
    
    ACTUAL_TOTAL=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    log "容器状态汇总: 总运行容器 $ACTUAL_TOTAL 个" "info"
fi

log "Docker 配置完成" "info"
if command -v docker &>/dev/null; then
    RUNNING_CONTAINERS=$(docker ps -q | wc -l)
    log "当前运行容器数: $RUNNING_CONTAINERS" "info"
fi

exit 0
