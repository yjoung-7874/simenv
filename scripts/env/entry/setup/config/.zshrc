export ZSH="$HOME/.oh-my-zsh"
export PATH=~/mtools:$PATH
export TERM=xterm-256color
export EDITOR=vim
# ZSH_THEME="agnoster_custom"
ZSH_THEME="dst"

plugins=(
        git
        sudo
        colored-man-pages
        zsh-syntax-highlighting
        zsh-autosuggestions
        fzf
        docker
)

source $ZSH/oh-my-zsh.sh

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" 
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export CURRENT_SYSTEM="container"