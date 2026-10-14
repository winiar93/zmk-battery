#!/usr/bin/env bash
#
# Installs zmk-battery for the current user (no root needed):
#   ~/.local/bin/zmk-battery
#   ~/.config/zmk-battery/config
#   ~/.config/systemd/user/zmk-battery.{service,timer}

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zmk-battery"
CONF_FILE="$CONF_DIR/config"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

MAC=""
NAME=""
THRESHOLD=""
INTERVAL="15min"
TIMER=true

usage() {
    cat <<EOF
Usage: ./install.sh [options]

Options:
  --mac MAC         Keyboard MAC address (default: ask, or auto-detect)
  --name TEXT       Auto-detect only keyboards whose name contains TEXT
  --threshold N     Notify below N percent (default: 20)
  --interval TIME   How often to check, systemd time span (default: 30min)
  --no-timer        Install the command only, without the systemd timer
  -h, --help        Show this help
EOF
}

die() {
    echo "install: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac)       [[ $# -ge 2 ]] || die "--mac needs a value";       MAC="${2^^}";   shift 2 ;;
        --name)      [[ $# -ge 2 ]] || die "--name needs a value";      NAME="$2";      shift 2 ;;
        --threshold) [[ $# -ge 2 ]] || die "--threshold needs a value"; THRESHOLD="$2"; shift 2 ;;
        --interval)  [[ $# -ge 2 ]] || die "--interval needs a value";  INTERVAL="$2";  shift 2 ;;
        --no-timer)  TIMER=false; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

valid_mac() {
    [[ "$1" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]
}

if [[ -n "$MAC" ]]; then
    valid_mac "$MAC" || die "invalid MAC address: $MAC"
fi
if [[ -n "$THRESHOLD" ]]; then
    [[ "$THRESHOLD" =~ ^[0-9]+$ && "$THRESHOLD" -le 100 ]] || die "invalid threshold: $THRESHOLD"
fi
[[ "$INTERVAL" =~ ^[0-9a-zA-Z\ ]+$ ]] || die "invalid interval: $INTERVAL"
[[ "$NAME" =~ ^[[:alnum:][:space:]._-]*$ ]] || die "invalid name: $NAME (letters, digits, spaces, . _ - only)"

# set_conf KEY VALUE - replace KEY=... in the config, or append it if missing
# (configs from older versions may lack newer keys)
set_conf() {
    if grep -q "^$1=" "$CONF_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$CONF_FILE"
    else
        printf '%s=%s\n' "$1" "$2" >>"$CONF_FILE"
    fi
}

# --- dependencies ------------------------------------------------------------

command -v busctl >/dev/null || die "busctl not found (it is part of systemd)"
if $TIMER; then
    command -v systemctl >/dev/null || die "systemctl not found (use --no-timer to skip the timer)"
fi
if ! command -v notify-send >/dev/null; then
    echo "Warning: notify-send not found - install libnotify to get notifications." >&2
fi

# --- command -----------------------------------------------------------------

install -Dm755 "$SRC_DIR/zmk-battery.sh" "$BIN_DIR/zmk-battery"
echo "Installed $BIN_DIR/zmk-battery"

# --- config ------------------------------------------------------------------

NEW_CONFIG=false
if [[ ! -f "$CONF_FILE" ]]; then
    install -Dm644 "$SRC_DIR/config.example" "$CONF_FILE"
    NEW_CONFIG=true
    echo "Created $CONF_FILE"
else
    echo "Keeping existing $CONF_FILE"
fi

# On a fresh install without --mac or --name, offer to pick the keyboard
if $NEW_CONFIG && [[ -z "$MAC" && -z "$NAME" && -t 0 ]]; then
    echo
    echo "Devices currently exposing a battery level:"
    "$BIN_DIR/zmk-battery" --list || true
    echo
    read -rp "Keyboard MAC address (leave empty to auto-detect): " MAC
    MAC="${MAC^^}"
    if [[ -n "$MAC" ]] && ! valid_mac "$MAC"; then
        echo "Not a valid MAC address, leaving auto-detect enabled." >&2
        MAC=""
    fi
fi

if [[ -n "$MAC" ]]; then
    set_conf DEVICE_MAC "\"$MAC\""
fi
if [[ -n "$NAME" ]]; then
    set_conf DEVICE_NAME "\"$NAME\""
fi
if [[ -n "$THRESHOLD" ]]; then
    set_conf THRESHOLD "$THRESHOLD"
fi

# --- systemd timer -----------------------------------------------------------

if $TIMER; then
    install -Dm644 "$SRC_DIR/zmk-battery.service" "$UNIT_DIR/zmk-battery.service"
    install -Dm644 "$SRC_DIR/zmk-battery.timer" "$UNIT_DIR/zmk-battery.timer"
    sed -i "s|^OnUnitActiveSec=.*|OnUnitActiveSec=$INTERVAL|" "$UNIT_DIR/zmk-battery.timer"

    systemctl --user daemon-reload
    systemctl --user enable --now zmk-battery.timer
    systemctl --user restart zmk-battery.timer
    echo "Enabled zmk-battery.timer (every $INTERVAL)"
fi

# --- summary -----------------------------------------------------------------

echo
echo "Current reading:"
"$BIN_DIR/zmk-battery" || echo "(no reading - is the keyboard connected and awake?)"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo
        echo "Note: $BIN_DIR is not in your PATH. Add it to run 'zmk-battery' from anywhere:"
        echo "  fish:      fish_add_path $BIN_DIR"
        echo "  bash/zsh:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
        ;;
esac
