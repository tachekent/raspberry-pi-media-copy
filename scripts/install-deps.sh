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

# Clock sync + network tools
echo "Installing chrony and network tools..."
sudo apt install -y chrony ethtool

# Python
sudo apt install -y python3-full

# rpt1 ffmpeg dev headers + mpv build deps
#
# Pi OS ships rpt1 ffmpeg (with V4L2 HEVC stateless support) via the RPi apt archive.
# We build mpv from source so it links against these headers — the apt mpv package
# does not correctly pick up --hwdec=drm-copy against rpt1 ffmpeg.
echo "Installing ffmpeg and build dependencies..."

# Core ffmpeg dev headers (picks up rpt1 build with V4L2 HEVC stateless support)
sudo apt install -y ffmpeg \
    libavcodec-dev libavformat-dev libavutil-dev \
    libswscale-dev libswresample-dev libavfilter-dev

# Build toolchain
sudo apt install -y meson ninja-build pkg-config git

# DRM + EGL: libdrm for KMS/DRM API; libgbm/libegl/libgles for GBM buffer management
# and EGL context creation — required for --vo=drm with DRM+EGL output path
sudo apt install -y libdrm-dev libgbm-dev libegl1-mesa-dev libgles2-mesa-dev libv4l-dev

# libdisplay-info: hard dep when meson is invoked with -Ddrm=enabled — provides
# EDID/HDR display metadata parsing. Build fails without it.
sudo apt install -y libdisplay-info-dev

# Subtitles + font rendering
sudo apt install -y libass-dev libfreetype-dev libfontconfig-dev

# libzimg: software scaler used when display output resolution != video resolution
sudo apt install -y libzimg-dev libuchardet-dev libjpeg-dev zlib1g-dev

# Vulkan (optional but expected by mpv 0.40.0 at configure time)
sudo apt install -y libvulkan-dev

# libplacebo: hard dep in mpv 0.40.0 — not optional even if you never use gpu-next VO
sudo apt install -y libplacebo-dev

# liblua5.2-dev — mpv requires Lua < 5.3. liblua5.4-dev is silently rejected at build
# time (mpv checks the version and skips it). Without any Lua, the osc.lua script
# fails to load and mpv exits with "option not found" on some flag combinations.
sudo apt install -y liblua5.2-dev

# Audio: needed at build time for audio driver detection even though audio is unused
# on a headless Pi (no PipeWire/PulseAudio session in multi-user.target)
sudo apt install -y libpipewire-0.3-dev libpulse-dev

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
        # -Ddrm=enabled is mandatory: without it, --vo=drm is silently excluded from the
        # build even when libdrm is installed. There is no warning — it just won't work.
        meson setup build --prefix=/usr/local -Ddrm=enabled
        ninja -C build
        sudo ninja -C build install
    )
    echo "mpv $MPV_VERSION installed to $MPV_BIN"
fi

# Verify
echo ""
echo "=== Verifying ==="
echo -n "chrony:  "; chronyd --version 2>&1 | head -1 || echo "NOT FOUND"
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
echo "=== Done ==="
echo "Next: edit config.env, then run ./scripts/setup-autostart.sh [master|slave]"
