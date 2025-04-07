#!/usr/bin/env fish

# 彩色输出函数
function green
    echo -e "\033[32m$argv\033[0m"
end

function red
    echo -e "\033[31m$argv\033[0m"
end

function check_error
    if test $status -ne 0
        red "错误: $argv 执行失败"
        exit 1
    end
end

# 步骤1: 安装fisher和插件
green "步骤1: 安装fisher和插件..."
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
check_error "安装fisher"

fisher install jorgebucaran/fisher
check_error "安装fisher核心插件"

green "安装fisher插件集..."
fisher install jhillyerd/plugin-git jorgebucaran/autopair.fish jethrokuan/z edc/bass patrickf1/fzf.fish
check_error "安装fisher插件"

# 步骤2: 安装starship
green "步骤2: 安装starship..."
curl -sS https://starship.rs/install.sh | sh
check_error "安装starship"

# 配置starship (检查避免重复)
if not grep -q "starship init" ~/.config/fish/config.fish
    echo 'starship init fish | source' >> ~/.config/fish/config.fish
    check_error "配置starship"
end

# 步骤3: 安装mise和Python
green "步骤3: 安装mise和Python..."
curl https://mise.run | sh
check_error "安装mise"

# 添加mise到fish配置 (检查避免重复)
if not grep -q "mise activate" ~/.config/fish/config.fish
    echo "$HOME/.local/bin/mise activate fish | source" >> ~/.config/fish/config.fish
    check_error "配置mise到fish"
end

# 确保.local/bin在PATH中
set -gx PATH $HOME/.local/bin $PATH

# 安装Python 3.10
~/.local/bin/mise use -g python@3.10
check_error "安装Python 3.10"

# 步骤4: 内核调优
green "步骤4: 执行内核调优..."
bash -c "curl -fsSL https://raw.githubusercontent.com/LucaLin233/Luca_Conf/refs/heads/main/Other/kernel_optimization.sh | bash"
check_error "内核调优"

green "所有设置已成功完成！"
green "重新启动终端以应用所有更改，或执行 'source ~/.config/fish/config.fish'"
