#!/bin/bash
# Test hardware video decoding on Raspberry Pi 5

set -e

VIDEO_FILE="$1"

if [ -z "$VIDEO_FILE" ]; then
    echo "Usage: $0 <video-file>"
    echo ""
    echo "Tests hardware HEVC decoding on Raspberry Pi 5"
    exit 1
fi

if [ ! -f "$VIDEO_FILE" ]; then
    echo "Error: File not found: $VIDEO_FILE"
    exit 1
fi

echo "=== Testing Hardware Decode ==="
echo "File: $VIDEO_FILE"
echo ""

# Check video codec
echo "--- Video Info ---"
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 "$VIDEO_FILE"
echo ""

CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$VIDEO_FILE")
echo "Detected codec: $CODEC"
echo ""

if [ "$CODEC" = "hevc" ] || [ "$CODEC" = "h265" ]; then
    echo "--- Testing HEVC Hardware Decode ---"
    echo "Running: ffmpeg -v verbose -hwaccel drm -i $VIDEO_FILE -f null -"
    echo ""

    # Run decode test and capture output
    OUTPUT=$(ffmpeg -v verbose -hwaccel drm -i "$VIDEO_FILE" -t 5 -f null - 2>&1)

    if echo "$OUTPUT" | grep -qi "hwaccel.*hevc\|V4L2 HEVC"; then
        echo "SUCCESS: Hardware HEVC decode is working!"
        echo ""
        echo "Relevant output:"
        echo "$OUTPUT" | grep -i "hwaccel\|hevc\|v4l2" | head -5
    else
        echo "WARNING: Hardware decode may not be active"
        echo "Check output for details"
    fi
else
    echo "--- Testing Software Decode (non-HEVC) ---"
    echo "Note: Pi 5 only has hardware HEVC decode."
    echo "H.264 uses software decode (CPU). This is fine for 1080p."
    echo ""
    echo "Running decode test..."
    ffmpeg -v error -i "$VIDEO_FILE" -t 5 -f null - 2>&1
    echo "Decode test completed."
fi

echo ""
echo "--- Playback Test ---"
echo "Testing playback with mpv (5 seconds)..."
echo "Command: mpv --hwdec=drm --length=5 $VIDEO_FILE"
echo ""
mpv --hwdec=drm --length=5 --vo=drm "$VIDEO_FILE" 2>&1 || true

echo ""
echo "=== Test Complete ==="
