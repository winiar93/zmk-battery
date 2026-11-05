# zmk-battery
Shows battery level of both halves of a ZMK split keyboard on Linux, with desktop notifications. 
A single bash script and a systemd timer, no GUI, no daemon.


```
$ zmk-battery
Central: 57%
Peripheral: 63%
```

# Why zmk-battery?
`zmk-battery` is for users who only want a warning before the keyboard dies. without running another app.
- Nothing to build: it's a single bash script that uses tools already on most Linux desktops (see Requirements)
- Nothing running in the background: Timer starts the script for a second then exits.
- Works on any desktop: KDE Plasma, Gnome, Hyprland
- It uses ZMK's standard battery level proxy


# Requirements
- BlueZ, including `bluetoothctl` (optional, used to reconnect the keyboard automatically)
- systemd
- notify-send from libnotify (optional, used for notifications)

On Arch-based systems, install the packages that may be missing:

`sudo pacman -S --needed bluez bluez-utils libnotify`

# Installation

Connect the keyboard over Bluetooth first, then:
 
```bash
git clone https://github.com/YOUR_USERNAME/zmk-battery.git
cd zmk-battery
chmod +x install.sh uninstall.sh zmk-battery.sh
./install.sh
```


### Verify the installation
 
```bash
systemctl --user is-enabled zmk-battery.timer
systemctl --user list-timers --all | grep zmk
systemctl --user start zmk-battery.service; journalctl --user -u zmk-battery.service -n 5 --no-pager
```

# Usage
```bash
Usage:
  ./zmk-battery.sh                  -> print battery levels
  ./zmk-battery.sh --notify         -> same as above + send notify-send
  ./zmk-battery.sh --notify 20      -> notify-send only when < 20%
  ./zmk-battery.sh --name corne     -> pick a device by part of its name
  ./zmk-battery.sh --mac AA:BB:...  -> use a specific device, no auto-detection
Environment variables ZMK_MAC and ZMK_NAME work like --mac and --name.
```