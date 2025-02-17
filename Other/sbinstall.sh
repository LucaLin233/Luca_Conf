#!/bin/bash

# 定义变量
INSTALL_DIR="/root/proxy"
SRC_DIR="${INSTALL_DIR}/src"
BACKUP_DIR="${INSTALL_DIR}/backup"

# 错误处理函数
error_exit() {
    echo "错误: $1" >&2
    exit 1
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${ID}"
        OS_VERSION_ID="${VERSION_ID%%.*}"  # 只取主版本号
        echo "检测到操作系统: ${OS_NAME} ${VERSION_ID}"
        
        case "${OS_NAME}" in
            debian)
                if [ "${OS_VERSION_ID}" != "12" ]; then
                    echo "警告: 推荐使用 Debian 12，当前版本: ${VERSION_ID}"
                    read -p "是否继续？(y/n) " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        error_exit "安装已取消"
                    fi
                fi
                PKG_MANAGER="apt"
                PKG_UPDATE="apt update"
                PKG_INSTALL="apt install -y"
                CHRONY_SERVICE="chrony"
                ;;
            almalinux)
                if [ "${OS_VERSION_ID}" != "9" ]; then
                    echo "警告: 推荐使用 AlmaLinux 9，当前版本: ${VERSION_ID}"
                    read -p "是否继续？(y/n) " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        error_exit "安装已取消"
                    fi
                fi
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf check-update"
                PKG_INSTALL="dnf install -y"
                CHRONY_SERVICE="chronyd"
                ;;
            *)
                error_exit "不支持的操作系统: ${OS_NAME}"
                ;;
        esac
    else
        error_exit "无法检测操作系统类型"
    fi
}

# 安装必要的软件包
install_dependencies() {
    echo "检查并安装必要的软件包..."
    
    # 更新软件包列表
    echo "更新软件包列表..."
    ${PKG_UPDATE} >/dev/null 2>&1 || true
    
    # 要安装的软件包列表
    local debian_packages=("curl" "tar" "gzip" "jq" "chrony")
    local almalinux_packages=("curl" "tar" "gzip" "jq" "chrony" "policycoreutils-python-utils")
    
    # 根据系统选择包列表
    local packages=()
    case "${OS_NAME}" in
        debian)
            packages=("${debian_packages[@]}")
            ;;
        almalinux)
            packages=("${almalinux_packages[@]}")
            ;;
    esac
    
    # 检查并安装缺失的软件包
    local missing_packages=()
    for pkg in "${packages[@]}"; do
        if ! command -v "${pkg}" >/dev/null 2>&1; then
            case "${OS_NAME}" in
                debian)
                    if ! dpkg -l | grep -q "^ii  $pkg "; then
                        missing_packages+=("$pkg")
                    fi
                    ;;
                almalinux)
                    if ! rpm -q "$pkg" >/dev/null 2>&1; then
                        missing_packages+=("$pkg")
                    fi
                    ;;
            esac
        fi
    done
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "安装缺失的软件包: ${missing_packages[*]}"
        ${PKG_INSTALL} "${missing_packages[@]}" || error_exit "软件包安装失败"
        
        # 特别处理 chrony
        if [[ " ${missing_packages[*]} " =~ " chrony " ]]; then
            echo "配置并启动 chrony 服务..."
            systemctl enable "${CHRONY_SERVICE}" || error_exit "chrony 服务启用失败"
            systemctl start "${CHRONY_SERVICE}" || error_exit "chrony 服务启动失败"
            # 等待 chrony 同步时间
            echo "等待时间同步..."
            sleep 5
            chronyc tracking || error_exit "chrony 时间同步状态检查失败"
        fi
    else
        echo "所有必要的软件包已安装"
    fi
    
    echo "软件包安装完成"
}

# 配置 SELinux
configure_selinux() {
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        echo "检测到 SELinux 已启用，配置相关权限..."
        
        # 设置二进制文件的 SELinux 上下文
        chcon -t bin_t "${SRC_DIR}/sing-box" || error_exit "设置 SELinux 上下文失败"
        
        # 允许服务访问网络
        setsebool -P nis_enabled 1 || error_exit "设置 SELinux boolean 失败"
        
        # 如果需要，可以添加自定义 SELinux 策略
        # semanage port -a -t http_port_t -p tcp 443 || true
        
        echo "SELinux 配置完成"
    else
        echo "SELinux 未启用或不存在，跳过配置"
    fi
}

# 创建必要的目录
create_directories() {
    echo "检查必要的目录..."
    # 检查目录是否存在，不存在则创建
    for dir in "${SRC_DIR}" "${BACKUP_DIR}"; do
        if [ ! -d "$dir" ]; then
            echo "创建目录: $dir"
            mkdir -p "$dir" || error_exit "无法创建 $dir"
        else
            echo "目录已存在: $dir"
        fi
    done
    echo "目录检查完成"
}

# 验证配置文件和证书
verify_config() {
    echo "验证文件..."
    
    # 检查配置文件
    if [ ! -f "${INSTALL_DIR}/config.json" ]; then
        error_exit "配置文件不存在: ${INSTALL_DIR}/config.json"
    fi

    # 检查配置文件格式
    if ! jq empty "${INSTALL_DIR}/config.json" 2>/dev/null; then
        error_exit "配置文件 JSON 格式无效"
    fi
    
    # 检查证书文件
    local cert_files=("cert.crt" "private.key")
    local missing_files=()
    
    for file in "${cert_files[@]}"; do
        if [ ! -f "${INSTALL_DIR}/${file}" ]; then
            missing_files+=("${file}")
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo "警告: 以下证书文件不存在:"
        printf '%s\n' "${missing_files[@]}"
        read -p "是否继续安装？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error_exit "安装已取消"
        fi
    fi
    
    echo "文件验证完成"
}
# 检查并设置证书文件权限
check_cert_permissions() {
    echo "检查证书文件权限..."
    local cert_files=("cert.crt" "private.key")
    
    for file in "${cert_files[@]}"; do
        if [ -f "${INSTALL_DIR}/${file}" ]; then
            # 设置证书文件权限为 600 (仅所有者可读写)
            chmod 600 "${INSTALL_DIR}/${file}" || error_exit "无法设置 ${file} 的权限"
            echo "已设置 ${file} 的权限为 600"
        fi
    done
}

