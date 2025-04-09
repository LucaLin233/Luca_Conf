#!/bin/bash
# 恢复脚本

# 检查root权限
[ "$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

# 寻找最近的备份
SYSCTL_BACKUP=$(ls -t /etc/sysctl.conf.backup_* | head -1)
LIMITS_BACKUP=$(ls -t /etc/security/limits.conf.backup_* | head -1)

if [ -n "$SYSCTL_BACKUP" ] && [ -n "$LIMITS_BACKUP" ]; then
    cp "$SYSCTL_BACKUP" /etc/sysctl.conf
    cp "$LIMITS_BACKUP" /etc/security/limits.conf
    
    echo "已恢复配置文件："
    echo "- $SYSCTL_BACKUP → /etc/sysctl.conf"
    echo "- $LIMITS_BACKUP → /etc/security/limits.conf"
    
    sysctl -p
    echo "请重启系统以完成恢复"
else
    echo "未找到备份文件，无法自动恢复"
fi
