#!/bin/zsh

sudo apt install -y fonts-powerline 

git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting # zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}/plugins/zsh-autosuggestions # zsh-autosuggestions
git clone --depth 1 https://github.com/junegunn/fzf.git ${HOME}/.fzf  # fzf (Fuzzy Finder )
${HOME}/.fzf/install

# update zshrc (plugins)
sudo cp /entry/setup/config/agnoster_custom.zsh-theme ${HOME}/.oh-my-zsh/themes
sudo cp /entry/setup/config/.zshrc ${HOME}

echo "\033[32;1m======= zsh env setup done.. try re-login =======\033[0m"