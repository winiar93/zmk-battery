#!/usr/bin/env bash
#
# Test suite for zmk-battery. Needs only bash and coreutils: busctl and the
# other system tools are replaced by tests/stubs, so it runs without Bluetooth
# hardware, D-Bus or systemd, and never touches the real home directory.
#
# Usage: tests/run.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/tests/stubs"
SCRIPT="$ROOT/zmk-battery.sh"

BATTERY_CHAR_UUID="00002a19-0000-1000-8000-00805f9b34fb"
BATTERY_SVC_UUID="0000180f-0000-1000-8000-00805f9b34fb"
HID_SVC_UUID="00001812-0000-1000-8000-00805f9b34fb"

MAC_A="AA:AA:AA:AA:AA:AA"
MAC_B="BB:BB:BB:BB:BB:BB"

# --- Helpers -----------------------------------------------------------------

fail() {
  echo "    $*" >&2
  exit 1
}

# run COMMAND... - stores combined output in OUT and the exit code in STATUS
run() {
  OUT=$("$@" 2>&1 </dev/null)
  STATUS=$?
}

assert_status() {
  [[ "$STATUS" -eq "$1" ]] || fail "expected exit code $1, got $STATUS. Output: $OUT"
}

assert_output() {
  [[ "$OUT" == *"$1"* ]] || fail "expected output to contain '$1'. Output: $OUT"
}

refute_output() {
  [[ "$OUT" != *"$1"* ]] || fail "expected output not to contain '$1'. Output: $OUT"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

refute_file() {
  [[ ! -e "$1" ]] || fail "expected file not to exist: $1"
}

assert_file_contains() {
  grep -qF -- "$2" "$1" 2>/dev/null || fail "expected $1 to contain '$2'"
}

# add_device MAC ALIAS [LEVEL...] - a paired HID device with one Battery Level
# characteristic per LEVEL. Connected unless DISCONNECTED=true is set.
add_device() {
  local mac="$1" alias="$2" dev i=0 level char connected="b true"
  shift 2
  dev="/org/bluez/hci0/dev_${mac//:/_}"
  [[ "${DISCONNECTED:-false}" == true ]] && connected="b false"

  echo "$dev" >>"$FAKE_BUS/tree"
  {
    echo "$dev org.bluez.Device1 Connected=$connected"
    echo "$dev org.bluez.Device1 ServicesResolved=$connected"
    echo "$dev org.bluez.Device1 UUIDs=as 2 \"$BATTERY_SVC_UUID\" \"$HID_SVC_UUID\""
    echo "$dev org.bluez.Device1 Alias=s \"$alias\""
  } >>"$FAKE_BUS/props"

  for level in "$@"; do
    i=$((i + 1))
    char="$dev/service0010/char000$i"
    echo "$char" >>"$FAKE_BUS/tree"
    echo "$char org.bluez.GattCharacteristic1 UUID=s \"$BATTERY_CHAR_UUID\"" >>"$FAKE_BUS/props"
    echo "$char $level" >>"$FAKE_BUS/levels"
  done
}

config_file() {
  echo "$HOME/.config/zmk-battery/config"
}

# --- zmk-battery.sh: arguments -----------------------------------------------

test_help_prints_usage() {
  run "$SCRIPT" --help
  assert_status 0
  assert_output "--notify"
}

test_unknown_argument_exits_2() {
  run "$SCRIPT" --nope
  assert_status 2
  assert_output "Unknown argument: --nope"
}

test_invalid_mac_exits_2() {
  run "$SCRIPT" --mac not-a-mac
  assert_status 2
  assert_output "Invalid MAC address"
}

test_invalid_zmk_mac_variable_exits_2() {
  ZMK_MAC="nope" run "$SCRIPT"
  assert_status 2
  assert_output "Invalid MAC address"
}

# --- zmk-battery.sh: reading -------------------------------------------------

test_split_keyboard_prints_both_levels() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT"
  assert_status 0
  assert_output "Left/Central: 57%"
  assert_output "Right/Peripheral: 63%"
}

