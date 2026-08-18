#!/bin/bash
# Install dependencies for Pi Video Sync on Raspberry Pi 5 (Pi OS Trixie)
# Run on each Pi before setup-autostart.sh
# Builds mpv from source against the Pi OS rpt1 ffmpeg — this is what enables
# --hwdec=drm-copy (V4L2 HEVC stateless via /dev/media2 + /dev/video19).

set -euo pipefail

MPV_VERSION="0.40.0"
MPV_BIN="/usr/local/bin/mpv"

echo "=== Pi Video Sync: Installing Dependencies ==="

# Update package list
echo "Updating package list..."
sudo apt update

# PTP tools
echo "Installing PTP tools..."
sudo apt install -y linuxptp ethtool

# Python
sudo apt install -y python3-full

# rpt1 ffmpeg dev headers + mpv build deps
# Pi OS ships rpt1 ffmpeg (with V4L2 HEVC stateless support) in the RPi archive.
# We install the headers so mpv picks them up at build time.
echo "Installing ffmpeg and build dependencies..."
sudo apt install -y \
    ffmpeg \
    libavcodec-dev libavformat-dev libavutil-dev \
    libswscale-dev libswresample-dev libavfilter-dev \
    meson ninja-build pkg-config git \
    libdrm-dev libv4l-dev \
    libass-dev libfreetype-dev libfontconfig-dev \
    libzimg-dev \
    libjpeg-dev zlib1g-dev \
    libvulkan-dev

# Add user to video + render groups (required for DRM master access on tty1)
sudo usermod -aG video,render "$USER"

# Build mpv from source
if [ -f "$MPV_BIN" ] && "$MPV_BIN" --version 2>/dev/null | grep -q "$MPV_VERSION"; then
    echo "mpv $MPV_VERSION already at $MPV_BIN — skipping build"
else
    echo "Building mpv $MPV_VERSION from source (takes ~10 min on Pi 5)..."
    BUILD_DIR=$(mktemp -d)
    trap "rm -rf '$BUILD_DIR'" EXIT

    git clone --depth=1 --branch "v$MPV_VERSION" https://github.com/mpv-player/mpv.git "$BUILD_DIR/mpv"
    (
        cd "$BUILD_DIR/mpv"
        meson setup build --prefix=/usr/local
        ninja -C build
        sudo ninja -C build install
    )
    echo "mpv $MPV_VERSION installed to $MPV_BIN"
fi

# Verify
echo ""
echo "=== Verifying ==="
echo -n "ptp4l:   "; ptp4l -v 2>&1 | head -1 || echo "NOT FOUND"
echo -n "phc2sys: "; which phc2sys || echo "NOT FOUND"
echo -n "ffmpeg:  "; ffmpeg -version 2>&1 | head -1 || echo "NOT FOUND"
echo -n "mpv:     "; "$MPV_BIN" --version 2>&1 | head -1 || echo "NOT FOUND"

echo ""
echo "=== Checking HEVC decoder ==="
if [ -e /dev/video19 ] && [ -e /dev/media2 ]; then
    echo "Decoder devices present: /dev/video19, /dev/media2"
else
    echo "Decoder devices not found — may appear after first playback (loads on demand)"
    echo "If missing after reboot: sudo modprobe rpi-hevc-dec"
fi

echo ""
echo "=== Checking PTP hardware support ==="
if ethtool -T eth0 2>/dev/null | grep -q "hardware-transmit"; then
    echo "PTP hardware timestamping: SUPPORTED"
else
    echo "PTP hardware timestamping: NOT DETECTED — use ethernet, not WiFi"
fi

echo ""
echo "=== Done ==="
echo "Next: edit config.env, then run ./scripts/setup-autostart.sh [master|slave]"
