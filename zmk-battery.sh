#!/usr/bin/env bash
#
# zmk-battery.sh
# Reads the battery level (GATT Battery Level, UUID 0x2A19) of a ZMK split
# keyboard via BlueZ/D-Bus. Requires in the firmware:
#   CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY=y
#   CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=y
#
# The keyboard is detected automatically: the script looks for a connected
# device exposing HID (0x1812) and Battery Service (0x180F). Devices with at
# least two battery characteristics (a split with the proxy) take precedence.
# The detected MAC is saved to ~/.config/zmk-battery/config and used as a
# fallback when auto-detection finds nothing (e.g. the keyboard disconnected)
# or finds several matching devices.
#
# Usage:
#   ./zmk-battery.sh                  -> print battery levels
#   ./zmk-battery.sh --notify         -> same as above + send notify-send
#   ./zmk-battery.sh --notify 20      -> notify-send only when < 20%
#   ./zmk-battery.sh --name corne     -> pick a device by part of its name
#   ./zmk-battery.sh --mac AA:BB:...  -> use a specific device, no auto-detection
# Environment variables ZMK_MAC and ZMK_NAME work like --mac and --name.

set -euo pipefail

BATTERY_CHAR_UUID="00002a19-0000-1000-8000-00805f9b34fb"
BATTERY_SVC_UUID="0000180f-0000-1000-8000-00805f9b34fb"
HID_SVC_UUID="00001812-0000-1000-8000-00805f9b34fb"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zmk-battery"
CONFIG_FILE="$CONFIG_DIR/config"

NOTIFY=false
THRESHOLD=100
EXPLICIT_MAC="${ZMK_MAC:-}"
NAME_PATTERN="${ZMK_NAME:-}"

usage() {
  sed -n '/^# Usage:/,/^# Environment/p' "$0" | sed -E 's/^# ?//'
}

# --- Arguments -----------------------------------------------------------------

while (($#)); do
  case "$1" in
    --notify)
      NOTIFY=true
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        THRESHOLD="$2"
        shift
      fi
      ;;
    --mac)
      EXPLICIT_MAC="${2:?Missing MAC address after --mac}"
      shift
      ;;
    --name)
      NAME_PATTERN="${2:?Missing name after --name}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -n "$EXPLICIT_MAC" && ! "$EXPLICIT_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "Invalid MAC address: $EXPLICIT_MAC" >&2
  exit 2
fi
EXPLICIT_MAC="${EXPLICIT_MAC^^}"

# --- D-Bus helpers ---------------------------------------------------------------

BUS_TREE=""

# Flat list of all BlueZ object paths (without tree drawing characters).
refresh_tree() {
  BUS_TREE=$(busctl tree org.bluez 2>/dev/null | grep -oE '/org/bluez/[^[:space:]]+' || true)
}

# prop PATH INTERFACE PROPERTY -> raw busctl output, e.g. 'b true'
prop() {
  busctl get-property org.bluez "$1" "$2" "$3" 2>/dev/null || true
}

# Like prop, but for string properties: 's "Corne"' -> 'Corne'
str_prop() {
  prop "$@" | sed -E 's/^s "(.*)"$/\1/'
}

device_paths() {
  grep -E '^/org/bluez/hci[0-9]+/dev_([0-9A-F]{2}_){5}[0-9A-F]{2}$' <<<"$BUS_TREE" || true
}

path_for_mac() {
  grep -E "^/org/bluez/hci[0-9]+/dev_${1//:/_}\$" <<<"$BUS_TREE" | head -n1 || true
}

mac_for_path() {
  local m="${1##*/dev_}"
  echo "${m//_/:}"
}

is_ready() {
  [[ "$(prop "$1" org.bluez.Device1 Connected)" == "b true" ]] &&
    [[ "$(prop "$1" org.bluez.Device1 ServicesResolved)" == "b true" ]]
}

# Paths of Battery Level characteristics under a device, in a stable order.
battery_chars() {
  local dev="$1" path
  while read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$(str_prop "$path" org.bluez.GattCharacteristic1 UUID)" == "$BATTERY_CHAR_UUID" ]]; then
      echo "$path"
    fi
  done < <(grep -E "^${dev}/service[0-9a-f]+/char[0-9a-f]+\$" <<<"$BUS_TREE" | sort -V || true)
}

# --- Config file (fallback MAC) ----------------------------------------------------

load_saved_mac() {
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -n -E 's/^DEVICE_MAC="?(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})"?$/\1/p' "$CONFIG_FILE" | head -n1
  fi
}

save_config() {
  local mac="$1" name="${2//\"/}" tmp
  [[ "$(load_saved_mac)" == "$mac" ]] && return 0
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.config.XXXXXX")
  {
    echo "# Saved automatically by zmk-battery.sh ($(date '+%F %T'))"
    echo "# Used as a fallback when auto-detection cannot find the keyboard."
    printf 'DEVICE_MAC="%s"\n' "$mac"
    printf 'DEVICE_NAME="%s"\n' "$name"
  } >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  echo "Saved keyboard ${name:-?} ($mac) to $CONFIG_FILE" >&2
}

# --- Keyboard detection ------------------------------------------------------------

