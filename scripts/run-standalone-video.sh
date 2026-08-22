#!/bin/bash
# Launches mpv looping a single video file forever. No sync client, no IPC
# socket, no drift correction — there's nothing else to stay in sync with on
# a standalone Pi. Invoked by systemd/standalone-video.service.
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$INSTALL_DIR/standalone.env"; set +a

mkdir -p "$INSTALL_DIR/logs"

cmd=(
    /usr/local/bin/mpv
    --hwdec=drm-copy
    --vo=drm
    --video-sync=display-resample
    --fullscreen
    --no-terminal
    --no-input-terminal
    --no-input-default-bindings
    --log-file="$INSTALL_DIR/logs/mpv.log"
    --loop
)

if [ -n "${DRM_MODE:-}" ]; then
    cmd+=(--drm-mode="$DRM_MODE")
fi

cmd+=("$VIDEO")

exec "${cmd[@]}"
