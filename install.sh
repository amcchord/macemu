#!/bin/bash
#
# Mac OS 9 Emulation System Installer
# Idempotent installation script for Debian
#
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
MACEMU_DIR="/opt/macemu"
MACEMU_USER="macemu"
ISO_URL="https://mcchord.net/static/macos_921_ppc.iso"
ROM_URL="https://archive.org/download/mac_rom_archive_-_as_of_8-19-2011/mac_rom_archive_-_as_of_8-19-2011.zip"
DISK_SIZE="10G"
DEFAULT_RAM="512"

# ============================================================================
# SECTION 1: Package Installation
# ============================================================================
install_packages() {
    log_info "Installing required packages..."
    
    # Update package lists
    apt-get update
    
    # Install packages - apt-get install is idempotent
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qemu-system-ppc \
        xorg \
        openbox \
        plymouth \
        plymouth-themes \
        python3-flask \
        python3-pillow \
        unzip \
        wget \
        curl \
        xinit \
        x11-xserver-utils \
        xdotool \
        netpbm \
        imagemagick \
        sudo
    
    log_info "Packages installed successfully"
}

# ============================================================================
# SECTION 2: Create macemu user
# ============================================================================
create_user() {
    log_info "Setting up macemu user..."
    
    if id "$MACEMU_USER" &>/dev/null; then
        log_info "User $MACEMU_USER already exists"
    else
        useradd -m -s /bin/bash "$MACEMU_USER"
        log_info "Created user $MACEMU_USER"
    fi
    
    # Add user to necessary groups
    usermod -aG video,audio,input,tty "$MACEMU_USER" 2>/dev/null || true
    
    # Allow macemu user to start X
    if ! grep -q "allowed_users=anybody" /etc/X11/Xwrapper.config 2>/dev/null; then
        mkdir -p /etc/X11
        echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
        echo "needs_root_rights=yes" >> /etc/X11/Xwrapper.config
    fi
    
    log_info "User configuration complete"
}

# ============================================================================
# SECTION 3: Create directory structure
# ============================================================================
create_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "$MACEMU_DIR/iso"
    mkdir -p "$MACEMU_DIR/rom"
    mkdir -p "$MACEMU_DIR/disk"
    mkdir -p "$MACEMU_DIR/config"
    mkdir -p "$MACEMU_DIR/web/templates"
    mkdir -p "$MACEMU_DIR/web/static"
    mkdir -p "$MACEMU_DIR/scripts"
    mkdir -p "$MACEMU_DIR/screenshots"
    
    chown -R "$MACEMU_USER:$MACEMU_USER" "$MACEMU_DIR"
    
    log_info "Directory structure created"
}

# ============================================================================
# SECTION 4: Download Mac OS 9 ISO
# ============================================================================
download_iso() {
    log_info "Checking Mac OS 9 ISO..."
    
    ISO_PATH="$MACEMU_DIR/iso/macos_921_ppc.iso"
    
    if [ -f "$ISO_PATH" ]; then
        log_info "ISO already exists at $ISO_PATH"
    else
        log_info "Downloading Mac OS 9.2.1 ISO..."
        wget -O "$ISO_PATH" "$ISO_URL"
        chown "$MACEMU_USER:$MACEMU_USER" "$ISO_PATH"
        log_info "ISO downloaded successfully"
    fi
}

