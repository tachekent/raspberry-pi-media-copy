#!/bin/bash
# Persistent watcher: keep a paired Bluetooth audio device reconnected for
# the whole uptime, not just once at boot. Doesn't gate video playback —
# runs independently; if the device is off or unreachable, mpv/Kodi keep
# playing and audio just isn't routed until this reconnects it. Pairing/
# trust itself already persists via bluetoothd's own state
# (/var/lib/bluetooth/) — this only handles noticing a later disconnect
# (e.g. someone turns the soundbar off, then back on) and reconnecting
# without anyone needing to be there to click it.
set -u

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# standalone.env on a standalone Pi (pi3's original setup); config.env on a
# sync-fleet Pi (pi1/pi2) — BLUETOOTH_MAC can live in whichever this board
# actually uses. Both are sourced (harmless if one doesn't exist) so this
# script works unmodified on either kind of deployment.
set -a
source "$INSTALL_DIR/standalone.env" 2>/dev/null || true
source "$INSTALL_DIR/config.env" 2>/dev/null || true
set +a

if [ -z "${BLUETOOTH_MAC:-}" ]; then
    echo "BLUETOOTH_MAC not set in standalone.env or config.env — nothing to reconnect."
    exit 0
fi

CHECK_INTERVAL="${BLUETOOTH_RECONNECT_INTERVAL:-15}"  # seconds between connection checks

echo "Watching $BLUETOOTH_MAC — checking every ${CHECK_INTERVAL}s, reconnecting on disconnect."

while true; do
    if bluetoothctl info "$BLUETOOTH_MAC" 2>/dev/null | grep -q "Connected: yes"; then
        sleep "$CHECK_INTERVAL"
        continue
    fi
    echo "Not connected to $BLUETOOTH_MAC — attempting reconnect..."
    if bluetoothctl connect "$BLUETOOTH_MAC"; then
        echo "Reconnected to $BLUETOOTH_MAC"
    fi
    sleep "$CHECK_INTERVAL"
done
