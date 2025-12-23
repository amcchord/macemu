#!/usr/bin/env python3
"""
Mac OS 9 Emulator Web Interface
Enhanced with disk and USB management
"""

import os
import subprocess
import glob
import json
import re
from flask import Flask, render_template, request, redirect, url_for, jsonify, send_file

app = Flask(__name__)

MACEMU_DIR = "/opt/macemu"
CONFIG_FILE = f"{MACEMU_DIR}/config/qemu.conf"
SCREENSHOT_DIR = f"{MACEMU_DIR}/screenshots"
DISK_DIR = f"{MACEMU_DIR}/disk"
ISO_DIR = f"{MACEMU_DIR}/iso"
EMU_SCRIPT = f"{MACEMU_DIR}/scripts/start-emulator.sh"
SCREENSHOT_SCRIPT = f"{MACEMU_DIR}/scripts/take-screenshot.sh"
CONTROL_SCRIPT = f"{MACEMU_DIR}/scripts/emu-control.sh"
QEMU_MONITOR = "/tmp/qemu-monitor.sock"

def read_config():
    """Read the QEMU configuration file"""
    config = {
        'RAM_MB': '512',
        'BOOT_DEVICE': 'd',
        'SCREEN_WIDTH': '1024',
        'SCREEN_HEIGHT': '768',
        'VNC_DISPLAY': '0',
        'SOUND_ENABLED': '0',
        'PRIMARY_DISK': 'macos9.qcow2',
        'SECONDARY_DISK': '',
        'CDROM_ISO': 'macos_921_ppc.iso'
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
        f.write(f"SOUND_ENABLED={config.get('SOUND_ENABLED', '0')}\n\n")
        f.write(f"# Disk configuration\n")
        f.write(f"PRIMARY_DISK={config.get('PRIMARY_DISK', 'macos9.qcow2')}\n")
        f.write(f"SECONDARY_DISK={config.get('SECONDARY_DISK', '')}\n")
        f.write(f"CDROM_ISO={config.get('CDROM_ISO', 'macos_921_ppc.iso')}\n")

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

def send_monitor_command(cmd):
    """Send a command to QEMU monitor"""
    try:
        result = subprocess.run(
            ['socat', '-', f'UNIX-CONNECT:{QEMU_MONITOR}'],
            input=cmd + '\n',
            capture_output=True,
            text=True,
            timeout=5
        )
        return result.stdout
    except Exception as e:
        return str(e)

def get_disk_list():
    """Get list of disk images"""
    disks = []
    for ext in ['*.qcow2', '*.img', '*.raw']:
        for path in glob.glob(os.path.join(DISK_DIR, ext)):
            name = os.path.basename(path)
            size_bytes = os.path.getsize(path)
            # Get virtual size for qcow2
            virtual_size = "Unknown"
            if path.endswith('.qcow2'):
                try:
                    result = subprocess.run(['qemu-img', 'info', '--output=json', path],
                                          capture_output=True, text=True)
                    info = json.loads(result.stdout)
                    virtual_size = format_size(info.get('virtual-size', 0))
                except:
                    pass
            disks.append({
                'name': name,
                'path': path,
                'actual_size': format_size(size_bytes),
                'virtual_size': virtual_size
            })
    return disks

def get_iso_list():
    """Get list of ISO images"""
    isos = []
    for path in glob.glob(os.path.join(ISO_DIR, '*.iso')):
        name = os.path.basename(path)
        size_bytes = os.path.getsize(path)
        isos.append({
            'name': name,
            'path': path,
            'size': format_size(size_bytes)
        })
    return isos

def get_usb_devices():
    """Get list of USB devices on the host"""
    devices = []
    try:
        result = subprocess.run(['lsusb'], capture_output=True, text=True)
        for line in result.stdout.strip().split('\n'):
            if line:
                # Parse: Bus 001 Device 002: ID 0a5c:4500 Broadcom Corp. BCM2046B1
                match = re.match(r'Bus (\d+) Device (\d+): ID ([0-9a-f:]+) (.+)', line)
                if match:
                    bus, device, usb_id, name = match.groups()
                    vendor_id, product_id = usb_id.split(':')
                    devices.append({
                        'bus': bus,
                        'device': device,
                        'vendor_id': vendor_id,
                        'product_id': product_id,
                        'name': name.strip(),
                        'id': usb_id
                    })
    except Exception as e:
        pass
    return devices

def format_size(bytes):
    """Format bytes to human readable size"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes < 1024:
            return f"{bytes:.1f} {unit}"
        bytes /= 1024
    return f"{bytes:.1f} PB"

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
            'SOUND_ENABLED': request.form.get('sound_enabled', '0'),
            'PRIMARY_DISK': request.form.get('primary_disk', 'macos9.qcow2'),
            'SECONDARY_DISK': request.form.get('secondary_disk', ''),
            'CDROM_ISO': request.form.get('cdrom_iso', '')
        }
        write_config(config)
        return redirect(url_for('config_page', saved=1))
    
    config = read_config()
    saved = request.args.get('saved', False)
    disks = get_disk_list()
    isos = get_iso_list()
    return render_template('config.html', config=config, saved=saved, disks=disks, isos=isos)

@app.route('/disks', methods=['GET'])
def disks_page():
    """Disk management page"""
    disks = get_disk_list()
    config = read_config()
    return render_template('disks.html', disks=disks, config=config)

@app.route('/usb', methods=['GET'])
def usb_page():
    """USB management page"""
    devices = get_usb_devices()
    running = is_emulator_running()
    return render_template('usb.html', devices=devices, running=running)

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
        subprocess.run(['systemctl', 'restart', 'getty@tty1.service'], 
                      capture_output=True, timeout=30)
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# Disk Management API
@app.route('/api/disks', methods=['GET'])
def api_disks_list():
    """List all disk images"""
    return jsonify({'disks': get_disk_list()})

@app.route('/api/disks/create', methods=['POST'])
def api_disks_create():
    """Create a new disk image"""
    data = request.get_json()
    name = data.get('name', '').strip()
    size = data.get('size', '10G').strip()
    
    if not name:
        return jsonify({'success': False, 'error': 'Disk name required'}), 400
    
    # Sanitize filename
    if not name.endswith('.qcow2'):
        name = name + '.qcow2'
    name = re.sub(r'[^a-zA-Z0-9._-]', '', name)
    
    disk_path = os.path.join(DISK_DIR, name)
    
    if os.path.exists(disk_path):
        return jsonify({'success': False, 'error': 'Disk already exists'}), 400
    
    try:
        result = subprocess.run(
            ['qemu-img', 'create', '-f', 'qcow2', disk_path, size],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            os.chown(disk_path, 1001, 1001)  # macemu user
            return jsonify({'success': True, 'name': name})
        else:
            return jsonify({'success': False, 'error': result.stderr})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/disks/delete', methods=['POST'])
def api_disks_delete():
    """Delete a disk image"""
    data = request.get_json()
    name = data.get('name', '').strip()
    
    if not name:
        return jsonify({'success': False, 'error': 'Disk name required'}), 400
    
    disk_path = os.path.join(DISK_DIR, name)
    
    if not os.path.exists(disk_path):
        return jsonify({'success': False, 'error': 'Disk not found'}), 404
    
    # Check if disk is in use
    config = read_config()
    if name == config.get('PRIMARY_DISK') or name == config.get('SECONDARY_DISK'):
        return jsonify({'success': False, 'error': 'Cannot delete disk that is currently configured'}), 400
    
    try:
        os.remove(disk_path)
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/disks/resize', methods=['POST'])
def api_disks_resize():
    """Resize a disk image"""
    data = request.get_json()
    name = data.get('name', '').strip()
    size = data.get('size', '').strip()
    
    if not name or not size:
        return jsonify({'success': False, 'error': 'Disk name and size required'}), 400
    
    disk_path = os.path.join(DISK_DIR, name)
    
    if not os.path.exists(disk_path):
        return jsonify({'success': False, 'error': 'Disk not found'}), 404
    
    try:
        result = subprocess.run(
            ['qemu-img', 'resize', disk_path, size],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return jsonify({'success': True})
        else:
            return jsonify({'success': False, 'error': result.stderr})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# USB Management API
@app.route('/api/usb', methods=['GET'])
def api_usb_list():
    """List available USB devices"""
    return jsonify({'devices': get_usb_devices()})

@app.route('/api/usb/attach', methods=['POST'])
def api_usb_attach():
    """Attach a USB device to the emulator"""
    if not is_emulator_running():
        return jsonify({'success': False, 'error': 'Emulator not running'}), 400
    
    data = request.get_json()
    vendor_id = data.get('vendor_id', '').strip()
    product_id = data.get('product_id', '').strip()
    
    if not vendor_id or not product_id:
        return jsonify({'success': False, 'error': 'Vendor and product ID required'}), 400
    
    try:
        cmd = f"device_add usb-host,vendorid=0x{vendor_id},productid=0x{product_id},id=usbdev_{vendor_id}_{product_id}"
        output = send_monitor_command(cmd)
        return jsonify({'success': True, 'output': output})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/usb/detach', methods=['POST'])
def api_usb_detach():
    """Detach a USB device from the emulator"""
    if not is_emulator_running():
        return jsonify({'success': False, 'error': 'Emulator not running'}), 400
    
    data = request.get_json()
    vendor_id = data.get('vendor_id', '').strip()
    product_id = data.get('product_id', '').strip()
    
    if not vendor_id or not product_id:
        return jsonify({'success': False, 'error': 'Vendor and product ID required'}), 400
    
    try:
        cmd = f"device_del usbdev_{vendor_id}_{product_id}"
        output = send_monitor_command(cmd)
        return jsonify({'success': True, 'output': output})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/iso', methods=['GET'])
def api_iso_list():
    """List available ISO images"""
    return jsonify({'isos': get_iso_list()})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)
