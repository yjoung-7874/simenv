if [ $# -lt 1 ]; then
  echo "Usage: $0 git-user-name"
  echo "  git-user-name : mostly AD account"
  exit -1
fi

USERNAME=$1

git config --global user.name "$USERNAME"
git config --global user.email "$USERNAME"@lge.com
git config --global push.default current