test_lowercase_mac_is_accepted() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT" --mac "aa:aa:aa:aa:aa:aa"
  assert_status 0
  assert_output "Left/Central: 57%"
}

test_failed_read_of_every_battery_exits_1() {
  add_device "$MAC_A" "Corne" 57 63
  : >"$FAKE_BUS/levels"
  run "$SCRIPT"
  assert_status 1
  assert_output "Failed to read any battery."
}

test_device_without_battery_characteristic_exits_1() {
  add_device "$MAC_A" "Corne"
  run "$SCRIPT" --mac "$MAC_A"
  assert_status 1
  assert_output "No Battery Level characteristic"
}

# --- zmk-battery.sh: detection -----------------------------------------------

test_no_device_exits_1() {
  run "$SCRIPT"
  assert_status 1
  assert_output "No connected keyboard with Battery Service found."
}

test_split_wins_over_single_battery_device() {
  add_device "$MAC_A" "Mouse" 90
  add_device "$MAC_B" "Corne" 57 63
  run "$SCRIPT"
  assert_status 0
  assert_output "Left/Central: 57%"
  refute_output "90%"
}

test_several_splits_ask_for_a_choice() {
  add_device "$MAC_A" "Corne" 57 63
  add_device "$MAC_B" "Sofle" 41 42
  run "$SCRIPT"
  assert_status 1
  assert_output "Found several matching devices"
  assert_output "$MAC_A  Corne"
  assert_output "$MAC_B  Sofle"
}

test_name_picks_one_of_several_splits() {
  add_device "$MAC_A" "Corne" 57 63
  add_device "$MAC_B" "Sofle" 41 42
  run "$SCRIPT" --name sofle
  assert_status 0
  assert_output "Left/Central: 41%"
}

test_detected_keyboard_is_saved_to_config() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT"
  assert_status 0
  assert_file_contains "$(config_file)" "DEVICE_MAC=\"$MAC_A\""
}

test_saved_keyboard_wins_when_several_are_connected() {
  add_device "$MAC_A" "Corne" 57 63
  add_device "$MAC_B" "Sofle" 41 42
  mkdir -p "$(dirname "$(config_file)")"
  echo "DEVICE_MAC=\"$MAC_B\"" >"$(config_file)"
  run "$SCRIPT"
  assert_status 0
  assert_output "Left/Central: 41%"
}

test_single_battery_device_does_not_replace_saved_keyboard() {
  add_device "$MAC_A" "Mouse" 90
  DISCONNECTED=true add_device "$MAC_B" "Corne" 57 63
  mkdir -p "$(dirname "$(config_file)")"
  echo "DEVICE_MAC=\"$MAC_B\"" >"$(config_file)"
  run "$SCRIPT"
  assert_status 1
  assert_output "Could not connect to $MAC_B"
  refute_output "90%"
}

test_unknown_mac_exits_1() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT" --mac "$MAC_B"
  assert_status 1
  assert_output "BlueZ does not know device $MAC_B"
}

test_disconnected_keyboard_tries_to_connect() {
  DISCONNECTED=true add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT" --mac "$MAC_A"
  assert_status 1
  assert_output "Could not connect to $MAC_A"
  assert_file_contains "$FAKE_BUS/bluetoothctl.log" "connect $MAC_A"
}

# --- zmk-battery.sh: notifications -------------------------------------------

test_notify_only_for_levels_below_threshold() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT" --notify 60
  assert_status 0
  assert_file_contains "$FAKE_BUS/notify.log" "57% charge"
  if grep -qF "63% charge" "$FAKE_BUS/notify.log"; then
    fail "63% is above the threshold and should not notify"
  fi
}

test_no_notification_above_threshold() {
  add_device "$MAC_A" "Corne" 57 63
  run "$SCRIPT" --notify 20
  assert_status 0
  refute_file "$FAKE_BUS/notify.log"
}

