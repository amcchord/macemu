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