# 备份现有配置
backup_existing() {
    # 备份配置文件
    if [ -f "${INSTALL_DIR}/config.json" ]; then
        echo "发现现有配置文件，创建备份..."
        cp "${INSTALL_DIR}/config.json" "${BACKUP_DIR}/config.json.$(date +%Y%m%d_%H%M%S)" || error_exit "配置备份失败"
        echo "配置文件已备份"
    fi

    # 备份指定的证书文件
    local cert_files=("cert.crt" "private.key")
    for file in "${cert_files[@]}"; do
        if [ -f "${INSTALL_DIR}/${file}" ]; then
            echo "备份证书文件: ${file}"
            cp "${INSTALL_DIR}/${file}" "${BACKUP_DIR}/${file}.$(date +%Y%m%d_%H%M%S)" || error_exit "证书文件 ${file} 备份失败"
        fi
    done
}

# 下载最新版sing-box
download_singbox() {
    echo "获取最新版sing-box..."
    # 获取最新版本号
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d'"' -f4)
    
    if [ -z "${LATEST_VERSION}" ]; then
        error_exit "无法获取最新版本号"
    fi
    
    # 去掉版本号中的 'v' 前缀
    VERSION_NUMBER=${LATEST_VERSION#v}
    echo "最新版本: ${LATEST_VERSION}"
    
    # 下载并解压
    cd "${SRC_DIR}" || error_exit "无法进入 ${SRC_DIR}"
    
    # 检测系统架构
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            error_exit "不支持的系统架构: ${ARCH}"
            ;;
    esac
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION_NUMBER}-linux-${ARCH}.tar.gz"
    echo "下载地址: ${DOWNLOAD_URL}"
    
    # 下载文件，增加重试机制
    MAX_RETRIES=3
    RETRY_COUNT=0
    while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
        echo "尝试下载 (${RETRY_COUNT}/${MAX_RETRIES})..."
        if curl -L -o sing-box.tar.gz "${DOWNLOAD_URL}" --fail --silent --show-error --retry 3 --retry-delay 2; then
            # 验证下载的文件
            if [ -f sing-box.tar.gz ] && [ $(stat -c%s sing-box.tar.gz) -gt 1000 ]; then
                echo "下载完成，文件大小: $(stat -c%s sing-box.tar.gz) 字节"
                break
            else
                echo "下载的文件无效"
                rm -f sing-box.tar.gz
            fi
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
            echo "下载失败，等待 5 秒后重试..."
            sleep 5
        fi
    done

    if [ ! -f sing-box.tar.gz ]; then
        error_exit "下载失败，已达到最大重试次数"
    fi
    
    # 解压文件
    echo "解压文件..."
    if ! tar -xzf sing-box.tar.gz; then
        rm -f sing-box.tar.gz
        error_exit "解压失败"
    fi
    
    # 清理和移动文件
    rm sing-box.tar.gz
    mv sing-box-${VERSION_NUMBER}-linux-${ARCH}/sing-box . || error_exit "移动文件失败"
    rm -rf sing-box-${VERSION_NUMBER}-linux-${ARCH}
    
    # 验证安装
    if [ ! -f "${SRC_DIR}/sing-box" ]; then
        error_exit "sing-box 安装失败"
    fi
    
    # 设置执行权限
    chmod +x "${SRC_DIR}/sing-box"
    echo "sing-box 安装成功"
}

# 创建systemd服务
create_service() {
    echo "创建systemd服务..."
    cat > /etc/systemd/system/sing-box.service << EOL
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SRC_DIR}/sing-box run -c ${INSTALL_DIR}/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
Type=simple
User=root
Group=root
SELinuxContext=system_u:system_r:unconfined_service_t:s0

[Install]
WantedBy=multi-user.target
EOL

    if [ ! -f "/etc/systemd/system/sing-box.service" ]; then
        error_exit "服务文件创建失败"
    fi
    echo "服务文件创建成功"
}

# 启动服务并设置开机自启
enable_service() {
    echo "启动服务并设置开机自启..."
    systemctl daemon-reload || error_exit "daemon-reload 失败"
    systemctl enable sing-box || error_exit "服务启用失败"
    systemctl start sing-box || error_exit "服务启动失败"
    
    # 检查服务状态
    sleep 2
    if ! systemctl is-active sing-box >/dev/null 2>&1; then
        error_exit "服务启动失败，请检查日志: journalctl -u sing-box"
    fi
    
    echo "服务启动成功"
    systemctl status sing-box
}

# 清理函数
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "安装过程中出现错误（退出码：${exit_code}），正在清理..."
        # 只清理新创建的文件和目录
        rm -rf "${SRC_DIR}"
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi
}

# 主函数
main() {
    # 检查是否以root权限运行
    if [ "$EUID" -ne 0 ]; then 
        error_exit "请使用 sudo 运行此脚本"
    fi
    
    # 设置清理陷阱
    trap cleanup EXIT
    
    echo "开始安装 sing-box..."
    detect_os
    install_dependencies
    verify_config
    check_cert_permissions
    create_directories
    backup_existing
    download_singbox
    configure_selinux    # 添加这一行
    create_service
    enable_service
    echo "安装完成!"
}

# 执行主函数
main