#!/usr/bin/env bash
# Interactive setup wizard for ScreenToRtsp.
# Run this script ON the machine that will publish the stream.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_C=$'\033[1;36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_C=; C_D=; C_0=
fi

banner() {
  cat <<EOF
${C_C}╭──────────────────────────────────────────────────╮
│  ScreenToRtsp — interactive setup                │
│  GNOME Wayland → MediaMTX → Frigate              │
╰──────────────────────────────────────────────────╯${C_0}
EOF
}

ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    printf '%s%s%s [%s]: ' "$C_B" "$prompt" "$C_0" "$default" >&2
  else
    printf '%s%s%s: ' "$C_B" "$prompt" "$C_0" >&2
  fi
  IFS= read -r reply
  printf '%s' "${reply:-$default}"
}

ask_secret() {
  local prompt="$1" reply
  printf '%s%s%s: ' "$C_B" "$prompt" "$C_0" >&2
  IFS= read -rs reply; echo >&2
  printf '%s' "$reply"
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" reply hint
  hint=$([[ $default == y ]] && echo "[Y/n]" || echo "[y/N]")
  while :; do
    printf '%s%s%s %s: ' "$C_B" "$prompt" "$C_0" "$hint" >&2
    IFS= read -r reply || reply=""
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

choose() {
  local title="$1"; shift
  local opts=("$@") i
  echo "${C_B}${title}${C_0}" >&2
  for i in "${!opts[@]}"; do printf '  %s%2d)%s %s\n' "$C_Y" "$((i+1))" "$C_0" "${opts[$i]}" >&2; done
  while :; do
    local n
    n="$(ask "Choice [1-${#opts[@]}]" "1")"
    [[ $n =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#opts[@]} ]] && {
      printf '%s' "${opts[$((n-1))]}"; return
    }
  done
}

# ── existing-install detection ──────────────────────────────────────────────
CURRENT_PROFILE=""
CURRENT_CONNECTOR=""
CURRENT_URL=""
CURRENT_USER=""
if [[ -f "$HOME/.config/screen-to-rtsp/profile.env" ]]; then
  # shellcheck disable=SC1091
  CURRENT_PROFILE="$(grep -oP '(?<=profile: )\S+' "$HOME/.config/screen-to-rtsp/profile.env" || true)"
  CURRENT_CONNECTOR="$(grep -oP '(?<=^SCREEN_CONNECTOR=).*' "$HOME/.config/screen-to-rtsp/profile.env" || true)"
  CURRENT_URL="$(grep -oP '(?<=^RTSP_URL=).*' "$HOME/.config/screen-to-rtsp/profile.env" || true)"
fi
if [[ -f "$HOME/.config/screen-to-rtsp/credentials.env" ]]; then
  CURRENT_USER="$(grep -oP '(?<=^RTSP_USER=).*' "$HOME/.config/screen-to-rtsp/credentials.env" || true)"
fi

banner

if [[ -n "$CURRENT_PROFILE" ]]; then
  echo "${C_D}Existing install detected — profile=$CURRENT_PROFILE connector=$CURRENT_CONNECTOR auth=${CURRENT_USER:-none}${C_0}"
  echo
fi

ACTION="$(choose "What do you want to do?" \
  "Install / reconfigure" \
  "Uninstall" \
  "Show stream URL only")"

case "$ACTION" in
  Uninstall)
    bash "$ROOT/lib/uninstall.sh"; exit ;;
  Show*)
    echo
    if [[ -n "$CURRENT_URL" ]]; then
      IP="$(hostname -I | awk '{print $1}')"
      LOCAL_URL="$(echo "$CURRENT_URL" | sed "s|localhost|${IP}|")"
      if [[ -n "$CURRENT_USER" ]]; then
        echo "  rtsp://${CURRENT_USER}:<password>@${IP}:$(echo "$CURRENT_URL" | sed -nE 's|.*://[^/]+:([0-9]+)/.*|\1|p')/$(echo "$CURRENT_URL" | sed -nE 's|.*/([^/]+)$|\1|p')"
        echo "  ${C_D}(password in ~/.config/screen-to-rtsp/credentials.env)${C_0}"
      else
        echo "  $LOCAL_URL"
      fi
    else
      echo "${C_R}Nothing installed yet — run ./setup.sh first.${C_0}"
    fi
    exit ;;
esac

# ── auto-detect monitor connectors ──────────────────────────────────────────
detect_connectors() {
  command -v gdbus >/dev/null 2>&1 || return
  : "${DBUS_SESSION_BUS_ADDRESS:=unix:path=/run/user/$(id -u)/bus}"
  : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
  gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null \
    | grep -oP "\(\('\K[^']+" | sort -u
}

# ── profile ─────────────────────────────────────────────────────────────────
echo
echo "${C_C}── Quality profile ──${C_0}"
mapfile -t PROFILE_FILES < <(ls "$ROOT/profiles"/*.env 2>/dev/null | sort)
[[ ${#PROFILE_FILES[@]} -gt 0 ]] || { echo "${C_R}No profiles found${C_0}"; exit 1; }
PROFILE_OPTS=()
for f in "${PROFILE_FILES[@]}"; do
  name="$(basename "$f" .env)"
  vars=$(grep -vE '^\s*(#|$)' "$f" | tr '\n' ' ')
  marker=""; [[ "$name" == "$CURRENT_PROFILE" ]] && marker=" ${C_G}(current)${C_0}"
  PROFILE_OPTS+=("$(printf '%-7s %s%s' "$name" "$vars" "$marker")")
done
PROFILE_LINE="$(choose "Select profile" "${PROFILE_OPTS[@]}")"
PROFILE="${PROFILE_LINE%% *}"

# ── capture settings ────────────────────────────────────────────────────────
echo
echo "${C_C}── Capture settings ──${C_0}"
mapfile -t CONNECTORS < <(detect_connectors)
DEFAULT_CONN="${CURRENT_CONNECTOR:-${CONNECTORS[0]:-Virtual-1}}"
if [[ ${#CONNECTORS[@]} -gt 1 ]]; then
  echo "${C_D}Detected connectors: ${CONNECTORS[*]}${C_0}"
elif [[ ${#CONNECTORS[@]} -eq 1 ]]; then
  echo "${C_D}Detected connector: ${CONNECTORS[0]}${C_0}"
fi
SCREEN_CONNECTOR="$(ask "Monitor connector" "$DEFAULT_CONN")"

DEFAULT_PORT=8554; DEFAULT_PATH=screen
if [[ -n "$CURRENT_URL" ]]; then
  DEFAULT_PORT="$(echo "$CURRENT_URL" | sed -nE 's|.*://[^/]+:([0-9]+)/.*|\1|p')"
  DEFAULT_PATH="$(echo "$CURRENT_URL" | sed -nE 's|.*/([^/]+)$|\1|p')"
fi
RTSP_PORT="$(ask "RTSP port" "$DEFAULT_PORT")"
RTSP_PATH="$(ask "RTSP path (URL: rtsp://host:port/<path>)" "$DEFAULT_PATH")"

# ── auth ────────────────────────────────────────────────────────────────────
echo
echo "${C_C}── RTSP authentication ──${C_0}"
AUTH_DEFAULT=$([[ -n "$CURRENT_USER" ]] && echo y || echo y)
if ask_yes_no "Require username/password to access the stream?" "$AUTH_DEFAULT"; then
  RTSP_USER="$(ask "RTSP username" "${CURRENT_USER:-cam}")"
  while :; do
    RTSP_PASS="$(ask_secret "RTSP password (leave empty to auto-generate)")"
    if [[ -z $RTSP_PASS ]]; then
      RTSP_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
      echo "${C_Y}Generated: $RTSP_PASS${C_0}"
      break
    fi
    P2="$(ask_secret "Confirm RTSP password")"
    [[ $RTSP_PASS == "$P2" ]] && break
    echo "${C_R}Passwords don't match — try again.${C_0}"
  done
else
  RTSP_USER=""
  RTSP_PASS=""
fi

# ── sudo password (for unattended apt + writes to /etc) ─────────────────────
echo
echo "${C_C}── Sudo ──${C_0}"
if sudo -n true 2>/dev/null; then
  SUDO_PASS=""
  echo "${C_D}Passwordless sudo detected.${C_0}"
elif ask_yes_no "Cache sudo password for this run (avoids repeated prompts)?" "y"; then
  SUDO_PASS="$(ask_secret "Sudo password")"
else
  SUDO_PASS=""
fi

# ── summary + confirm ───────────────────────────────────────────────────────
echo
echo "${C_C}── Summary ──${C_0}"
cat <<EOF
  Profile:    $PROFILE   ($(grep -vE '^\s*(#|$)' "$ROOT/profiles/${PROFILE}.env" | xargs))
  Connector:  $SCREEN_CONNECTOR
  RTSP:       rtsp://<host>:${RTSP_PORT}/${RTSP_PATH}
  Auth:       $([[ -n $RTSP_USER ]] && echo "user=$RTSP_USER pass=$(printf '%*s' "${#RTSP_PASS}" "" | tr ' ' '*')" || echo "none")
EOF
ask_yes_no "Proceed?" "y" || { echo "Cancelled."; exit 0; }

# ── execute ─────────────────────────────────────────────────────────────────
echo
echo "${C_G}Running installer …${C_0}"
env \
  PROFILE="$PROFILE" \
  SCREEN_CONNECTOR="$SCREEN_CONNECTOR" \
  RTSP_PORT="$RTSP_PORT" \
  RTSP_PATH="$RTSP_PATH" \
  RTSP_USER="$RTSP_USER" \
  RTSP_PASS="$RTSP_PASS" \
  SUDO_PASSWORD="$SUDO_PASS" \
  bash "$ROOT/lib/install.sh"
