#!/bin/bash
# Start PTP slave on this Pi
# This Pi will sync its clock to the master

set -e

INTERFACE="${1:-eth0}"

echo "=== Starting PTP Slave on $INTERFACE ==="

# Check if already running
if systemctl is-active --quiet ptp-slave 2>/dev/null; then
    echo "PTP slave service already running"
    echo "Use: sudo systemctl status ptp-slave"
    exit 0
fi

# Kill any existing ptp4l/phc2sys processes
sudo pkill ptp4l 2>/dev/null || true
sudo pkill phc2sys 2>/dev/null || true
sleep 1

echo "Starting ptp4l (PTP daemon)..."
# Start ptp4l as slave
# --slaveOnly 1: Always act as slave
# -m: Print messages to stdout
# --tx_timestamp_timeout 200: Timeout for TX timestamps (Pi 5 needs this)
sudo ptp4l -i "$INTERFACE" --slaveOnly 1 -m --tx_timestamp_timeout 200 &
PTP4L_PID=$!

sleep 2

echo "Starting phc2sys (sync system clock to PTP clock)..."
# Sync system clock to PTP hardware clock
# -s eth0: Source is PTP clock on eth0
# -c CLOCK_REALTIME: Target is system clock
# -O 0: No offset
# -m: Print messages
# -w: Wait for ptp4l to sync before starting
sudo phc2sys -s "$INTERFACE" -c CLOCK_REALTIME -O 0 -m -w &
PHC2SYS_PID=$!

echo ""
echo "=== PTP Slave Running ==="
echo "ptp4l PID: $PTP4L_PID"
echo "phc2sys PID: $PHC2SYS_PID"
echo ""
echo "Watch for:"
echo "  - 's2' state (locked to master)"
echo "  - 'master offset' values close to 0 (in nanoseconds)"
echo ""
echo "Press Ctrl+C to stop."
echo ""

# Wait for interrupt
wait
