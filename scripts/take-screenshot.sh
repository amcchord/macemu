#!/bin/bash
# Take screenshot via VNC

SCREENSHOT_DIR="/opt/macemu/screenshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="$SCREENSHOT_DIR/screenshot_$TIMESTAMP.png"
LATEST_FILE="$SCREENSHOT_DIR/latest.png"

# Use QEMU monitor to take screenshot
echo "screendump /tmp/qemu_screen.ppm" | socat - UNIX-CONNECT:/tmp/qemu-monitor.sock 2>/dev/null

# Wait a moment for the file to be written
sleep 0.5

# Convert PPM to PNG if the file exists
if [ -f "/tmp/qemu_screen.ppm" ]; then
    convert "/tmp/qemu_screen.ppm" "$OUTPUT_FILE"
    cp "$OUTPUT_FILE" "$LATEST_FILE"
    rm -f "/tmp/qemu_screen.ppm"
    echo "$OUTPUT_FILE"
else
    echo "ERROR: Could not capture screenshot"
    exit 1
fi
