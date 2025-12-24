#!/bin/bash
# Start Mac OS 9 Emulator

MACEMU_DIR="/opt/macemu"
CONFIG_FILE="$MACEMU_DIR/config/qemu.conf"

# Defaults
RAM_MB=512
BOOT_DEVICE=d
SCREEN_WIDTH=1024
SCREEN_HEIGHT=768
VNC_DISPLAY=0
SOUND_ENABLED=0
PRIMARY_DISK=macos9.qcow2
SECONDARY_DISK=
CDROM_ISO=macos_921_ppc.iso

# Load configuration (overrides defaults)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Auto-detect display resolution if running with X
if [ -n "$DISPLAY" ]; then
    # Try to get resolution from xrandr
    DETECTED_RES=$(xrandr 2>/dev/null | grep '\*' | head -1 | awk '{print $1}')
    
    if [ -n "$DETECTED_RES" ]; then
        SCREEN_WIDTH=$(echo "$DETECTED_RES" | cut -d'x' -f1)
        SCREEN_HEIGHT=$(echo "$DETECTED_RES" | cut -d'x' -f2)
        echo "Detected display resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    else
        # Fallback to default
        SCREEN_WIDTH=1024
        SCREEN_HEIGHT=768
        echo "Could not detect resolution, using default: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    fi
fi

# Build QEMU command
QEMU_CMD="qemu-system-ppc"
QEMU_ARGS="-M mac99,via=pmu"
QEMU_ARGS="$QEMU_ARGS -m $RAM_MB"
QEMU_ARGS="$QEMU_ARGS -boot $BOOT_DEVICE"

# OpenFirmware settings to speed up boot and reduce visual noise
QEMU_ARGS="$QEMU_ARGS -prom-env 'auto-boot?=true'"
QEMU_ARGS="$QEMU_ARGS -prom-env 'boot-command=mac-boot'"
QEMU_ARGS="$QEMU_ARGS -prom-env 'diag-switch?=false'"

# IDE drive index counter
IDE_INDEX=0

# Primary disk on IDE0 (required for Mac OS to boot properly)
if [ -n "$PRIMARY_DISK" ] && [ -f "$MACEMU_DIR/disk/$PRIMARY_DISK" ]; then
    QEMU_ARGS="$QEMU_ARGS -drive file=$MACEMU_DIR/disk/$PRIMARY_DISK,format=qcow2,media=disk,if=ide,index=$IDE_INDEX"
    IDE_INDEX=$((IDE_INDEX + 1))
fi

# Secondary disk (optional) on next IDE index
if [ -n "$SECONDARY_DISK" ] && [ -f "$MACEMU_DIR/disk/$SECONDARY_DISK" ]; then
    QEMU_ARGS="$QEMU_ARGS -drive file=$MACEMU_DIR/disk/$SECONDARY_DISK,format=qcow2,media=disk,if=ide,index=$IDE_INDEX"
    IDE_INDEX=$((IDE_INDEX + 1))
fi

# CD-ROM ISO on next available IDE index
# Note: For Mac OS 9 installation, CD-ROM typically needs to be on IDE1
if [ -n "$CDROM_ISO" ] && [ -f "$MACEMU_DIR/iso/$CDROM_ISO" ]; then
    # If no hard disk, CD-ROM goes on IDE0; otherwise use current index
    QEMU_ARGS="$QEMU_ARGS -drive file=$MACEMU_DIR/iso/$CDROM_ISO,format=raw,media=cdrom,if=ide,index=$IDE_INDEX"
fi
QEMU_ARGS="$QEMU_ARGS -device usb-mouse -device usb-kbd"
QEMU_ARGS="$QEMU_ARGS -vnc :$VNC_DISPLAY"
QEMU_ARGS="$QEMU_ARGS -monitor unix:/tmp/qemu-monitor.sock,server,nowait"
QEMU_ARGS="$QEMU_ARGS -serial null"
QEMU_ARGS="$QEMU_ARGS -g ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x32"

# Note: QEMU mac99 uses built-in OpenBIOS, no external ROM needed
# The classic Mac ROM files are for SheepShaver/Basilisk, not QEMU

# Sound configuration
if [ "$SOUND_ENABLED" = "1" ]; then
    QEMU_ARGS="$QEMU_ARGS -audiodev pa,id=snd0 -device screamer,audiodev=snd0"
fi

# Display configuration - use GTK for X11 display with zoom-to-fit
if [ -n "$DISPLAY" ]; then
    # GTK with zoom-to-fit scales the display properly
    QEMU_ARGS="$QEMU_ARGS -display gtk,zoom-to-fit=on,full-screen=on,grab-on-hover=on"
else
    # No X display, use VNC only
    QEMU_ARGS="$QEMU_ARGS -display none"
fi

echo "Starting QEMU with: $QEMU_CMD $QEMU_ARGS"
exec $QEMU_CMD $QEMU_ARGS
