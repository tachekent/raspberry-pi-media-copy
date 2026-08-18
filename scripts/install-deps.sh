#!/bin/bash
# Install dependencies for Pi Video Sync
# Run on each Raspberry Pi 5

set -e

echo "=== Pi Video Sync: Installing Dependencies ==="

# Update package list
echo "Updating package list..."
if ! sudo apt update; then
    echo "ERROR: apt update failed — check your internet connection and try again."
    exit 1
fi

# Install PTP tools
echo "Installing PTP tools..."
sudo apt install -y linuxptp

# Install video players
echo "Installing video players..."
sudo apt install -y ffmpeg mpv

# Install Python dependencies
echo "Installing Python dependencies..."
sudo apt install -y python3-full

# Verify installations
echo ""
echo "=== Verifying installations ==="

echo -n "ptp4l: "
which ptp4l && ptp4l -v 2>&1 | head -1 || echo "NOT FOUND"

echo -n "phc2sys: "
which phc2sys || echo "NOT FOUND"

echo -n "ffmpeg: "
ffmpeg -version 2>&1 | head -1 || echo "NOT FOUND"

echo -n "mpv: "
mpv --version 2>&1 | head -1 || echo "NOT FOUND"

# Check for HEVC hardware decoder
echo ""
echo "=== Checking hardware decoder ==="
if lsmod | grep -q rpi_hevc_dec; then
    echo "HEVC hardware decoder: LOADED"
else
    echo "HEVC hardware decoder: NOT LOADED"
    echo "This may be normal - it loads on demand"
fi

# Check PTP hardware timestamping support
echo ""
echo "=== Checking PTP hardware support ==="
if ethtool -T eth0 2>/dev/null | grep -q "hardware-transmit"; then
    echo "PTP hardware timestamping: SUPPORTED"
else
    echo "PTP hardware timestamping: NOT DETECTED"
    echo "Make sure you're using the ethernet port (not WiFi)"
fi

echo ""
echo "=== Installation complete ==="
echo "Next steps:"
echo "  - On master Pi: ./scripts/ptp-master.sh"
echo "  - On slave Pis: ./scripts/ptp-slave.sh"
