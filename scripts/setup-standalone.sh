#!/bin/bash
# Configure a standalone Pi that just loops one video, with no other Pi to
# stay in sync with. Run once, after ./scripts/install-deps.sh.
#
# Deliberately does NOT touch: chrony/PTP (nothing to clock-sync against),
# NetworkManager/static IPs (no other Pi to reach), tty1 autologin (a bare
# systemd service is simpler and sufficient — see standalone-video.service
# for why). install-deps.sh still installs chrony as shared infra; it's just
# never configured or used here, which is harmless.
#
# Usage: ./scripts/setup-standalone.sh

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEMD_DIR=/etc/systemd/system

echo "=== Setting up standalone video loop ==="

# 1. Create standalone.env if missing
if [ ! -f "$INSTALL_DIR/standalone.env" ]; then
    cp "$INSTALL_DIR/standalone.env.example" "$INSTALL_DIR/standalone.env"
    echo "Created standalone.env — edit VIDEO before starting the service."
fi

# 2. Make scripts executable
chmod +x "$INSTALL_DIR/scripts/"*.sh

# 3. Enable audio. PipeWire is installed but never starts headless — it's
#    designed to launch inside a desktop login session, which never happens
#    on a headless boot. wireplumber (the session/policy manager that
#    actually discovers ALSA hardware and creates sink nodes) is the piece
#    that's normally missing; once it runs, mpv's default AO probe (pipewire
#    first) just works. Note this mpv build has no ALSA output compiled in
#    at all (libasound2-dev was never in install-deps.sh), so --ao=alsa is
#    not a fallback option here.
sudo loginctl enable-linger pipe
systemctl --user enable pipewire.service pipewire.socket wireplumber.service pipewire-pulse.service pipewire-pulse.socket

# 3b. Bluetooth audio output (optional — harmless if never used). Two gotchas
# found the hard way pairing a real speaker against this exact setup:
#  - libspa-0.2-bluetooth (PipeWire's A2DP plugin) is in install-deps.sh now,
#    but wasn't historically — without it, pairing succeeds but connect()
#    fails with br-connection-profile-unavailable (nothing registers an
#    audio profile with bluetoothd for it to hand the connection to).
#  - WirePlumber's bluez monitor gates on monitor.bluez.seat-monitoring,
#    which requires a real logind *seat* — a lingering-but-never-logged-in
#    background session (this whole setup) has no seat, so the monitor loads
#    but silently never enumerates the adapter. Disabled here the same way
#    WirePlumber's own "main-systemwide" profile mixin does for exactly this
#    class of headless setup. (pi1/pi2's tty1-autologin setup likely doesn't
#    need this — a real console autologin gets an actual seat0 — untested.)
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/51-headless-bluetooth.conf > /dev/null <<'EOF'
wireplumber.profiles = {
  main = {
    monitor.bluez.seat-monitoring = disabled
    support.logind = disabled
  }
}
EOF

systemctl --user start pipewire wireplumber pipewire-pulse 2>/dev/null || true

# 4. Install and enable the playback service
sudo cp "$INSTALL_DIR/systemd/standalone-video.service" "$SYSTEMD_DIR/"
sudo systemctl daemon-reload
sudo systemctl enable standalone-video.service

# 5. Bluetooth auto-reconnect (best-effort, only does anything if
#    BLUETOOTH_MAC is set in standalone.env — see that file for how to pair
#    a device first). Doesn't block playback; see bluetooth-reconnect.sh.
sudo cp "$INSTALL_DIR/systemd/bluetooth-reconnect.service" "$SYSTEMD_DIR/"
sudo systemctl daemon-reload
sudo systemctl enable bluetooth-reconnect.service

echo ""
echo "=== Done ==="
echo "Before starting, edit: $INSTALL_DIR/standalone.env"
echo "  - Set VIDEO to the full path of your video file"
echo ""
echo "Then either reboot, or start now: sudo systemctl start standalone-video.service"
echo "Check it's running: systemctl status standalone-video.service"
echo "Logs: $INSTALL_DIR/logs/mpv.log"