test_no_notification_without_notify_flag() {
  add_device "$MAC_A" "Corne" 5 6
  run "$SCRIPT"
  assert_status 0
  refute_file "$FAKE_BUS/notify.log"
}

# --- install.sh --------------------------------------------------------------

test_install_rejects_invalid_values() {
  run "$ROOT/install.sh" --mac nope
  assert_status 1
  assert_output "invalid MAC address"
  run "$ROOT/install.sh" --threshold 101
  assert_status 1
  assert_output "invalid threshold"
  run "$ROOT/install.sh" --interval 'a;b'
  assert_status 1
  assert_output "invalid interval"
  run "$ROOT/install.sh" --name 'a|b'
  assert_status 1
  assert_output "invalid name"
  refute_file "$HOME/.local/bin/zmk-battery"
}

test_install_without_timer_writes_command_and_config() {
  run "$ROOT/install.sh" --no-timer --mac "$MAC_A" --threshold 15
  assert_status 0
  assert_file "$HOME/.local/bin/zmk-battery"
  assert_file_contains "$(config_file)" "DEVICE_MAC=\"$MAC_A\""
  assert_file_contains "$(config_file)" "THRESHOLD=15"
  refute_file "$HOME/.config/systemd/user/zmk-battery.timer"
  refute_file "$FAKE_BUS/systemctl.log"
}

test_install_with_timer_enables_it_with_the_interval() {
  run "$ROOT/install.sh" --interval 45min
  assert_status 0
  assert_file "$HOME/.config/systemd/user/zmk-battery.service"
  assert_file_contains "$HOME/.config/systemd/user/zmk-battery.timer" "OnUnitActiveSec=45min"
  assert_file_contains "$FAKE_BUS/systemctl.log" "--user enable --now zmk-battery.timer"
}

test_install_keeps_existing_config() {
  mkdir -p "$(dirname "$(config_file)")"
  echo "LABELS=(\"Mine\")" >"$(config_file)"
  run "$ROOT/install.sh" --no-timer
  assert_status 0
  assert_output "Keeping existing"
  assert_file_contains "$(config_file)" "LABELS=(\"Mine\")"
}

# --- uninstall.sh ------------------------------------------------------------

test_uninstall_removes_files_and_keeps_config() {
  run "$ROOT/install.sh"
  assert_status 0
  run "$ROOT/uninstall.sh"
  assert_status 0
  refute_file "$HOME/.local/bin/zmk-battery"
  refute_file "$HOME/.config/systemd/user/zmk-battery.timer"
  assert_file "$(config_file)"
}

test_uninstall_purge_removes_config() {
  run "$ROOT/install.sh" --no-timer
  assert_status 0
  run "$ROOT/uninstall.sh" --purge
  assert_status 0
  refute_file "$(config_file)"
}

test_uninstall_rejects_unknown_argument() {
  run "$ROOT/uninstall.sh" --nope
  assert_status 1
  assert_output "Usage:"
}

# --- Runner ------------------------------------------------------------------

# Each test runs in its own subshell with a fresh home directory and fake bus.
run_test() (
  local dir
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT

  export HOME="$dir/home"
  export FAKE_BUS="$dir/bus"
  export PATH="$STUBS:$PATH"
  unset XDG_CONFIG_HOME XDG_STATE_HOME ZMK_MAC ZMK_NAME
  mkdir -p "$HOME" "$FAKE_BUS"
  touch "$FAKE_BUS/tree" "$FAKE_BUS/props" "$FAKE_BUS/levels"

  "$1"
)

passed=0
failed=0
while read -r name; do
  if run_test "$name"; then
    echo "ok    $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    failed=$((failed + 1))
  fi
done < <(declare -F | awk '$3 ~ /^test_/ {print $3}')

echo
echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 && "$passed" -gt 0 ]]
