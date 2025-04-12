#!/usr/bin/env fish

# 彩色输出函数
function green
    echo -e "\033[32m$argv\033[0m"
end

function yellow
    echo -e "\033[33m$argv\033[0m"
end

function red
    echo -e "\033[31m$argv\033[0m"
end

# 错误处理函数
function check_error
    if test $status -ne 0
        red "错误: $argv 执行失败"
        exit 1
    end
end

# 命令执行封装
function run_cmd
    eval $argv
    check_error "$argv"
end

# 检查程序是否已安装
function is_installed
    command -v $argv[1] >/dev/null 2>&1
end

# 检查配置文件中是否包含特定内容
function config_contains
    grep -q "$argv[2]" $argv[1] 2>/dev/null
end

# 安全获取版本信息
function safe_version
    set cmd $argv[1]
    set args $argv[2..-1]
    if command -v $cmd >/dev/null 2>&1
        set output (eval "$cmd $args" 2>/dev/null; or echo "命令执行失败")
        echo $output
    else
        echo "未安装或未配置"
    end
end

# 获取当前用户
set current_user (whoami)

# 检查是否为root用户
if test "$current_user" != "root"
    red "此脚本需要以root用户运行"
    exit 1
end

# 步骤1: 安装fisher和插件
green "步骤1: 安装fisher和插件..."
if not functions -q fisher
    yellow "安装fisher包管理器..."
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
    fisher install jorgebucaran/fisher
    check_error "安装fisher"
else
    yellow "Fisher已安装，跳过安装步骤"
end

set required_plugins jhillyerd/plugin-git jorgebucaran/autopair.fish jethrokuan/z edc/bass patrickf1/fzf.fish
set installed_plugins (fisher list)
yellow "检查并安装所需fisher插件..."
for plugin in $required_plugins
    if not echo $installed_plugins | grep -q $plugin
        yellow "安装插件: $plugin"
        fisher install $plugin
        check_error "安装 $plugin"
    else
        yellow "插件已安装: $plugin"
    end
end
yellow "步骤1完成: Fisher和插件安装结束。"

# 步骤2: 安装starship
green "步骤2: 检查并安装starship..."
if not is_installed starship
    yellow "安装starship提示符..."
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    check_error "安装starship"
else
    yellow "Starship已安装，跳过安装步骤"
end

set config_file ~/.config/fish/config.fish
cp $config_file $config_file.bak 2>/dev/null; or yellow "备份配置文件失败，但继续"
if not config_contains $config_file "starship init"
    yellow "添加starship初始化到fish配置..."
    echo 'starship init fish | source' >> $config_file
    check_error "配置starship"
else
    yellow "Starship已在fish配置中初始化"
end
yellow "步骤2完成: Starship安装结束。"

# 步骤3: 检查并安装mise和Python
green "步骤3: 检查并安装mise和Python..."
set mise_path $HOME/.local/bin/mise
if not test -e $mise_path
    yellow "安装mise版本管理器..."
    curl https://mise.run | sh
    check_error "安装mise"
else
    yellow "Mise已安装，跳过安装步骤"
end

if not config_contains $config_file "mise activate"
    yellow "添加mise初始化到fish配置..."
    echo "$HOME/.local/bin/mise activate fish | source" >> $config_file
    check_error "配置mise"
else
    yellow "Mise已在fish配置中初始化"
end

if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end

if test -e $mise_path
    eval ($mise_path activate fish)
    if not $mise_path list python 2>/dev/null | grep -q "3.10"
        yellow "通过mise安装Python 3.10..."
        $mise_path use -g python@3.10
        check_error "安装Python 3.10"
    else
        yellow "Python 3.10已由mise管理，跳过安装"
    end
else
    red "警告: Mise未正确安装，跳过Python设置"
end
yellow "步骤3完成: Mise和Python安装结束。"

# 步骤4: 执行内核调优
green "步骤4: 执行内核调优..."
if is_installed sudo
    if test ! -e /tmp/.kernel_optimization_done
        yellow "应用内核调优设置..."
        bash -c "curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | bash"
        touch /tmp/.kernel_optimization_done  # 修正路径
    else
        yellow "内核已优化，跳过调优步骤"
    end
else
    red "警告: 无sudo权限，跳过内核调优。请手动执行或使用root权限运行此步骤。"
end
yellow "步骤4完成: 内核调优结束。"

# 步骤5: 系统信息汇总
green "步骤5: 系统信息汇总"
yellow "====== 部署完成，设置总结 ======="
yellow "Fish版本: "(fish --version)
yellow "Fisher插件: "(fisher list | tr '\n' ' ')
if is_installed starship
    yellow "Starship版本: "(starship --version 2>/dev/null || echo "已安装但无法获取版本")
else
    yellow "Starship版本: 未安装或未配置"
end
if test -e $mise_path  # 修正变量名称
    yellow "Mise版本: "($mise_path --version 2>/dev/null || echo "已安装但无法获取版本")
    if $mise_path which python > /dev/null 2>&1
        set python_cmd ($mise_path which python)
        yellow "Python版本: "($python_cmd --version 2>&1 || echo "已安装但无法获取版本")
    else
        yellow "Python版本: 未通过mise安装或配置"
    end
else
    yellow "Mise状态: 安装路径不存在，请检查安装"
    yellow "Python版本: 未通过mise配置"
end
yellow "配置文件: "$config_file
yellow "======================================"
yellow "步骤5完成: 总结信息已显示。"

# 步骤6: 清理不需要的欢迎信息
green "步骤6: 清理不需要的欢迎信息..."
echo "" | sudo tee /etc/motd /etc/issue /etc/issue.net > /dev/null
if test $status -eq 0
    yellow "欢迎信息已成功清空。"
else
    red "警告: 无法执行，需要正确权限。请手动检查。"
end
yellow "步骤6完成: 清理结束。"

yellow "\n所有步骤已成功完成！"
yellow "提示: 重新启动终端以应用所有更改，或执行 'source ~/.config/fish/config.fish'"
