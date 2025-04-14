#!/bin/bash
# 恢复系统内核调优设置的脚本

# 检查root权限
[ "$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

# 定义备份目录
BACKUP_DIR="/root/kernel_tuning_backup"

# 检查备份目录是否存在
if [ ! -d "$BACKUP_DIR" ]; then
    # 尝试查找旧版本的备份
    OLD_SYSCTL_BACKUP=$(ls -t /etc/sysctl.conf.backup_* 2>/dev/null | head -1)
    OLD_LIMITS_BACKUP=$(ls -t /etc/security/limits.conf.backup_* 2>/dev/null | head -1)
    
    if [ -n "$OLD_SYSCTL_BACKUP" ] || [ -n "$OLD_LIMITS_BACKUP" ]; then
        echo "找到旧版本备份文件，但备份目录不存在"
        echo "创建备份目录并迁移备份..."
        mkdir -p "$BACKUP_DIR"
        
        [ -n "$OLD_SYSCTL_BACKUP" ] && cp "$OLD_SYSCTL_BACKUP" "$BACKUP_DIR/"
        [ -n "$OLD_LIMITS_BACKUP" ] && cp "$OLD_LIMITS_BACKUP" "$BACKUP_DIR/"
        
        echo "备份文件已迁移到: $BACKUP_DIR"
    else
        echo "错误: 备份目录 $BACKUP_DIR 不存在且找不到旧版本备份"
        echo "请指定正确的备份目录或运行内核调优脚本创建备份"
        exit 1
    fi
fi

# 显示可用备份
echo "可用备份文件:"
ls -l "$BACKUP_DIR"/*.backup_* 2>/dev/null || { 
    echo "未找到任何备份文件"; 
    exit 1; 
}

# 询问用户是否继续
read -p "是否继续恢复 (y/n)? " answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "操作已取消"
    exit 0
fi

# 恢复文件的函数
restore_file() {
    local backup="$1"
    local target="$2"
    
    if [ -f "$backup" ]; then
        cp "$backup" "$target"
        echo "已恢复: $backup → $target"
        return 0
    else
        echo "警告: 备份文件 $backup 不存在"
        return 1
    fi
}

# 寻找最近的备份文件
SYSCTL_BACKUP=$(ls -t "$BACKUP_DIR"/sysctl.conf.backup_* 2>/dev/null | head -1)
LIMITS_BACKUP=$(ls -t "$BACKUP_DIR"/limits.conf.backup_* 2>/dev/null | head -1)
COMMON_SESSION_BACKUP=$(ls -t "$BACKUP_DIR"/common-session.backup_* 2>/dev/null | head -1)
LOGIN_BACKUP=$(ls -t "$BACKUP_DIR"/login.backup_* 2>/dev/null | head -1)

# 恢复系统配置文件
if [ -n "$SYSCTL_BACKUP" ]; then
    restore_file "$SYSCTL_BACKUP" "/etc/sysctl.conf"
    sysctl_restored=true
else
    # 尝试查找旧版本的备份
    OLD_SYSCTL_BACKUP=$(ls -t /etc/sysctl.conf.backup_* 2>/dev/null | head -1)
    if [ -n "$OLD_SYSCTL_BACKUP" ]; then
        restore_file "$OLD_SYSCTL_BACKUP" "/etc/sysctl.conf"
        sysctl_restored=true
    else
        echo "警告: 未找到 sysctl.conf 备份"
    fi
fi

if [ -n "$LIMITS_BACKUP" ]; then
    restore_file "$LIMITS_BACKUP" "/etc/security/limits.conf"
    limits_restored=true
else
    # 尝试查找旧版本的备份
    OLD_LIMITS_BACKUP=$(ls -t /etc/security/limits.conf.backup_* 2>/dev/null | head -1)
    if [ -n "$OLD_LIMITS_BACKUP" ]; then
        restore_file "$OLD_LIMITS_BACKUP" "/etc/security/limits.conf"
        limits_restored=true
    else
        echo "警告: 未找到 limits.conf 备份"
    fi
fi

if [ -n "$COMMON_SESSION_BACKUP" ]; then
    restore_file "$COMMON_SESSION_BACKUP" "/etc/pam.d/common-session"
fi

if [ -n "$LOGIN_BACKUP" ]; then
    restore_file "$LOGIN_BACKUP" "/etc/pam.d/login"
fi

# 恢复limits.d下的配置
for nproc_conf_bk in /etc/security/limits.d/*nproc.conf_bk; do
    if [ -f "$nproc_conf_bk" ]; then
        restored_name=$(echo "$nproc_conf_bk" | sed 's/_bk$//')
        mv "$nproc_conf_bk" "$restored_name"
        echo "已恢复: $nproc_conf_bk → $restored_name"
    fi
done

# 应用配置
if [ "$sysctl_restored" = true ]; then
    echo "正在应用恢复的系统参数..."
    sysctl -p
fi

# 完成信息
if [ "$sysctl_restored" = true ] || [ "$limits_restored" = true ]; then
    echo "系统配置恢复完成"
    echo "请重启系统以确保所有更改生效"
else
    echo "警告: 未能恢复任何配置文件"
fi