# Prints matching device paths; splits (>=2 batteries) take precedence.
autodetect() {
  local dev uuids alias n
  local split=() single=()
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    is_ready "$dev" || continue
    uuids=$(prop "$dev" org.bluez.Device1 UUIDs)
    [[ "$uuids" == *"$BATTERY_SVC_UUID"* && "$uuids" == *"$HID_SVC_UUID"* ]] || continue
    if [[ -n "$NAME_PATTERN" ]]; then
      alias=$(str_prop "$dev" org.bluez.Device1 Alias)
      [[ "${alias,,}" == *"${NAME_PATTERN,,}"* ]] || continue
    fi
    n=$(battery_chars "$dev" | wc -l)
    if ((n >= 2)); then
      split+=("$dev")
    elif ((n == 1)); then
      single+=("$dev")
    fi
  done < <(device_paths)

  # First line: "split" or "single" (which kind of devices was found).
  if ((${#split[@]})); then
    echo "split"
    printf '%s\n' "${split[@]}"
  elif ((${#single[@]})); then
    echo "single"
    printf '%s\n' "${single[@]}"
  fi
}

try_connect() {
  local mac="$1" path _
  echo "Keyboard $mac is not connected, trying to connect..." >&2
  timeout 15 bluetoothctl connect "$mac" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    refresh_tree
    path=$(path_for_mac "$mac")
    if [[ -n "$path" ]] && is_ready "$path"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Sets DEVICE_PATH to the keyboard's D-Bus path or exits with an error.
resolve_device() {
  local mac path saved kind candidates=() c
  refresh_tree

  if [[ -n "$EXPLICIT_MAC" ]]; then
    mac="$EXPLICIT_MAC"
  else
    mapfile -t candidates < <(autodetect)
    saved=$(load_saved_mac)
    kind="${candidates[0]:-}"
    candidates=("${candidates[@]:1}")

    # The saved keyboard is connected -> always use it.
    for c in "${candidates[@]}"; do
      if [[ -n "$saved" && "$(mac_for_path "$c")" == "$saved" ]]; then
        DEVICE_PATH="$c"
        return 0
      fi
    done

    # Single-battery devices (e.g. a mouse) don't replace the saved keyboard
    # (unless picked explicitly with --name).
    if [[ "$kind" == "single" && -n "$saved" && -z "$NAME_PATTERN" ]]; then
      candidates=()
    fi

    if ((${#candidates[@]} == 1)); then
      DEVICE_PATH="${candidates[0]}"
      save_config "$(mac_for_path "$DEVICE_PATH")" "$(str_prop "$DEVICE_PATH" org.bluez.Device1 Alias)"
      return 0
    fi

    if ((${#candidates[@]} > 1)); then
      echo "Found several matching devices, pick one with --mac or --name:" >&2
      for c in "${candidates[@]}"; do
        echo "  $(mac_for_path "$c")  $(str_prop "$c" org.bluez.Device1 Alias)" >&2
      done
      exit 1
    fi

    if [[ -z "$saved" ]]; then
      echo "No connected keyboard with Battery Service found." >&2
      echo "Connect the keyboard (bluetoothctl connect <MAC>) or pass --mac." >&2
      exit 1
    fi
    echo "Auto-detection found nothing, using saved $saved." >&2
    mac="$saved"
  fi

  path=$(path_for_mac "$mac")
  if [[ -z "$path" ]]; then
    echo "BlueZ does not know device $mac. Is it paired?" >&2
    exit 1
  fi
  if ! is_ready "$path"; then
    if ! try_connect "$mac"; then
      echo "Could not connect to $mac (try: bluetoothctl connect $mac)." >&2
      exit 1
    fi
    path=$(path_for_mac "$mac")
  fi
  DEVICE_PATH="$path"
}

# --- Battery readout ---------------------------------------------------------------

DEVICE_PATH=""
resolve_device

mapfile -t CHAR_PATHS < <(battery_chars "$DEVICE_PATH")

if [[ ${#CHAR_PATHS[@]} -eq 0 ]]; then
  echo "No Battery Level characteristic (UUID $BATTERY_CHAR_UUID) found under $DEVICE_PATH." >&2
  exit 1
fi

count=0
labels=("Left/Central" "Right/Peripheral" "Battery #3" "Battery #4")

for path in "${CHAR_PATHS[@]}"; do
  raw=$(busctl call org.bluez "$path" org.bluez.GattCharacteristic1 ReadValue a{sv} 0 2>/dev/null || true)

  if [[ -z "$raw" ]]; then
    echo "Failed to read: $path" >&2
    continue
  fi

  # busctl returns e.g. "ay 1 65" -> the last number is the value in %
  value=$(awk '{print $NF}' <<<"$raw")
  label="${labels[$count]:-Battery #$((count + 1))}"

  echo "${label}: ${value}%"

  if $NOTIFY && [[ "$value" -lt "$THRESHOLD" ]]; then
    notify-send -i battery-caution "Keyboard battery (${label})" "${value}% charge"
  fi

  count=$((count + 1))
done

if [[ $count -eq 0 ]]; then
  echo "Failed to read any battery." >&2
  exit 1
fi