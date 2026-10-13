#!/usr/bin/env bash
#
# Removes zmk-battery. The config file is kept unless --purge is given.
# The remembered auto-detected keyboard (~/.local/state/zmk-battery) is always removed.

set -euo pipefail

BIN="$HOME/.local/bin/zmk-battery"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zmk-battery"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zmk-battery"

PURGE=false
case "${1:-}" in
    --purge) PURGE=true ;;
    "") ;;
    *) echo "Usage: ./uninstall.sh [--purge]" >&2; exit 1 ;;
esac

if command -v systemctl >/dev/null; then
    systemctl --user disable --now zmk-battery.timer 2>/dev/null || true
fi

rm -f "$UNIT_DIR/zmk-battery.service" "$UNIT_DIR/zmk-battery.timer" "$BIN"
rm -rf "$STATE_DIR"   # only the remembered auto-detected keyboard

if command -v systemctl >/dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
fi

if $PURGE; then
    rm -rf "$CONF_DIR"
    echo "zmk-battery removed, including its config."
else
    echo "zmk-battery removed. Config kept in $CONF_DIR (use --purge to delete it)."
fi
