#!/usr/bin/env bash
# Install fnm (Fast Node Manager) for cloud-setup and CI.
#
# Idempotent: safe to rerun. Symlinks fnm into /usr/local/bin when possible so
# every shell sees it without mutating ~/.bashrc (--skip-shell on upstream installer).
#
# Usage:
#   source tools/shared/node-runtime/install-fnm.sh && install_fnm
#   bash tools/shared/node-runtime/install-fnm.sh

set -uo pipefail

install_fnm() {
  local url="https://fnm.vercel.app/install"
  local installer="/tmp/fnm-install.sh"

  if declare -f retry_fetch >/dev/null 2>&1; then
    retry_fetch "$url" "$installer" || return 0
  elif ! curl -fsSL "$url" -o "$installer"; then
    return 0
  fi

  if ! head -c 2 "$installer" | grep -q '^#!'; then
    echo "WARN: $installer does not start with #! — skipping fnm install" >&2
    rm -f "$installer"
    return 0
  fi

  bash "$installer" --skip-shell 2>/dev/null || true
  ln -sf "$HOME/.local/share/fnm/fnm" /usr/local/bin/fnm 2>/dev/null || true
  rm -f "$installer"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_fnm
fi
