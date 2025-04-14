#!/usr/bin/env fish

# =====================================================
# Fish Shell增强配置脚本 - 二次连接阶段
# 前提：系统已完成基础配置，SSH已重连，当前使用fish shell
# =====================================================

# 增强的日志系统
function log
    set -l type "info"
    set -l message $argv[1]
    
    if test (count $argv) -gt 1
        set type $argv[2]
    end
    
    switch $type
        case "info"
            set_color -o cyan
            echo -n "● "
        case "success"
            set_color -o green
            echo -n "✓ "
        case "warning"
            set_color -o yellow
            echo -n "⚠ "
        case "error"
            set_color -o red
            echo -n "✗ "
        case "title"
            set_color -o magenta
            echo -n "➤ "
    end
    
    if test "$type" = "title"
        set_color -o magenta
    else
        set_color normal
    end
    
    echo $message
    set_color normal
end

# 步骤管理
function step_start
    echo
    log "步骤$argv[1]: $argv[2]" "title"
    echo "―――――――――――――――――――――――――――――――――"
end

function step_end
    log "步骤$argv[1]完成: $argv[2]" "success"
    echo
end

# 错误处理函数
function handle_error
    log "$argv" "error"
    read -l -P "是否继续执行? (y/n): " continue_exec
    if test "$continue_exec" != "y"
        log "操作已中止" "error"
        exit 1
    end
end

# 命令执行封装
function run_cmd
    eval $argv
    if test $status -ne 0
        handle_error "命令失败: $argv"
        return 1
    end
    return 0
end

# 安全地检测程序是否已安装
function is_installed
    if command -v $argv[1] >/dev/null 2>&1
        return 0
    else
        return 1
    end
end

# 检查配置文件中是否包含特定内容
function config_contains
    if test -e $argv[1]
        if grep -q "$argv[2]" $argv[1] 2>/dev/null
            return 0
        end
    end
    return 1
end

# 安全地添加到配置文件
function append_to_config
    set -l file $argv[1]
    set -l content $argv[2]
    
    # 确保目录存在
    mkdir -p (dirname $file)
    
    if not config_contains $file "$content"
        echo $content >> $file
        log "已添加配置: $content" "success"
        return 0
    else
        log "配置已存在，跳过" "info"
        return 1
    end
end

# 简短环境验证
function verify_environment
    # 检查是否为fish shell
    if not echo $SHELL | grep -q "fish"
        log "警告: 可能未正确切换到fish shell" "warning"
    else
        log "当前环境: Fish Shell" "success"
    end
    
    # 确保基本命令可用
    if not is_installed curl
        log "错误: 缺少curl，部分功能可能无法正常工作" "error"
        read -l -P "是否继续? (y/n): " continue_exec
        if test "$continue_exec" != "y"
            exit 1
        end
    end
end

# 步骤1: 安装fisher和插件
function setup_fisher
    step_start 1 "安装Fisher包管理器及插件"
    
    if not functions -q fisher
        log "安装Fisher包管理器..." "info"
        if not curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
            handle_error "无法下载Fisher"
        else
            fisher install jorgebucaran/fisher
            log "Fisher安装成功" "success"
        end
    else
        log "Fisher已安装，跳过安装步骤" "success"
    end
    
    set -l required_plugins jhillyerd/plugin-git jorgebucaran/autopair.fish jethrokuan/z edc/bass patrickf1/fzf.fish
    set -l installed_plugins (fisher list ^/dev/null | string collect)
    
    for plugin in $required_plugins
        set -l plugin_name (string split "/" $plugin)[2]
        if not echo $installed_plugins | grep -q $plugin
            log "安装插件: $plugin_name" "info"
            if fisher install $plugin
                log "插件 $plugin_name 安装成功" "success"
            else
                handle_error "安装插件 $plugin_name 失败"
            end
        else
            log "插件已安装: $plugin_name" "success"
        end
    end
    
    step_end 1 "Fisher和插件安装完成"
end

# 步骤2: 安装starship
function setup_starship
    step_start 2 "安装Starship提示符"
    
    if not is_installed starship
        log "安装Starship提示符..." "info"
        if curl -sS https://starship.rs/install.sh | sh -s -- -y
            log "Starship安装成功" "success"
        else
            handle_error "安装Starship失败"
        end
    else
        log "Starship已安装，跳过安装步骤" "success"
    end
    
    set -l config_file ~/.config/fish/config.fish
    
    # 备份配置文件
    if test -e $config_file
        set -l backup_file "$config_file.bak.$(date +%Y%m%d%H%M%S)"
        if cp $config_file $backup_file 2>/dev/null
            log "已备份fish配置到 $backup_file" "success"
        else
            log "无法备份配置文件，但将继续" "warning"
        end
    else
        log "创建新的fish配置文件" "info"
    end
    
    # 添加Starship初始化
    if append_to_config $config_file 'starship init fish | source'
        log "已添加Starship初始化到配置" "success"
    end
    
    step_end 2 "Starship设置完成"
