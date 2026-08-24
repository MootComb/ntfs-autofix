# NTFS Auto-Fix

A bash script that automatically detects and fixes dirty NTFS filesystems on USB drives.

## Features

- 🔍 **Automatic Detection** - Identifies NTFS filesystems on USB devices
- 🔧 **Automatic Repair** - Runs `ntfsfix` on dirty filesystems
- 📢 **Desktop Notifications** - Alerts users (can be disabled)
- 📝 **Logging** - Detailed logs (can be disabled)
- 🔒 **Safety** - Prevents concurrent operations on the same device

## Quick Install

```bash
# Download
curl -O https://raw.githubusercontent.com/MootComb/ntfs-autofix/main/ntfs-autofix
cd ntfs-autofix
chmod +x ntfs-autofix.sh

# Install with default settings (notifications & logging enabled)
sudo ./ntfs-autofix.sh install

# Silent install (no notifications, no logging)
ENABLE_NOTIFICATIONS=0 ENABLE_LOGGING=0 ./ntfs-autofix.sh install
```

## Commands

| Command | Description |
|---------|-------------|
| `sudo ntfs-autofix install` | Install the service |
| `sudo ntfs-autofix uninstall` | Remove the service |
| `sudo ntfs-autofix status` | Show service status |

## Configuration

Settings stored in `/etc/ntfs-autofix.conf`:

```bash
ENABLE_NOTIFICATIONS=1  # Desktop notifications (0 to disable)
ENABLE_LOGGING=1        # Log to /var/log/ntfs-autofix.log (0 to disable)
```

### Override During Install

Set environment variables before running install:

```bash
# Silent install
ENABLE_NOTIFICATIONS=0 ENABLE_LOGGING=0 ./ntfs-autofix install

# Enable notifications, disable logging
ENABLE_NOTIFICATIONS=1 ENABLE_LOGGING=0 ./ntfs-autofix install
```

## How It Works

1. USB device plugged in → udev triggers the script
2. Checks if filesystem is NTFS
3. If dirty, unmounts and runs `ntfsfix`
4. Sends desktop notification (if enabled)
5. Logs all actions (if enabled)

## Uninstall

```bash
sudo ntfs-autofix uninstall
```

## Requirements

- Linux with systemd and udev
- Root privileges
- `ntfs-3g` (auto-installed via pacman on Arch)
- `libnotify` (optional, for notifications)

## Troubleshooting

### Check service status
```bash
sudo ntfs-autofix status
```

### View logs (if enabled)
```bash
sudo tail -f /var/log/ntfs-autofix.log
```

### Fix notifications
```bash
sudo pacman -S libnotify
sudo sed -i 's/ENABLE_NOTIFICATIONS=0/ENABLE_NOTIFICATIONS=1/' /etc/ntfs-autofix.conf
```

### Reload udev rules
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=block
```
