#!/bin/bash

USERNAME=$1
PASSWORD=$2
HOST_UID=$3

if [ -n "$USERNAME" ]; then
    useradd -u ${HOST_UID} -m -s /bin/bash ${USERNAME}
    if [ $? -ne 0 ]; then
        echo "adding user failed."
        exit 1
    fi
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    if [ $? -ne 0 ]; then
        echo "change password failed."
        exit 1
    fi
    usermod -d /devenv/${USERNAME} -m ${USERNAME}
    usermod -aG sudo ${USERNAME}

    cp /root/.tmux.conf /devenv/"$USERNAME"
    # cp /root/.Xauthority /devenv/"$USERNAME"
    # chown $USERNAME:$USERNAME /devenv/"$USERNAME"/.Xauthority

    cp -a /home/"$USERNAME"/. /devenv/"$USERNAME"
    rm -rf /home/"$USERNAME"

    SSHD_CONFIG="/etc/ssh/ssh_config"
    NEW_LINES="HostKeyAlgorithms +ssh-rsa\nPubkeyAcceptedAlgorithms +ssh-rsa"
    
    if ! grep -q "HostKeyAlgorithms +ssh-rsa" "$SSHD_CONFIG"; then
        echo -e "$NEW_LINES" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "ssh-rsa setting updated."
    else
        echo "ssh-rsa setting already exist."
    fi
    # cp -r /root/.ssh /devenv/"$USERNAME"/.ssh
    # chown -R $USERNAME:$USERNAME /devenv/"$USERNAME"/.ssh

    service ssh stop
    service ssh start

    cp -r /root/.nvm /devenv/"$USERNAME"
    chown -R $USERNAME:$USERNAME /devenv/"$USERNAME"/.nvm
    . /devenv/"$USERNAME"/.nvm/nvm.sh 
    echo -e '\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" \n[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> /devenv/"$USERNAME"/.bashrc

    echo -e '\nexport CURRENT_SYSTEM=container' >> /devenv/"$USERNAME"/.bashrc
fi

exec /bin/bash