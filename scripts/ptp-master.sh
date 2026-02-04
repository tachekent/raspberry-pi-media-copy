#!/bin/bash
# Start PTP master on this Pi
# This Pi will be the time reference for all others

set -e

INTERFACE="${1:-eth0}"

echo "=== Starting PTP Master on $INTERFACE ==="

# Check if already running
if systemctl is-active --quiet ptp-master 2>/dev/null; then
    echo "PTP master service already running"
    echo "Use: sudo systemctl status ptp-master"
    exit 0
fi

# Kill any existing ptp4l/phc2sys processes
sudo pkill ptp4l 2>/dev/null || true
sudo pkill phc2sys 2>/dev/null || true
sleep 1

echo "Starting ptp4l (PTP daemon)..."
# Start ptp4l as master
# --masterOnly 1: Always act as master
# -m: Print messages to stdout
# --tx_timestamp_timeout 200: Timeout for TX timestamps (Pi 5 needs this)
sudo ptp4l -i "$INTERFACE" --masterOnly 1 -m --tx_timestamp_timeout 200 &
PTP4L_PID=$!

sleep 2

echo "Starting phc2sys (sync system clock to PTP clock)..."
# Sync system clock to PTP hardware clock
# -s eth0: Source is PTP clock on eth0
# -c CLOCK_REALTIME: Target is system clock
# -O 0: No offset (both clocks use same epoch)
# -m: Print messages
# -w: Wait for ptp4l to sync before starting
sudo phc2sys -s "$INTERFACE" -c CLOCK_REALTIME -O 0 -m -w &
PHC2SYS_PID=$!

echo ""
echo "=== PTP Master Running ==="
echo "ptp4l PID: $PTP4L_PID"
echo "phc2sys PID: $PHC2SYS_PID"
echo ""
echo "Watch for 'master offset' values near 0 in the output above."
echo "Press Ctrl+C to stop."
echo ""

# Wait for interrupt
wait
