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
- Nothing to build: it needs only bash
- Nothing running in the background: Timer starts the script for a second then exits.
- Works on any desktop: KDE Plasma, Gnome, Hyprland
- It uses ZMK's standard battery level proxy


# Requirements
- BlueZ
- sstemd
- notify-send from libnotify
  
On Arch-based systems everything except libnotify is normally already there:
`sudo pacman -S --needed bluez libnotify`