# ============================================================================
# SECTION 5: Download and extract ROM files
# ============================================================================
download_rom() {
    log_info "Checking ROM files..."
    
    ROM_ZIP="$MACEMU_DIR/rom/mac_roms.zip"
    ROM_DIR="$MACEMU_DIR/rom"
    
    # Check if we already have a usable ROM
    if [ -f "$ROM_DIR/mac99.rom" ]; then
        log_info "ROM already configured"
        return
    fi
    
    # Download ROM archive if not present
    if [ ! -f "$ROM_ZIP" ]; then
        log_info "Downloading ROM archive..."
        wget -O "$ROM_ZIP" "$ROM_URL"
    fi
    
    # Extract ROMs
    log_info "Extracting ROM files..."
    cd "$ROM_DIR"
    unzip -o "$ROM_ZIP" || true
    
    # Find a suitable New World ROM for mac99
    # The mac99 machine needs a New World ROM (like from iMac, Blue G3, etc.)
    # Look for common New World ROM files
    ROM_FOUND=""
    
    # Search for ROM files - look for Power Mac G3 ROMs specifically for mac99
    # New World ROMs are typically 1MB (1048576 bytes) or 4MB (4194304 bytes)
    for rom_file in "$ROM_DIR"/*G3*.ROM "$ROM_DIR"/*G3*.rom "$ROM_DIR"/*Power*.ROM "$ROM_DIR"/*Power*.rom; do
        if [ -f "$rom_file" ]; then
            size=$(stat -c%s "$rom_file" 2>/dev/null || echo "0")
            if [ "$size" -ge 1000000 ] && [ "$size" -le 5000000 ]; then
                ROM_FOUND="$rom_file"
                log_info "Found potential ROM: $rom_file (size: $size bytes)"
                break
            fi
        fi
    done
    
    # If no G3 ROM found, look for any large ROM file
    if [ -z "$ROM_FOUND" ]; then
        for rom_file in "$ROM_DIR"/*.ROM "$ROM_DIR"/*.rom; do
            if [ -f "$rom_file" ]; then
                size=$(stat -c%s "$rom_file" 2>/dev/null || echo "0")
                if [ "$size" -ge 1000000 ] && [ "$size" -le 5000000 ]; then
                    ROM_FOUND="$rom_file"
                    log_info "Found potential ROM: $rom_file (size: $size bytes)"
                    break
                fi
            fi
        done
    fi
    
    if [ -n "$ROM_FOUND" ]; then
        cp "$ROM_FOUND" "$ROM_DIR/mac99.rom"
        log_info "ROM configured: $ROM_DIR/mac99.rom"
    else
        # List what we have for debugging
        log_warn "Could not auto-detect ROM. Available files:"
        find "$ROM_DIR" -type f -ls 2>/dev/null | head -20
        # Create a placeholder - QEMU mac99 might work without explicit ROM
        log_warn "Will attempt to run without explicit ROM file"
    fi
    
    chown -R "$MACEMU_USER:$MACEMU_USER" "$ROM_DIR"
}

# ============================================================================
# SECTION 6: Create virtual disk
# ============================================================================
create_virtual_disk() {
    log_info "Checking virtual disk..."
    
    DISK_PATH="$MACEMU_DIR/disk/macos9.qcow2"
    
    if [ -f "$DISK_PATH" ]; then
        log_info "Virtual disk already exists"
    else
        log_info "Creating $DISK_SIZE virtual disk..."
        qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
        chown "$MACEMU_USER:$MACEMU_USER" "$DISK_PATH"
        log_info "Virtual disk created"
    fi
}

# ============================================================================
# SECTION 7: Create QEMU configuration
# ============================================================================
create_qemu_config() {
    log_info "Creating QEMU configuration..."
    
    CONFIG_FILE="$MACEMU_DIR/config/qemu.conf"
    
    cat > "$CONFIG_FILE" << 'EOF'
# Mac OS 9 QEMU Configuration
# Edit these values and restart the emulator

# Memory in MB (128-1024 recommended)
RAM_MB=512

# Boot device: d=cdrom, c=hard disk
# Use 'd' for initial install, then 'c' after installation
BOOT_DEVICE=d

# Display resolution
SCREEN_WIDTH=1024
SCREEN_HEIGHT=768

# VNC display number (for screenshots)
VNC_DISPLAY=0

# Enable sound (0=disabled, 1=enabled)
SOUND_ENABLED=0
EOF
    
    chown "$MACEMU_USER:$MACEMU_USER" "$CONFIG_FILE"
    log_info "QEMU configuration created"
}

# ============================================================================
# SECTION 8: Create emulator launch script
# ============================================================================
create_emulator_scripts() {
    log_info "Creating emulator scripts..."
    
    # Main emulator start script
    cat > "$MACEMU_DIR/scripts/start-emulator.sh" << 'EOF'
#!/bin/bash
# Start Mac OS 9 Emulator

MACEMU_DIR="/opt/macemu"
CONFIG_FILE="$MACEMU_DIR/config/qemu.conf"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Defaults
    RAM_MB=512
    BOOT_DEVICE=d
    SCREEN_WIDTH=1024
    SCREEN_HEIGHT=768
    VNC_DISPLAY=0
    SOUND_ENABLED=0
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
QEMU_ARGS="$QEMU_ARGS -drive file=$MACEMU_DIR/disk/macos9.qcow2,format=qcow2,media=disk"
QEMU_ARGS="$QEMU_ARGS -drive file=$MACEMU_DIR/iso/macos_921_ppc.iso,format=raw,media=cdrom"
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
EOF
    
    chmod +x "$MACEMU_DIR/scripts/start-emulator.sh"
    
    # Screenshot script
    cat > "$MACEMU_DIR/scripts/take-screenshot.sh" << 'EOF'
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
EOF
    
    chmod +x "$MACEMU_DIR/scripts/take-screenshot.sh"
    
    # Emulator control script
    cat > "$MACEMU_DIR/scripts/emu-control.sh" << 'EOF'
#!/bin/bash
# Control the emulator

SOCKET="/tmp/qemu-monitor.sock"

send_command() {
    echo "$1" | socat - UNIX-CONNECT:$SOCKET 2>/dev/null
}

case "$1" in
    stop)
        send_command "quit"
        ;;
    reset)
        send_command "system_reset"
        ;;
    pause)
        send_command "stop"
        ;;
    resume)
        send_command "cont"
        ;;
    status)
        send_command "info status"
        ;;
    *)
        echo "Usage: $0 {stop|reset|pause|resume|status}"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$MACEMU_DIR/scripts/emu-control.sh"
    chown -R "$MACEMU_USER:$MACEMU_USER" "$MACEMU_DIR/scripts"
    
    log_info "Emulator scripts created"
}

# ============================================================================
# SECTION 9: Create Flask web interface
# ============================================================================
create_web_interface() {
    log_info "Creating web interface..."
    
    # Main Flask application
    cat > "$MACEMU_DIR/web/app.py" << 'FLASK_APP'
#!/usr/bin/env python3
"""
Mac OS 9 Emulator Web Interface
"""

import os
import subprocess
import signal
import json
from flask import Flask, render_template, request, redirect, url_for, jsonify, send_file

app = Flask(__name__)

MACEMU_DIR = "/opt/macemu"
CONFIG_FILE = f"{MACEMU_DIR}/config/qemu.conf"
SCREENSHOT_DIR = f"{MACEMU_DIR}/screenshots"
EMU_SCRIPT = f"{MACEMU_DIR}/scripts/start-emulator.sh"
SCREENSHOT_SCRIPT = f"{MACEMU_DIR}/scripts/take-screenshot.sh"
CONTROL_SCRIPT = f"{MACEMU_DIR}/scripts/emu-control.sh"

def read_config():
    """Read the QEMU configuration file"""
    config = {
        'RAM_MB': '512',
        'BOOT_DEVICE': 'd',
        'SCREEN_WIDTH': '1024',
        'SCREEN_HEIGHT': '768',
        'VNC_DISPLAY': '0',
        'SOUND_ENABLED': '0'
    }
    
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()
    
    return config

def write_config(config):
    """Write the QEMU configuration file"""
    with open(CONFIG_FILE, 'w') as f:
        f.write("# Mac OS 9 QEMU Configuration\n")
        f.write("# Edit these values and restart the emulator\n\n")
        f.write(f"# Memory in MB (128-1024 recommended)\n")
        f.write(f"RAM_MB={config.get('RAM_MB', '512')}\n\n")
        f.write(f"# Boot device: d=cdrom, c=hard disk\n")
        f.write(f"BOOT_DEVICE={config.get('BOOT_DEVICE', 'd')}\n\n")
        f.write(f"# Display resolution\n")
        f.write(f"SCREEN_WIDTH={config.get('SCREEN_WIDTH', '1024')}\n")
        f.write(f"SCREEN_HEIGHT={config.get('SCREEN_HEIGHT', '768')}\n\n")
        f.write(f"# VNC display number\n")
        f.write(f"VNC_DISPLAY={config.get('VNC_DISPLAY', '0')}\n\n")
        f.write(f"# Sound (0=disabled, 1=enabled)\n")
        f.write(f"SOUND_ENABLED={config.get('SOUND_ENABLED', '0')}\n")

def is_emulator_running():
    """Check if the emulator is running"""
    try:
        result = subprocess.run(['pgrep', '-f', 'qemu-system-ppc'], 
                              capture_output=True, text=True)
        return result.returncode == 0
    except Exception:
        return False

def get_emulator_pid():
    """Get the PID of the running emulator"""
    try:
        result = subprocess.run(['pgrep', '-f', 'qemu-system-ppc'], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip().split('\n')[0]
    except Exception:
        pass
    return None

@app.route('/')
def index():
    """Main dashboard"""
    config = read_config()
    running = is_emulator_running()
    return render_template('index.html', config=config, running=running)

@app.route('/config', methods=['GET', 'POST'])
def config_page():
    """Configuration page"""
    if request.method == 'POST':
        config = {
            'RAM_MB': request.form.get('ram_mb', '512'),
            'BOOT_DEVICE': request.form.get('boot_device', 'd'),
            'SCREEN_WIDTH': request.form.get('screen_width', '1024'),
            'SCREEN_HEIGHT': request.form.get('screen_height', '768'),
            'VNC_DISPLAY': request.form.get('vnc_display', '0'),
            'SOUND_ENABLED': request.form.get('sound_enabled', '0')
        }
        write_config(config)
        return redirect(url_for('config_page', saved=1))
    
    config = read_config()
    saved = request.args.get('saved', False)
    return render_template('config.html', config=config, saved=saved)

@app.route('/screenshot')
def screenshot():
    """Take and display a screenshot"""
    return render_template('screenshot.html')

@app.route('/api/screenshot', methods=['POST'])
def api_screenshot():
    """API endpoint to take a screenshot"""
    try:
        result = subprocess.run([SCREENSHOT_SCRIPT], 
                              capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return jsonify({'success': True, 'file': result.stdout.strip()})
        else:
            return jsonify({'success': False, 'error': result.stderr})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/screenshot/latest')
def api_screenshot_latest():
    """Get the latest screenshot"""
    latest = f"{SCREENSHOT_DIR}/latest.png"
    if os.path.exists(latest):
        return send_file(latest, mimetype='image/png')
    else:
        return jsonify({'error': 'No screenshot available'}), 404

@app.route('/api/status')
def api_status():
    """Get emulator status"""
    running = is_emulator_running()
    pid = get_emulator_pid() if running else None
    config = read_config()
    return jsonify({
        'running': running,
        'pid': pid,
        'config': config
    })

@app.route('/api/control/<action>', methods=['POST'])
def api_control(action):
    """Control the emulator"""
    valid_actions = ['stop', 'reset', 'pause', 'resume']
    if action not in valid_actions:
        return jsonify({'success': False, 'error': 'Invalid action'}), 400
    
    try:
        result = subprocess.run([CONTROL_SCRIPT, action], 
                              capture_output=True, text=True, timeout=10)
        return jsonify({'success': True, 'output': result.stdout})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/restart', methods=['POST'])
def api_restart():
    """Restart the emulator service"""
    try:
        subprocess.run(['systemctl', 'restart', 'macemu-display'], 
                      capture_output=True, timeout=30)
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)
FLASK_APP
    
    # HTML Templates
    cat > "$MACEMU_DIR/web/templates/base.html" << 'HTML_BASE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}Mac OS 9 Emulator{% endblock %}</title>
    <style>
        :root {
            --mac-grey: #BDBDBD;
            --mac-dark: #666666;
            --mac-light: #E8E8E8;
            --mac-blue: #3366CC;
            --mac-border: #999999;
        }
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        
        body {
            font-family: "Chicago", "Charcoal", "Helvetica Neue", Helvetica, Arial, sans-serif;
            background: linear-gradient(180deg, var(--mac-grey) 0%, var(--mac-light) 100%);
            min-height: 100vh;
            color: #000;
        }
        
        .container {
            max-width: 900px;
            margin: 0 auto;
            padding: 20px;
        }
        
        header {
            background: linear-gradient(180deg, #FFFFFF 0%, var(--mac-grey) 100%);
            border: 2px solid var(--mac-border);
            border-radius: 8px 8px 0 0;
            padding: 10px 20px;
            margin-bottom: 0;
            box-shadow: inset 0 1px 0 #fff;
        }
        
        header h1 {
            font-size: 14px;
            font-weight: bold;
            text-align: center;
            text-shadow: 1px 1px 0 #fff;
        }
        
        .window {
            background: var(--mac-light);
            border: 2px solid var(--mac-border);
            border-top: none;
            border-radius: 0 0 8px 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 2px 2px 10px rgba(0,0,0,0.3);
        }
        
        nav {
            margin-bottom: 20px;
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }
        
        nav a, .btn {
            display: inline-block;
            padding: 8px 16px;
            background: linear-gradient(180deg, #FFFFFF 0%, var(--mac-grey) 100%);
            border: 2px solid var(--mac-border);
            border-radius: 6px;
            color: #000;
            text-decoration: none;
            font-size: 12px;
            font-weight: bold;
            cursor: pointer;
            box-shadow: inset 0 1px 0 #fff;
        }
        
        nav a:hover, .btn:hover {
            background: linear-gradient(180deg, #FFFFFF 0%, #CCCCCC 100%);
        }
        
        nav a:active, .btn:active {
            background: linear-gradient(180deg, var(--mac-grey) 0%, #FFFFFF 100%);
            box-shadow: inset 0 2px 4px rgba(0,0,0,0.2);
        }
        
        nav a.active {
            background: var(--mac-blue);
            color: #fff;
            border-color: #2255AA;
        }
        
        .btn-danger {
            background: linear-gradient(180deg, #FF6666 0%, #CC3333 100%);
            color: #fff;
            border-color: #AA2222;
        }
        
        .btn-success {
            background: linear-gradient(180deg, #66CC66 0%, #33AA33 100%);
            color: #fff;
            border-color: #228822;
        }
        
        .status-indicator {
            display: inline-block;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            margin-right: 8px;
            border: 1px solid #666;
        }
        
        .status-running {
            background: #33CC33;
            box-shadow: 0 0 6px #33CC33;
        }
        
        .status-stopped {
            background: #CC3333;
        }
        
        .form-group {
            margin-bottom: 15px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
            font-size: 12px;
        }
        
        .form-group input, .form-group select {
            width: 100%;
            max-width: 300px;
            padding: 8px;
            border: 2px solid var(--mac-border);
            border-radius: 4px;
            font-size: 12px;
            background: #fff;
        }
        
        .form-group input:focus, .form-group select:focus {
            outline: none;
            border-color: var(--mac-blue);
        }
        
        .alert {
            padding: 12px;
            border-radius: 6px;
            margin-bottom: 15px;
            border: 2px solid;
        }
        
        .alert-success {
            background: #D4EDDA;
            border-color: #28A745;
            color: #155724;
        }
        
        .alert-error {
            background: #F8D7DA;
            border-color: #DC3545;
            color: #721C24;
        }
        
        .screenshot-container {
            background: #000;
            border: 3px solid var(--mac-dark);
            border-radius: 8px;
            padding: 10px;
            text-align: center;
        }
        
        .screenshot-container img {
            max-width: 100%;
            height: auto;
            border: 1px solid #333;
        }
        
        .info-box {
            background: #fff;
            border: 2px solid var(--mac-border);
            border-radius: 6px;
            padding: 15px;
            margin-bottom: 15px;
        }
        
        .info-box h3 {
            font-size: 12px;
            margin-bottom: 10px;
            padding-bottom: 5px;
            border-bottom: 1px solid var(--mac-border);
        }
        
        .info-row {
            display: flex;
            justify-content: space-between;
            padding: 5px 0;
            font-size: 12px;
        }
        
        .controls {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
            margin-top: 15px;
        }
        
        footer {
            text-align: center;
            padding: 20px;
            font-size: 11px;
            color: var(--mac-dark);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🖥️ Mac OS 9 Emulator Control Panel</h1>
        </header>
        <div class="window">
            <nav>
                <a href="/" class="{% if request.endpoint == 'index' %}active{% endif %}">Dashboard</a>
                <a href="/config" class="{% if request.endpoint == 'config_page' %}active{% endif %}">Configuration</a>
                <a href="/screenshot" class="{% if request.endpoint == 'screenshot' %}active{% endif %}">Screenshot</a>
            </nav>
            
            {% block content %}{% endblock %}
        </div>
        <footer>
            Mac OS 9 Emulator Control Panel • QEMU PPC
        </footer>
    </div>
    {% block scripts %}{% endblock %}
</body>
</html>
HTML_BASE

    cat > "$MACEMU_DIR/web/templates/index.html" << 'HTML_INDEX'
{% extends "base.html" %}

{% block title %}Dashboard - Mac OS 9 Emulator{% endblock %}

{% block content %}
<h2 style="font-size: 14px; margin-bottom: 15px;">System Status</h2>

<div class="info-box">
    <h3>Emulator Status</h3>
    <div class="info-row">
        <span>Status:</span>
        <span>
            <span class="status-indicator {% if running %}status-running{% else %}status-stopped{% endif %}"></span>
            {% if running %}Running{% else %}Stopped{% endif %}
        </span>
    </div>
    <div class="info-row">
        <span>Memory:</span>
        <span>{{ config.RAM_MB }} MB</span>
    </div>
    <div class="info-row">
        <span>Boot Device:</span>
        <span>{% if config.BOOT_DEVICE == 'd' %}CD-ROM{% else %}Hard Disk{% endif %}</span>
    </div>
    <div class="info-row">
        <span>Resolution:</span>
        <span>{{ config.SCREEN_WIDTH }}x{{ config.SCREEN_HEIGHT }}</span>
    </div>
</div>

<div class="controls">
    {% if running %}
        <button class="btn btn-danger" onclick="controlEmulator('stop')">Stop Emulator</button>
        <button class="btn" onclick="controlEmulator('reset')">Reset</button>
        <button class="btn" onclick="controlEmulator('pause')">Pause</button>
        <button class="btn" onclick="controlEmulator('resume')">Resume</button>
    {% else %}
        <button class="btn btn-success" onclick="restartEmulator()">Start Emulator</button>
    {% endif %}
    <button class="btn" onclick="location.reload()">Refresh Status</button>
</div>

<div class="info-box" style="margin-top: 20px;">
    <h3>Quick Info</h3>
    <p style="font-size: 12px; line-height: 1.6;">
        This control panel allows you to manage the Mac OS 9 emulator running on this system.
        Use the Configuration page to adjust RAM and boot settings.
        Use the Screenshot page to view the current display.
    </p>
    <p style="font-size: 12px; margin-top: 10px;">
        <strong>First time setup:</strong> Boot from CD-ROM to install Mac OS 9, then change boot device to Hard Disk.
    </p>
</div>

<script>
function controlEmulator(action) {
    fetch('/api/control/' + action, {method: 'POST'})
        .then(r => r.json())
        .then(data => {
            if (data.success) {
                setTimeout(() => location.reload(), 1000);
            } else {
                alert('Error: ' + data.error);
            }
        });
}

function restartEmulator() {
    fetch('/api/restart', {method: 'POST'})
        .then(r => r.json())
        .then(data => {
            if (data.success) {
                setTimeout(() => location.reload(), 3000);
            } else {
                alert('Error: ' + data.error);
            }
        });
}
</script>
{% endblock %}
HTML_INDEX

    cat > "$MACEMU_DIR/web/templates/config.html" << 'HTML_CONFIG'
{% extends "base.html" %}

{% block title %}Configuration - Mac OS 9 Emulator{% endblock %}

{% block content %}
<h2 style="font-size: 14px; margin-bottom: 15px;">Emulator Configuration</h2>

{% if saved %}
<div class="alert alert-success">
    Configuration saved successfully! Restart the emulator to apply changes.
</div>
{% endif %}

<form method="POST" action="/config">
    <div class="info-box">
        <h3>Memory Settings</h3>
        <div class="form-group">
            <label for="ram_mb">RAM (MB):</label>
            <select name="ram_mb" id="ram_mb">
                <option value="128" {% if config.RAM_MB == '128' %}selected{% endif %}>128 MB</option>
                <option value="256" {% if config.RAM_MB == '256' %}selected{% endif %}>256 MB</option>
                <option value="512" {% if config.RAM_MB == '512' %}selected{% endif %}>512 MB</option>
                <option value="768" {% if config.RAM_MB == '768' %}selected{% endif %}>768 MB</option>
                <option value="1024" {% if config.RAM_MB == '1024' %}selected{% endif %}>1024 MB</option>
            </select>
        </div>
    </div>
    
    <div class="info-box">
        <h3>Boot Settings</h3>
        <div class="form-group">
            <label for="boot_device">Boot Device:</label>
            <select name="boot_device" id="boot_device">
                <option value="d" {% if config.BOOT_DEVICE == 'd' %}selected{% endif %}>CD-ROM (for installation)</option>
                <option value="c" {% if config.BOOT_DEVICE == 'c' %}selected{% endif %}>Hard Disk (after installation)</option>
            </select>
        </div>
    </div>
    
    <div class="info-box">
        <h3>Display Settings</h3>
        <div class="form-group">
            <label for="screen_width">Screen Width:</label>
            <input type="number" name="screen_width" id="screen_width" value="{{ config.SCREEN_WIDTH }}" min="640" max="1920">
        </div>
        <div class="form-group">
            <label for="screen_height">Screen Height:</label>
            <input type="number" name="screen_height" id="screen_height" value="{{ config.SCREEN_HEIGHT }}" min="480" max="1200">
        </div>
    </div>
    
    <div class="info-box">
        <h3>Audio Settings</h3>
        <div class="form-group">
            <label for="sound_enabled">Sound:</label>
            <select name="sound_enabled" id="sound_enabled">
                <option value="0" {% if config.SOUND_ENABLED == '0' %}selected{% endif %}>Disabled</option>
                <option value="1" {% if config.SOUND_ENABLED == '1' %}selected{% endif %}>Enabled</option>
            </select>
        </div>
    </div>
    
    <input type="hidden" name="vnc_display" value="{{ config.VNC_DISPLAY }}">
    
    <div class="controls">
        <button type="submit" class="btn btn-success">Save Configuration</button>
        <a href="/config" class="btn">Reset</a>
    </div>
</form>
{% endblock %}
HTML_CONFIG

    cat > "$MACEMU_DIR/web/templates/screenshot.html" << 'HTML_SCREENSHOT'
{% extends "base.html" %}

{% block title %}Screenshot - Mac OS 9 Emulator{% endblock %}

{% block content %}
<h2 style="font-size: 14px; margin-bottom: 15px;">Display Screenshot</h2>

<div class="controls" style="margin-bottom: 15px;">
    <button class="btn btn-success" onclick="takeScreenshot()">Take Screenshot</button>
    <button class="btn" onclick="refreshScreenshot()">Refresh</button>
</div>

<div class="screenshot-container">
    <img id="screenshot" src="/api/screenshot/latest" alt="Emulator Screenshot" 
         onerror="this.style.display='none'; document.getElementById('no-screenshot').style.display='block';">
    <p id="no-screenshot" style="color: #999; padding: 40px; display: none;">
        No screenshot available. Click "Take Screenshot" to capture the current display.
    </p>
</div>

<p style="font-size: 11px; color: #666; margin-top: 10px;">
    Screenshots are captured from the emulator's VNC display.
</p>

<script>
function takeScreenshot() {
    fetch('/api/screenshot', {method: 'POST'})
        .then(r => r.json())
        .then(data => {
            if (data.success) {
                refreshScreenshot();
            } else {
                alert('Error taking screenshot: ' + data.error);
            }
        });
}

function refreshScreenshot() {
    var img = document.getElementById('screenshot');
    img.style.display = 'block';
    document.getElementById('no-screenshot').style.display = 'none';
    img.src = '/api/screenshot/latest?' + new Date().getTime();
}
</script>
{% endblock %}
HTML_SCREENSHOT

    chown -R "$MACEMU_USER:$MACEMU_USER" "$MACEMU_DIR/web"
    chmod +x "$MACEMU_DIR/web/app.py"
    
    log_info "Web interface created"
}

# ============================================================================
# SECTION 10: Create Plymouth theme (Mac grey boot)
# ============================================================================
create_plymouth_theme() {
    log_info "Creating Plymouth boot theme..."
    
    THEME_DIR="/usr/share/plymouth/themes/macgrey"
    mkdir -p "$THEME_DIR"
    
    # Create theme script
    cat > "$THEME_DIR/macgrey.script" << 'PLYMOUTH_SCRIPT'
# Mac Grey Plymouth Theme

# Set the grey background color
Window.SetBackgroundTopColor(0.74, 0.74, 0.74);
Window.SetBackgroundBottomColor(0.74, 0.74, 0.74);

# Optional: Add a simple centered logo or message
# For now, just display a clean grey screen
message_sprite = Sprite();
message_sprite.SetPosition(Window.GetWidth() / 2, Window.GetHeight() / 2, 1);

fun message_callback(text) {
    # Suppress all messages for clean boot
}

Plymouth.SetMessageFunction(message_callback);

fun display_normal_callback() {
    # Normal boot display
}

fun display_password_callback(prompt, bullets) {
    # Password prompt (if needed)
}

Plymouth.SetDisplayNormalFunction(display_normal_callback);
Plymouth.SetDisplayPasswordFunction(display_password_callback);
PLYMOUTH_SCRIPT

    # Create theme descriptor
    cat > "$THEME_DIR/macgrey.plymouth" << 'PLYMOUTH_DESC'
[Plymouth Theme]
Name=Mac Grey
Description=Clean grey boot screen like classic Mac OS
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/macgrey
ScriptFile=/usr/share/plymouth/themes/macgrey/macgrey.script
PLYMOUTH_DESC

    # Set as default theme
    if command -v plymouth-set-default-theme &> /dev/null; then
        plymouth-set-default-theme macgrey || true
    else
        # Manual alternative
        if [ -f /etc/plymouth/plymouthd.conf ]; then
            sed -i 's/^Theme=.*/Theme=macgrey/' /etc/plymouth/plymouthd.conf
        else
            mkdir -p /etc/plymouth
            echo "[Daemon]" > /etc/plymouth/plymouthd.conf
            echo "Theme=macgrey" >> /etc/plymouth/plymouthd.conf
        fi
    fi
    
    # Update initramfs to include the theme
    update-initramfs -u || log_warn "Could not update initramfs"
    
    log_info "Plymouth theme created"
}

