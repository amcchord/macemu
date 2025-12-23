#!/usr/bin/env python3
"""
Smart Splash Overlay for Mac OS 9 Emulator
Monitors VNC to detect when OpenFirmware yellow screen passes
"""

import tkinter as tk
import threading
import subprocess
import time
import signal
import sys
import os

class SmartSplash:
    def __init__(self):
        self.root = tk.Tk()
        self.running = True
        self.yellow_detected = False
        self.mac_boot_detected = False
        
        # Setup fullscreen grey window
        self.root.attributes('-fullscreen', True)
        self.root.attributes('-topmost', True)
        self.root.configure(bg='#BDBDBD')
        self.root.overrideredirect(True)
        
        w = self.root.winfo_screenwidth()
        h = self.root.winfo_screenheight()
        self.root.geometry(f"{w}x{h}+0+0")
        
        # Keep on top
        self.lift_count = 0
        self.keep_on_top()
        
        # Start VNC monitoring thread
        self.monitor_thread = threading.Thread(target=self.monitor_vnc, daemon=True)
        self.monitor_thread.start()
        
        # Safety timeout - close after 20 seconds max
        self.root.after(20000, self.close)
        
        # Handle signals
        signal.signal(signal.SIGTERM, lambda s,f: self.close())
        signal.signal(signal.SIGINT, lambda s,f: self.close())
        
        self.root.mainloop()
    
    def keep_on_top(self):
        """Keep window on top during QEMU startup"""
        if self.running and self.lift_count < 100:
            try:
                self.root.lift()
                self.root.attributes('-topmost', True)
                self.lift_count += 1
                self.root.after(100, self.keep_on_top)
            except:
                pass
    
    def analyze_screenshot(self, ppm_path):
        """Analyze PPM screenshot for dominant colors"""
        try:
            # Read PPM file and analyze colors
            with open(ppm_path, 'rb') as f:
                # Skip PPM header
                header = f.readline()  # P6
                
                # Skip comments
                line = f.readline()
                while line.startswith(b'#'):
                    line = f.readline()
                
                # Get dimensions
                dims = line.decode().strip().split()
                width, height = int(dims[0]), int(dims[1])
                
                # Skip max value line
                f.readline()
                
                # Read pixel data (sample every 100th pixel for speed)
                pixel_data = f.read()
                
                yellow_count = 0
                grey_count = 0
                black_count = 0
                total_samples = 0
                
                # Sample pixels across the image
                step = max(3, len(pixel_data) // 3000) * 3  # Sample ~1000 pixels
                for i in range(0, len(pixel_data) - 2, step):
                    r, g, b = pixel_data[i], pixel_data[i+1], pixel_data[i+2]
                    total_samples += 1
                    
                    # Detect LIGHT yellow (OpenFirmware): high R, high G, lower B
                    # Light yellow: R and G are high (>200), B is noticeably lower
                    # Examples: (255,255,150), (240,240,180), (255,250,200)
                    is_yellow = False
                    if r > 200 and g > 200 and b < 220:
                        # Check if it's yellowish (R and G similar, B lower)
                        if b < r - 20 or b < g - 20:
                            is_yellow = True
                    # Also catch tan/beige shades
                    if r > 180 and g > 160 and b < 160 and r > b + 30:
                        is_yellow = True
                    
                    if is_yellow:
                        yellow_count += 1
                    # Detect Mac grey (boot screen): R≈G≈B around 170-210 (classic Mac grey is ~189)
                    elif abs(r - g) < 20 and abs(g - b) < 20 and 165 < r < 215:
                        grey_count += 1
                    # Detect white/light (Happy Mac icon area)
                    elif r > 230 and g > 230 and b > 230:
                        grey_count += 1
                    # Detect black/dark (loading or "NO DISPLAY" text on black)
                    elif r < 60 and g < 60 and b < 60:
                        black_count += 1
                
                if total_samples > 0:
                    yellow_pct = (yellow_count / total_samples) * 100
                    grey_pct = (grey_count / total_samples) * 100
                    black_pct = (black_count / total_samples) * 100
                    return yellow_pct, grey_pct, black_pct
                    
        except Exception as e:
            pass
        
        return 0, 0, 0
    
    def monitor_vnc(self):
        """Monitor VNC screenshots to detect when to close splash"""
        screenshot_path = '/tmp/splash_check.ppm'
        
        # Wait for QEMU to start
        time.sleep(2)
        
        check_count = 0
        yellow_seen = False
        post_yellow_frames = 0
        
        while self.running and check_count < 80:  # Max 20 seconds of checking (at 0.25s intervals)
            try:
                # Take screenshot via QEMU monitor
                result = subprocess.run(
                    ['socat', '-', 'UNIX-CONNECT:/tmp/qemu-monitor.sock'],
                    input=f'screendump {screenshot_path}\n',
                    capture_output=True,
                    text=True,
                    timeout=2
                )
                
                time.sleep(0.3)  # Wait for file to be written
                
                if os.path.exists(screenshot_path):
                    yellow_pct, grey_pct, black_pct = self.analyze_screenshot(screenshot_path)
                    
                    # Log for debugging
                    print(f"Frame {check_count}: Yellow={yellow_pct:.1f}% Grey={grey_pct:.1f}% Black={black_pct:.1f}%")
                    
                    # Detect yellow/tan screen (OpenFirmware)
                    if yellow_pct > 20:
                        yellow_seen = True
                        post_yellow_frames = 0
                        print(f"  -> Yellow/OpenFirmware detected!")
                    
                    # After seeing yellow, wait for it to go away
                    elif yellow_seen and yellow_pct < 10:
                        post_yellow_frames += 1
                        
                        # If yellow is gone for 2 consecutive frames, Mac is booting
                        if post_yellow_frames >= 2:
                            print("Yellow screen passed - Mac OS booting!")
                            time.sleep(0.3)
                            self.schedule_close()
                            return
                    
                    # Detect Mac grey boot screen (Happy Mac)
                    if grey_pct > 50:
                        print(f"  -> Mac grey screen detected!")
                        # Wait 1 more frame to confirm
                        time.sleep(0.5)
                        self.schedule_close()
                        return
                    
                    # Safety: if we've been checking for 10+ seconds and see no yellow
                    # close anyway (might have missed yellow or it's hidden)
                    if check_count > 40 and not yellow_seen:
                        print("Timeout waiting for yellow - closing splash")
                        self.schedule_close()
                        return
                    
                    # Cleanup
                    try:
                        os.remove(screenshot_path)
                    except:
                        pass
                        
            except Exception as e:
                print(f"Monitor error: {e}")
            
            check_count += 1
            time.sleep(0.25)  # Check 4 times per second to catch brief screens
        
        # Timeout - close anyway
        print("Monitor timeout - closing splash")
        self.schedule_close()
    
    def schedule_close(self):
        """Schedule close on main thread"""
        if self.running:
            self.root.after(100, self.close)
    
    def close(self):
        """Close the splash window"""
        self.running = False
        try:
            self.root.quit()
            self.root.destroy()
        except:
            pass
        sys.exit(0)


if __name__ == '__main__':
    try:
        SmartSplash()
    except Exception as e:
        print(f"SmartSplash error: {e}")
        sys.exit(1)

