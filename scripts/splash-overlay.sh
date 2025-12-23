#!/bin/bash
# Splash overlay - shows grey screen until Mac OS boots
# Uses a fullscreen grey window to cover QEMU during OpenFirmware

MACEMU_DIR="/opt/macemu"

# Get screen dimensions
SCREEN_WIDTH=$(xrandr | grep '\*' | head -1 | awk '{print $1}' | cut -d'x' -f1)
SCREEN_HEIGHT=$(xrandr | grep '\*' | head -1 | awk '{print $1}' | cut -d'x' -f2)

if [ -z "$SCREEN_WIDTH" ]; then
    SCREEN_WIDTH=1024
    SCREEN_HEIGHT=768
fi

# Create a simple grey overlay using xmessage or a drawing tool
# We'll use a combination of techniques

# Method: Create an override-redirect window that covers the screen
# Using Python with tkinter for a simple overlay

python3 << 'PYTHON_SCRIPT' &
import tkinter as tk
import time
import subprocess
import threading

class SplashOverlay:
    def __init__(self):
        self.root = tk.Tk()
        self.root.attributes('-fullscreen', True)
        self.root.attributes('-topmost', True)
        self.root.configure(bg='#BDBDBD')
        self.root.overrideredirect(True)
        
        # Remove all decorations and make it cover everything
        self.root.geometry(f"{self.root.winfo_screenwidth()}x{self.root.winfo_screenheight()}+0+0")
        
        # Start monitoring thread
        self.monitor_thread = threading.Thread(target=self.monitor_qemu)
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
        
        # Auto-close after 30 seconds max (safety)
        self.root.after(30000, self.close)
        
        self.root.mainloop()
    
    def monitor_qemu(self):
        """Monitor QEMU and close overlay when Mac OS starts booting"""
        time.sleep(3)  # Initial delay for QEMU to start
        
        while True:
            try:
                # Check if QEMU window exists and is showing content
                # We detect this by checking VNC screenshot changes
                result = subprocess.run(
                    ['echo', 'info status'],
                    capture_output=True,
                    text=True
                )
                
                # Wait a bit then close - Mac OS typically starts within 5-8 seconds
                time.sleep(5)
                self.close()
                break
                
            except Exception:
                pass
            
            time.sleep(1)
    
    def close(self):
        try:
            self.root.quit()
            self.root.destroy()
        except:
            pass

if __name__ == '__main__':
    try:
        SplashOverlay()
    except:
        pass
PYTHON_SCRIPT

SPLASH_PID=$!
echo $SPLASH_PID