# ============================================================================
# SECTION 11: Configure GRUB for silent boot
# ============================================================================
configure_grub() {
    log_info "Configuring GRUB for silent boot..."
    
    GRUB_FILE="/etc/default/grub"
    
    if [ -f "$GRUB_FILE" ]; then
        # Backup original
        cp "$GRUB_FILE" "$GRUB_FILE.backup" 2>/dev/null || true
        
        # Update GRUB settings for silent boot
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$GRUB_FILE"
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash vt.global_cursor_default=0 loglevel=0"/' "$GRUB_FILE"
        
        # Add hidden timeout if not present
        if ! grep -q "GRUB_TIMEOUT_STYLE" "$GRUB_FILE"; then
            echo "GRUB_TIMEOUT_STYLE=hidden" >> "$GRUB_FILE"
        else
            sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$GRUB_FILE"
        fi
        
        # Disable recovery menu
        if ! grep -q "GRUB_DISABLE_RECOVERY" "$GRUB_FILE"; then
            echo 'GRUB_DISABLE_RECOVERY="true"' >> "$GRUB_FILE"
        fi
        
        # Set graphics mode to keep resolution through boot
        sed -i 's/^#GRUB_GFXMODE=.*/GRUB_GFXMODE=1024x768/' "$GRUB_FILE"
        if ! grep -q "GRUB_GFXMODE=" "$GRUB_FILE"; then
            echo "GRUB_GFXMODE=1024x768" >> "$GRUB_FILE"
        fi
        
        # Keep graphics payload through Linux boot
        if ! grep -q "GRUB_GFXPAYLOAD_LINUX" "$GRUB_FILE"; then
            echo "GRUB_GFXPAYLOAD_LINUX=keep" >> "$GRUB_FILE"
        fi
        
        # Update GRUB
        update-grub
        
        log_info "GRUB configured for silent boot"
    else
        log_warn "GRUB configuration file not found"
    fi
}

