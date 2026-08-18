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

echo "Starting phc2sys (sync PTP hardware clock from system clock)..."
# On the master, sync the PHC *from* the system clock (not the other way around).
# The system clock is the reference; ptp4l then distributes the PHC time to slaves.
# -s CLOCK_REALTIME: Source is system clock
# -c eth0: Target is PTP hardware clock on eth0
# -O 0: No offset
# -m: Print messages
sudo phc2sys -s CLOCK_REALTIME -c "$INTERFACE" -O 0 -m &
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