end

# 步骤3: 设置mise和Python
function setup_mise_python
    step_start 3 "设置Mise版本管理器及Python"
    
    set -l mise_path $HOME/.local/bin/mise
    set -l config_file ~/.config/fish/config.fish
    
    # 确保.local/bin在PATH中
    if not contains $HOME/.local/bin $PATH
        set -gx PATH $HOME/.local/bin $PATH
        log "已添加 ~/.local/bin 到PATH" "success"
    end
    
    if not test -e $mise_path
        log "安装Mise版本管理器..." "info"
        if curl https://mise.run | sh
            log "Mise安装成功" "success"
            # 确保mise命令立即可用
            eval ($mise_path activate fish) ^/dev/null
        else
            handle_error "安装Mise失败"
        end
    else
        log "Mise已安装，跳过安装步骤" "success"
        # 激活mise
        eval ($mise_path activate fish) ^/dev/null
    end
    
    # 添加到配置
    if append_to_config $config_file "$mise_path activate fish | source"
        log "已添加Mise初始化到配置" "success"
    end
    
    # 设置Python
    if test -e $mise_path
        if not $mise_path list python 2>/dev/null | grep -q "3.10"
            log "通过Mise安装Python 3.10..." "info"
            if $mise_path use -g python@3.10
                log "Python 3.10设置成功" "success" 
            else
                handle_error "设置Python 3.10失败"
            end
        else
            log "Python 3.10已配置，跳过" "success"
        end
    end
    
    step_end 3 "Mise和Python设置完成"
end

# 系统信息汇总
function show_system_summary
    step_start 4 "配置汇总"
    
    log "╔═════════════════════════════════╗" "title"
    log "║      Fish Shell 增强配置        ║" "title"
    log "╚═════════════════════════════════╝" "title"
    
    log "当前Shell: $SHELL" "info"
    log "Fish版本: "(fish --version | string split ' ')[3] "info"
    
    # Fisher插件
    set -l plugins_count (fisher list ^/dev/null | wc -l)
    if test $plugins_count -gt 0
        log "Fisher插件: $plugins_count 个已安装" "success"
    else
        log "Fisher插件: 未安装" "warning"
    end
    
    # Starship
    if is_installed starship
        set -l version (starship --version 2>/dev/null | string split ' ')[1]
        log "Starship: $version" "success"
    else
        log "Starship: 未安装" "warning"
    end
    
    # Mise和Python
    set -l mise_path $HOME/.local/bin/mise
    if test -e $mise_path
        set -l version ($mise_path --version 2>/dev/null | string split ' ')[2]
        log "Mise: $version" "success"
        
        if $mise_path list | grep -q python
            set -l py_version ($mise_path which python | xargs -I{} {} --version 2>&1 | cut -d' ' -f2)
            log "Python (mise): $py_version" "success"
        else
            log "Python: 未通过mise配置" "warning"
        end
    else
        log "Mise: 未安装" "warning"
    end
    
    # 配置文件
    set -l config_file ~/.config/fish/config.fish
    if test -e $config_file
        log "配置文件: $config_file" "success"
    else
        log "配置文件: 未找到" "error"
    end
    
    log "──────────────────────────────────" "title"
    log "配置完成时间: "(date '+%Y-%m-%d %H:%M:%S') "info"
    
    step_end 4 "配置汇总完成"
end

# 步骤5: 提供清理欢迎信息提示 (不再自动执行)
function suggest_cleanup
    step_start 5 "后续步骤建议"
    
    log "如要清理系统欢迎信息，可执行以下命令:" "info"
    log "  echo \"\" | sudo tee /etc/motd /etc/issue /etc/issue.net > /dev/null" "info"
    
    log "如需立即应用所有配置，请执行:" "info"
    log "  source ~/.config/fish/config.fish" "info"
    
    log "要恢复到默认提示符 (禁用starship):" "info"
    log "  函数 fish_prompt; 函数 fish_right_prompt" "info"
    
    set -l config_file ~/.config/fish/config.fish
    set -l latest_backup (ls -t $config_file.bak* 2>/dev/null | head -n1)
    if test -n "$latest_backup"
        log "如需恢复之前的配置:" "info"
        log "  cp $latest_backup $config_file" "info"
    end
    
    step_end 5 "建议提供完成"
end

# 主函数
function main
    log "Fish Shell 增强配置" "title"
    log "此脚本将安装和配置Fisher、常用插件、Starship和Mise" "info"
    echo
    
    # 简单验证环境
    verify_environment
    
    # 核心功能执行
    setup_fisher    # 安装Fisher和插件
    setup_starship  # 安装Starship
    setup_mise_python  # 安装Mise和Python
    show_system_summary # 显示配置汇总 
    suggest_cleanup  # 提供后续步骤建议
    
    log "✨ 所有配置已完成!" "title"
    log "重启终端或执行 'source ~/.config/fish/config.fish' 以应用更改" "info"
end

# 执行主程序
main
