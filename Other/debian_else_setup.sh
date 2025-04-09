#!/usr/bin/env fish

# 彩色输出函数
function green
    echo -e "\033[32m$argv\033[0m"
end

function red
    echo -e "\033[31m$argv\033[0m"
end

function yellow
    echo -e "\033[33m$argv\033[0m"
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

# 获取当前用户
set current_user (whoami)

# 步骤0: 显示欢迎信息
green "Fish环境增强部署开始..."
green "当前用户: $current_user"

# 步骤1: 安装fisher和插件
green "步骤1: 安装fisher和插件..."

# 检查fisher是否已安装
if not functions -q fisher
    yellow "安装fisher包管理器..."
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
    fisher install jorgebucaran/fisher
    check_error "安装fisher"
else
    green "Fisher已安装，跳过安装步骤"
end

# 安装fisher插件集
set required_plugins jhillyerd/plugin-git jorgebucaran/autopair.fish jethrokuan/z edc/bass patrickf1/fzf.fish
set installed_plugins (fisher list)

green "检查并安装所需fisher插件..."
for plugin in $required_plugins
    if not echo $installed_plugins | grep -q $plugin
        yellow "安装插件: $plugin"
        fisher install $plugin
        check_error "安装 $plugin"
    else
        green "插件已安装: $plugin"
    end
end

# 步骤2: 安装starship（自动确认）
green "步骤2: 检查并安装starship..."
if not is_installed starship
    yellow "安装starship提示符..."
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    check_error "安装starship"
else
    green "Starship已安装，跳过安装步骤"
end

# 配置starship (检查避免重复)
set config_file ~/.config/fish/config.fish
if not config_contains $config_file "starship init"
    yellow "添加starship初始化到fish配置..."
    echo 'starship init fish | source' >> $config_file
    check_error "配置starship"
else
    green "Starship已在fish配置中初始化"
end

# 步骤3: 安装mise和Python
green "步骤3: 检查并安装mise和Python..."

# 检查mise是否已安装
set mise_path $HOME/.local/bin/mise
if not test -e $mise_path
    yellow "安装mise版本管理器..."
    curl https://mise.run | sh
    check_error "安装mise"
else
    green "Mise已安装，跳过安装步骤"
end

# 添加mise到fish配置 (检查避免重复)
if not config_contains $config_file "mise activate"
    yellow "添加mise初始化到fish配置..."
    echo "$HOME/.local/bin/mise activate fish | source" >> $config_file
    check_error "配置mise到fish"
else
    green "Mise已在fish配置中初始化"
end

# 确保.local/bin在PATH中
if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end

# 加载mise到当前shell以便执行Python安装
if test -e $mise_path
    eval ($mise_path activate fish)
end

# 检查Python 3.10是否已安装
if test -e $mise_path
    if not $mise_path list python 2>/dev/null | grep -q "3.10"
        yellow "通过mise安装Python 3.10..."
        # 确保$PATH中包含mise
        $mise_path use -g python@3.10
        check_error "安装Python 3.10"
    else
        green "Python 3.10已由mise管理，跳过安装"
    end
else
    red "警告: mise未正确安装，跳过Python设置"
end

# 步骤4: 内核调优
green "步骤4: 执行内核调优..."
# 检查是否有sudo权限
if is_installed sudo
    # 检查是否已经应用过内核优化
    if test ! -e /tmp/.kernel_optimization_done
        yellow "应用内核调优设置..."
        bash -c "curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | bash"
        # 不检查错误，因为某些内核参数可能不支持
        touch /tmp/.kernel_optimization_done
    else
        green "内核已优化，跳过调优步骤"
    end
else
    red "警告: 无sudo权限，跳过内核调优。请手动执行或使用root权限运行此步骤。"
end

# 步骤5: 设置总结
green "\n====== 部署完成，设置总结 ======="
echo "Fish版本: "(fish --version)
echo "Fisher插件: "(fisher list | tr '\n' ' ')

# 安全获取版本信息，防止命令失败
function safe_version
    command -v $argv[1] >/dev/null 2>&1 && $argv[2..-1] 2>/dev/null || echo "未安装或未配置"
end

echo "Starship版本: "(safe_version starship --version)

# 检查mise是否正确安装并可用
if test -e $mise_path
    echo "Mise版本: "(eval $mise_path --version 2>/dev/null || echo "安装但无法获取版本")
    
    # 尝试获取Python版本
    set python_version (eval $mise_path exec python -- --version 2>/dev/null || echo "未配置")
    echo "Python版本: "$python_version
else
    echo "Mise状态: 安装路径不存在，请检查安装"
    echo "Python版本: 未通过mise配置"
end

echo "配置文件: "$config_file
echo "======================================"

green "\n所有设置已成功完成！"
yellow "提示: 重新启动终端以应用所有更改，或执行 'source ~/.config/fish/config.fish'"
