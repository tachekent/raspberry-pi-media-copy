#!/bin/bash
# Generate a drift test video for checking playback sync across multiple screens.
#
# Visual elements:
#   - CORNERS: Black/white panels (top-left & top-right) that toggle at 2 Hz.
#              In sync: both screens' corners match. 1 frame off: clearly mismatched.
#   - BACKGROUND: Horizontal stripes scrolling upward (slide rule effect).
#                 Phase offset between screens = visible stripe misalignment.
#   - SECOND FLASH: Full-screen brightness spike for ~3 frames at each second boundary.
#   - TIMECODE: HH:MM:SS center display.
#   - FRAME: Frame number so you can count exact drift.
#
# Usage: ./make_drift_test.sh [output.mp4] [duration_seconds]
#   Default: drift_test.mp4, 600 seconds (10 min)

set -euo pipefail

OUTPUT="${1:-drift_test.mp4}"
DURATION="${2:-600}"
FPS=30
W=1920
H=1080

# Corner box dimensions
CW=280
CH=200
# Stripe height (px) and scroll speed (px/s).
# At 120px/s and 25px stripes: 1-frame drift = 4px = 16% of a stripe — clearly visible.
STRIPE_H=25
SPEED=120

echo "Generating: $OUTPUT  (${DURATION}s @ ${FPS}fps ${W}x${H})"
echo "  Stripe speed ${SPEED}px/s → 1-frame drift = $((SPEED / FPS))px"

# ffmpeg expression note: use * for AND, + for OR (mutually exclusive terms).
# Inside geq lum='...', commas are literal — no \, needed.
# Corners: lt(X,CW)*lt(Y,CH)=top-left,  gt(X,W-CW)*lt(Y,CH)=top-right
CORNER="lt(X,${CW})*lt(Y,${CH})+gt(X,W-${CW})*lt(Y,${CH})"
LUM="if(${CORNER},255*mod(floor(T*2),2),180*mod(floor((Y+T*${SPEED})/${STRIPE_H}+100000),2)+75*lt(mod(T,1),0.1))"

VF="geq=lum='${LUM}':cb=128:cr=128"
VF+=",drawtext=fontsize=140:text='%{pts\:hms}':fontcolor=white:x=(w-tw)/2:y=(h-th)/2-50:box=1:boxcolor=black@0.65:boxborderw=14"
VF+=",drawtext=fontsize=65:text='Frame %{n}':fontcolor=yellow:x=(w-tw)/2:y=(h-th)/2+100:box=1:boxcolor=black@0.6:boxborderw=8"
VF+=",drawtext=fontsize=26:text='DRIFT TEST  |  ${FPS}fps  |  ${SPEED}px\\/s stripes  |  1 frame = $((SPEED / FPS))px':fontcolor=0x888888:x=(w-tw)/2:y=h-44"

ffmpeg -y \
  -f lavfi -i "color=c=0x1a1a1a:size=${W}x${H}:rate=${FPS}" \
  -vf "$VF" \
  -t "$DURATION" \
  -c:v libx265 -crf 24 -preset fast -pix_fmt yuv420p \
  "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo ""
echo "Done: $OUTPUT  ($SIZE)"
echo ""
echo "How to read drift:"
echo "  Corners  — 2 Hz toggle; in sync = corners on both screens match simultaneously"
echo "  Stripes  — slide rule; ${STRIPE_H}px bands @ ${SPEED}px/s; 1-frame drift = $((SPEED / FPS))px stripe offset"
echo "  Flash    — ~3-frame white pulse each second; staggered pulses = desync"
echo "  Timecode — read exact offset in seconds"
echo "  Frame #  — count exact frame drift"