# ============================================================================
# SECTION 12: Configure auto-login
# ============================================================================
configure_autologin() {
    log_info "Configuring auto-login..."
    
    # Create getty override directory
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    
    # Create auto-login configuration
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $MACEMU_USER --noclear %I \$TERM
EOF
    
    # Create .bash_profile for macemu user to start X automatically
    BASH_PROFILE="/home/$MACEMU_USER/.bash_profile"
    cat > "$BASH_PROFILE" << 'EOF'
# Auto-start X on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx -- -nocursor 2>/dev/null
fi
EOF
    
    chown "$MACEMU_USER:$MACEMU_USER" "$BASH_PROFILE"
    
    log_info "Auto-login configured"
}

# ============================================================================
# SECTION 13: Configure X session
# ============================================================================
configure_xsession() {
    log_info "Configuring X session..."
    
    # Create .xinitrc for macemu user
    XINITRC="/home/$MACEMU_USER/.xinitrc"
    cat > "$XINITRC" << 'EOF'
#!/bin/bash

# Log file for debugging
exec >> /tmp/xinitrc.log 2>&1
echo "=== Starting X session at $(date) ==="

# Set grey background immediately
xsetroot -solid "#BDBDBD"

# Disable screen blanking and power management
xset s off
xset -dpms
xset s noblank

# Hide cursor after 1 second of inactivity
unclutter -idle 1 -root &

# Start a minimal window manager
openbox &
OPENBOX_PID=$!

# Wait for openbox to start
sleep 2

# Start the emulator in a loop (restart if it crashes)
while true; do
    echo "Starting emulator at $(date)"
    /opt/macemu/scripts/start-emulator.sh
    EXIT_CODE=$?
    echo "Emulator exited with code $EXIT_CODE at $(date)"
    
    # If emulator exits with 0 (user quit), break the loop
    if [ $EXIT_CODE -eq 0 ]; then
        echo "Clean exit, stopping X session"
        break
    fi
    
    # Wait a moment before restarting
    sleep 2
done

# Cleanup
kill $OPENBOX_PID 2>/dev/null
echo "=== X session ended at $(date) ==="
EOF
    
    chown "$MACEMU_USER:$MACEMU_USER" "$XINITRC"
    chmod +x "$XINITRC"
    
    # Install unclutter for hiding cursor
    apt-get install -y unclutter 2>/dev/null || true
    
    log_info "X session configured"
}

