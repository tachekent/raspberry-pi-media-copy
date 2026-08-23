#!/bin/bash
# Best-effort reconnect to a paired Bluetooth audio device on boot. Doesn't
# gate video playback — runs independently; if it fails or the device isn't
# powered on yet, mpv keeps playing and audio just isn't routed until this
# (or a later manual retry) succeeds. Pairing/trust itself already persists
# via bluetoothd's own state (/var/lib/bluetooth/) — this only handles the
# "nobody's around to click reconnect after a power cycle" part.
set -u

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$INSTALL_DIR/standalone.env" 2>/dev/null || true; set +a

if [ -z "${BLUETOOTH_MAC:-}" ]; then
    echo "BLUETOOTH_MAC not set in standalone.env — nothing to reconnect."
    exit 0
fi

for i in $(seq 1 10); do
    if bluetoothctl info "$BLUETOOTH_MAC" 2>/dev/null | grep -q "Connected: yes"; then
        echo "Already connected to $BLUETOOTH_MAC"
        exit 0
    fi
    echo "Reconnect attempt $i/10 to $BLUETOOTH_MAC..."
    bluetoothctl connect "$BLUETOOTH_MAC" && exit 0
    sleep 5
done

echo "Gave up reconnecting to $BLUETOOTH_MAC after 10 attempts — playback continues without it."
exit 0
