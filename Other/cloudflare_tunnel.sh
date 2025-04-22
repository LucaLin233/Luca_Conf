#!/bin/bash
# Cloudflared Tunnel 二进制版本安装与卸载脚本
# 功能：根据用户参数安装或卸载 Cloudflared 二进制版本及其相关服务和配置。

set -e # 任何命令失败时立即退出脚本执行

# --- 辅助函数: 检查命令是否存在 ---
command_exists() {
    command -v "$@" >/dev/null 2>&1
}

# --- 安装 Cloudflared 函数 ---
install_cloudflared() {
    echo "--- 开始安装 Cloudflared ---"

    # 检测系统架构并确定下载 URL
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7l|armv6l)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            echo "错误: 不支持的架构: $ARCH" >&2
            exit 1
            ;;
    esac

    TARGET_BIN_PATH="/usr/local/bin/cloudflared"

    # 检查 Cloudflared 二进制文件是否已存在，提示覆盖。如果覆盖，先尝试停止现有服务。
    if [ -f "$TARGET_BIN_PATH" ]; then
        echo "提示: Cloudflared 二进制文件已存在于 $TARGET_BIN_PATH。"
        read -p "是否覆盖安装? (y/N): " OVERWRITE_CONFIRM
        if [[ "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
            echo "继续覆盖安装..."

            # 尝试停止现有服务，以便覆盖正在执行的二进制文件
            echo "正在尝试停止现有的 cloudflared 服务 (如果正在运行)..."
            if systemctl is-active --quiet cloudflared.service; then
                if sudo systemctl stop cloudflared.service; then
                   echo "现有 cloudflared 服务已停止。"
                else
                   echo "错误: 停止 cloudflared.service 失败。可能导致无法覆盖二进制文件。请手动停止服务后重试。" >&2
                   exit 1 # 如果停止失败，退出安装
                fi
            else
                echo "未检测到正在运行的 cloudflared.service。"
            fi

        else
            echo "取消安装。"
            exit 0
        fi
    fi

    # 检查 curl 命令是否存在
    if ! command_exists curl; then
        echo "错误: 'curl' 命令未找到。请先安装 curl。" >&2
        exit 1
    fi

    # 下载 Cloudflared 二进制文件到目标路径
    echo "正在下载 cloudflared 二进制文件从 $CLOUDFLARED_URL 到 $TARGET_BIN_PATH..."
    # 注意: 如果上面停止服务失败，这里可能会因为文件被占用而报错 (Text file busy)
    if ! sudo curl -L "$CLOUDFLARED_URL" -o "$TARGET_BIN_PATH"; then
        echo "错误: 下载 cloudflared 失败。" >&2
        echo "可能是因为旧的服务还在运行并占用文件，或者网络问题。" >&2
        exit 1
    fi

    # 设置二进制文件执行权限
    echo "设置执行权限..."
    if ! sudo chmod +x "$TARGET_BIN_PATH"; then
        echo "错误: 设置 cloudflared 执行权限失败。" >&2
        sudo rm -f "$TARGET_BIN_PATH" # 清理文件
        exit 1
    fi

    # 验证安装 - 检查文件是否存在且可执行，并获取版本
    echo "验证安装:"
    if [ -x "$TARGET_BIN_PATH" ]; then # 检查文件是否存在且可执行
        "$TARGET_BIN_PATH" version # 直接执行目标路径的文件以验证
    else
        echo "警告: 安装的 cloudflared 二进制文件 $TARGET_BIN_PATH 不可执行或不存在。" >&2
        sudo rm -f "$TARGET_BIN_PATH" # 清理文件
        exit 1
    fi

    # --- 新增: 检查并尝试卸载旧的服务配置 ---
    # 在提示输入令牌和安装新服务之前执行此步骤
    SERVICE_FILE="/etc/systemd/system/cloudflared.service"
    if [ -f "$SERVICE_FILE" ]; then
        echo "检测到现有的 systemd 服务文件: $SERVICE_FILE。正在尝试使用新的二进制文件卸载旧的服务配置..."
        # 使用新下载的二进制尝试卸载旧服务配置
        if "$TARGET_BIN_PATH" service uninstall --help 2>/dev/null | grep -q "uninstall"; then
             if sudo "$TARGET_BIN_PATH" service uninstall; then
                echo "旧的 cloudflared 服务配置已成功卸载。"
             else
                echo "错误: 使用新的二进制文件卸载旧的服务配置失败。" >&2
                echo "请手动删除服务文件 $SERVICE_FILE 后重试安装。" >&2
                exit 1 # 如果卸载旧服务失败，则退出
             fi
        else
            echo "警告: 新的二进制文件 ($TARGET_BIN_PATH) 不支持 'service uninstall' 命令，或文件不可执行。请手动删除服务文件 $SERVICE_FILE 后重试安装。" >&2
            exit 1 # 如果新二进制不支持卸载功能，也需退出
        fi
    else
        echo "未检测到旧的 cloudflared systemd 服务文件，跳过卸载旧配置。"
    fi
    # --- 新增: 卸载旧服务配置结束 ---

    # 提示用户输入 Tunnel 令牌 - 放在卸载旧服务之后，安装新服务之前
    echo "请从 Cloudflare Zero Trust 后台复制令牌并粘贴:"
    read -p "令牌: " TOKEN

    if [ -z "$TOKEN" ]; then
        echo "错误: 未输入令牌。服务无法安装。" >&2
        # 由于服务安装必须有令牌且我们刚刚可能停止了旧服务/卸载了旧配置，这里必须退出。
        exit 1
    fi

    # 使用新下载的二进制安装 systemd 服务
    # 在上一步已经确保服务文件不存在或已被卸载，现在可以安全安装新服务了
    echo "正在安装 cloudflared 服务到 $SERVICE_FILE..."
    if sudo "$TARGET_BIN_PATH" service install "$TOKEN"; then
        echo "cloudflared 服务已成功安装。"
    else
        echo "错误: cloudflared 服务安装失败。" >&2
        echo "请尝试手动运行: sudo $TARGET_BIN_PATH service install $TOKEN" >&2
        # 如果安装失败（不应该发生，除非令牌问题、文件权限或其他systemd问题），退出
        exit 1
    fi

    # 启用服务文件的自动更新选项 (修改 service 文件)
    # service install 通常创建的主要服务文件在 /etc/systemd/system/cloudflared.service
    if [ -f "$SERVICE_FILE" ]; then
        echo "正在尝试修改服务文件 '$SERVICE_FILE' 启用自动更新..."
        # 检查是否存在 --no-autoupdate 再尝试删除
        if grep -q -- "--no-autoupdate" "$SERVICE_FILE"; then # 不需要 sudo grep，因为后面 sed 用 sudo 改
             sudo sed -i 's/--no-autoupdate//g' "$SERVICE_FILE"
             echo "自动更新已启用。"
        else
             echo "--no-autoupdate 选项未在服务文件中找到，可能自动更新已启用或服务文件结构不同。"
        fi
    else
        echo "警告: systemd 服务文件 ($SERVICE_FILE) 未找到，无法启用自动更新。" >&2
        echo "请手动编辑服务文件以启用自动更新（如果需要）。" >&2
    fi

    # 重新加载 systemd 配置，启用并启动新安装的服务
    echo "重新加载 systemd 配置并启动 cloudflared 服务..."
    sudo systemctl daemon-reload || echo "警告: systemctl daemon-reload 失败。" >&2
    # 确保开机自启，service install_逻辑上会 enable，这里再 ensure 一下
    sudo systemctl enable cloudflared || echo "警告: systemctl enable cloudflared 失败，服务可能不会开机自启。" >&2
    sudo systemctl start cloudflared || echo "警告: cloudflared 服务启动失败。请检查 journalctl -u cloudflared.service 日志。" >&2

    # 显示服务状态
    echo "cloudflared 服务状态:"
    systemctl status cloudflared || echo "警告: 获取 cloudflared 服务状态失败。" >&2

    echo "--- Cloudflared 安装完成！---"
    echo "cloudflared 二进制文件已安装到 $TARGET_BIN_PATH"
    echo "新服务已配置并尝试启动。"
    echo "下次系统启动时服务将尝试自动运行和更新。"
}

# --- 卸载 Cloudflared 函数 ---
uninstall_cloudflared() {
    echo "--- 开始彻底清除 Cloudflared ---"
    echo "警告: 此操作将尝试删除所有 cloudflared 二进制文件、相关的 systemd 服务和配置文件。"
    echo "特别是配置文件目录 (/etc/cloudflared, /var/lib/cloudflared, ~/.cloudflared 等) 将被移除，"
    echo "这些目录可能包含您与此 Tunnel 无关的其他 Cloudflare 配置。请谨慎操作，并在需要时提前备份您的配置。"
    read -p "确定要继续彻底清除吗? (y/N): " CONFIRM_UNINSTALL
    if [[ "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        echo "继续清除..."
    else
        echo "取消清除并退出。"
        exit 0
    fi
    echo "" # 加一个空行分隔

    # 尝试使用 cloudflared 自带的卸载命令 'cloudflared service uninstall'
    # 优先使用安装时的主要路径，如果不存在再尝试 PATH 中的命令
    TARGET_BIN_PATH="/usr/local/bin/cloudflared"
    CLOUDFLARED_CMD=""
    if [ -x "$TARGET_BIN_PATH" ]; then
        CLOUDFLARED_CMD="$TARGET_BIN_PATH"
    elif command_exists cloudflared; then
        CLOUDFLARED_CMD="$(which cloudflared)"
        echo "警告: 主要安装路径 $TARGET_BIN_PATH 未找到，将尝试使用 PATH 中的 cloudflared 命令: $CLOUDFLARED_CMD" >&2
    else
        echo "cloudflared 二进制文件未找到，跳过 'service uninstall' 尝试。" >&2
    fi

    if [ -n "$CLOUDFLARED_CMD" ]; then
        echo "尝试使用 cloudflared 自带卸载命令 '$CLOUDFLARED_CMD service uninstall'..."
         if "$CLOUDFLARED_CMD" service uninstall --help 2>/dev/null | grep -q "uninstall"; then
            sudo "$CLOUDFLARED_CMD" service uninstall || echo "警告: '$CLOUDFLARED_CMD service uninstall' 失败。可能服务不是由此命令安装的，或仍在运行。" >&2
        else
            echo "警告: '$CLOUDFLARED_CMD service uninstall' 命令不可用。" >&2
        fi
    fi

    # 停止并禁用已知的 systemd 服务 (作为额外的清理步骤)
    echo "停止并禁用已知的 cloudflared systemd 服务..."
    KNOWN_SERVICES="cloudflared.service cloudflared-update.service"
    for service in $KNOWN_SERVICES; do
        # 检查服务单元是否存在于系统中 (Loaded状态)
        if systemctl list-units --full --no-pager --all | grep -q "^${service}"; then # 使用 ^锚点确保匹配服务名称开头
             echo "正在停止和禁用 $service ..."
            sudo systemctl stop "$service" >/dev/null 2>&1 || true # 停止失败则忽略
            sudo systemctl disable "$service" >/dev/null 2>&1 || true # 禁用失败则忽略
             echo "$service 已停止并禁用 (如果存在且运行)。"
        else
            echo "未找到服务单元: $service"
        fi
    done

    # 删除已知的 cloudflared systemd 服务文件和软链接
    echo "删除已知的 cloudflared systemd 服务文件和软链接..."
    SERVICE_FILES_TO_DELETE=(
        "/etc/systemd/system/cloudflared.service"
        "/etc/systemd/system/cloudflared-update.service"
        "/etc/systemd/system/multi-user.target.wants/cloudflared.service"
        "/etc/systemd/system/multi-user.target.wants/cloudflared-update.service"
        # 根据需要添加其他可能的位置
    )

    for service_file_path in "${SERVICE_FILES_TO_DELETE[@]}"; do
        if [ -f "$service_file_path" ] || [ -L "$service_file_path" ]; then # 检查文件或软链接
            echo "删除服务文件/链接: $service_file_path"
            sudo rm -f "$service_file_path" || true # 删除失败则忽略
        fi
    done

    # 重新加载 systemd 配置
    echo "重新加载 systemd 配置并重置失败的服务..."
    sudo systemctl daemon-reload || echo "警告: systemctl daemon-reload 失败。" >&2
    sudo systemctl reset-failed || echo "警告: systemctl reset-failed 失败。" >&2

    # 删除配置文件和证书目录 (包含用户家目录)
    echo "删除配置文件和证书目录 (/etc/cloudflared, /var/lib/cloudflared, ~/.cloudflared 等)..."
     echo "注意: 这些目录可能包含其他 Cloudflare 配置。请确保您已备份重要数据。" # 重申警告

    CONFIG_DIRS_TO_DELETE=(
        "/etc/cloudflared"
        "/var/lib/cloudflared"
        "/root/.cloudflared" # root 用户
        "$HOME/.cloudflared" # 当前运行脚本的用户
    )

    for config_dir in "${CONFIG_DIRS_TO_DELETE[@]}"; do
        if [ -d "$config_dir" ]; then
             echo "删除目录: $config_dir"
             sudo rm -rf "$config_dir" || true # 删除失败则忽略
        fi
    done

    # 尝试删除其他用户家目录下的 .cloudflared 目录
    echo "尝试删除其他用户家目录下的 .cloudflared 目录 (/home/*/.cloudflared)..."
    find /home -maxdepth 1 -minddepth 1 -type d -print0 | while IFS= read -r -d $'\0' user_home; do
        if [ -d "$user_home/.cloudflared" ]; then
            echo "删除目录: $user_home/.cloudflared"
            sudo rm -rf "$user_home/.cloudflared" || true # 删除失败则忽略
        fi
    done

    # 删除 cloudflared 二进制文件
    echo "删除 cloudflared 二进制文件..."
    BINARIES_TO_DELETE=(
        "/usr/local/bin/cloudflared" # 安装脚本主要位置
        "/usr/bin/cloudflared"
        "/usr/sbin/cloudflared"
        "/bin/cloudflared"
    )

    for bin_path in "${BINARIES_TO_DELETE[@]}"; do
        if [ -f "$bin_path" ] || [ -L "$bin_path" ]; then
            echo "删除二进制文件/链接: $bin_path"
             sudo rm -f "$bin_path" || true # 删除失败则忽略
        fi
    done

    echo "--- Cloudflared 清除完成！---"

    # 最终验证
    echo "进行最终验证..."
    # 检查二进制文件是否还在
    if [ -x "/usr/local/bin/cloudflared" ] || command_exists cloudflared; then
        echo "警告：Cloudflared 二进制文件可能仍然存在。" >&2
         which cloudflared 2>/dev/null # 尝试显示路径
    else
        echo "验证：Cloudflared 二进制文件已成功移除或不在 PATH 中。"
    fi

    # 检查相关服务是否还在 systemd 中
    if systemctl list-units --full --no-pager --all | grep -q cloudflared.service; then # 检查服务单元是否存在
        echo "警告：仍有 Cloudflared 相关 systemd 服务单元存在。" >&2
        systemctl list-units --full --no-pager --all | grep cloudflared.service >&2 # 只显示服务单元行
    else
        echo "验证：所有 Cloudflared 服务单元已成功移除。"
    fi
}

# --- 显示用法函数 ---
usage() {
    echo "用法: sudo $(basename "$0") [install|uninstall]"
    echo "  install: 下载并安装最新版本 cloudflared 二进制文件，并安装为 systemd 服务。"
    echo "  uninstall: 尝试停止、禁用并移除 cloudflared 二进制文件、systemd 服务和配置文件。"
    exit 1
}

# --- 主脚本执行逻辑 ---

# 检查是否以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 sudo 运行此脚本。" >&2
    exit 1
fi

# 解析命令行参数，调用相应函数
case "$1" in
    install)
        install_cloudflared
        ;;
    uninstall)
        uninstall_cloudflared
        ;;
    *)
        usage # 参数错误或缺失时显示用法
        ;;
esac
