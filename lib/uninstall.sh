#!/usr/bin/env bash
# Run on the TARGET. Tears down everything install.sh created.
# Honors SUDO_PASSWORD if set, like install.sh.
set -euo pipefail

run_sudo() {
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

step() { printf '\n\033[1;33m▸ %s\033[0m\n' "$*"; }

step "Stopping user service"
systemctl --user disable --now screen-to-rtsp.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/screen-to-rtsp.service"
rm -rf "$HOME/.config/screen-to-rtsp"
systemctl --user daemon-reload || true

step "Stopping mediamtx"
run_sudo systemctl disable --now mediamtx 2>/dev/null || true
run_sudo rm -f /etc/systemd/system/mediamtx.service /etc/mediamtx.yml
run_sudo systemctl daemon-reload || true

step "Removing binaries"
run_sudo rm -f /usr/local/bin/mediamtx /usr/local/bin/screen-to-rtsp

echo "Uninstalled."