# ============================================================================
# SECTION 14: Create systemd services
# ============================================================================
create_systemd_services() {
    log_info "Creating systemd services..."
    
    # Web interface service
    cat > /etc/systemd/system/macemu-web.service << EOF
[Unit]
Description=Mac OS 9 Emulator Web Interface
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$MACEMU_DIR/web
ExecStart=/usr/bin/python3 $MACEMU_DIR/web/app.py
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start web service
    systemctl daemon-reload
    systemctl enable macemu-web.service
    systemctl start macemu-web.service || log_warn "Could not start web service"
    
    log_info "Systemd services created"
}

# ============================================================================
# SECTION 15: Install additional tools
# ============================================================================
install_additional_tools() {
    log_info "Installing additional tools..."
    
    # Install socat for QEMU monitor communication
    apt-get install -y socat || true
    
    log_info "Additional tools installed"
}

# ============================================================================
# MAIN INSTALLATION SEQUENCE
# ============================================================================
main() {
    echo "========================================"
    echo "  Mac OS 9 Emulator Installation"
    echo "========================================"
    echo ""
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Run installation steps
    install_packages
    create_user
    create_directories
    download_iso
    download_rom
    create_virtual_disk
    create_qemu_config
    create_emulator_scripts
    create_web_interface
    create_plymouth_theme
    configure_grub
    configure_autologin
    configure_xsession
    create_systemd_services
    install_additional_tools
    
    echo ""
    echo "========================================"
    log_info "Installation complete!"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "1. Reboot the system to boot into the emulator"
    echo "2. Access the web interface at http://$(hostname -I | awk '{print $1}'):5000"
    echo "3. Install Mac OS 9 from the CD-ROM"
    echo "4. After installation, change boot device to Hard Disk in the web config"
    echo ""
    echo "To test the emulator manually:"
    echo "  su - $MACEMU_USER"
    echo "  startx"
    echo ""
}

# Run main function
main "$@"

