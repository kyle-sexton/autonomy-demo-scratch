# shellcheck shell=bash
# Git Bash on Windows: prevent MSYS from rewriting POSIX container paths for docker.
#
# Usage: source "$(dirname "$0")/lib/docker-git-bash.sh" && docker_git_bash_prepare

docker_git_bash_prepare() {
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
}
