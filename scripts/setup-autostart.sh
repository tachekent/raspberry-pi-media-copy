#!/bin/bash
# Configure a Pi for headless autostart.
# Run once on each Pi after copying the project.
# Usage: ./scripts/setup-autostart.sh [master|slave]

set -euo pipefail

ROLE="${1:-}"
if [ "$ROLE" != "master" ] && [ "$ROLE" != "slave" ]; then
    echo "Usage: $0 [master|slave]"
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEMD_DIR=/etc/systemd/system

echo "=== Setting up Pi Video Sync ($ROLE) ==="

# 1. Create config.env if missing
if [ ! -f "$INSTALL_DIR/config.env" ]; then
    cp "$INSTALL_DIR/config.env.example" "$INSTALL_DIR/config.env"
    echo "Created config.env — edit VIDEO, DURATION, and SERVER_IP before rebooting."
fi

# 2. Make scripts executable
chmod +x "$INSTALL_DIR/scripts/"*.sh

# 3. Install PTP service
if [ "$ROLE" = "master" ]; then
    sudo cp "$INSTALL_DIR/systemd/ptp-master.service" "$SYSTEMD_DIR/"
    sudo systemctl enable ptp-master.service
else
    sudo cp "$INSTALL_DIR/systemd/ptp-slave.service" "$SYSTEMD_DIR/"
    sudo systemctl enable ptp-slave.service
fi

# 4. Launch client via .bash_profile on tty1 autologin.
#    This gives the process a logind seat → DRM master access → hwdec=drm works.
#    A systemd service lacks a seat, so hwdec fails there.
if systemctl is-enabled sync-client.service &>/dev/null 2>&1; then
    sudo systemctl disable --now sync-client.service 2>/dev/null || true
    echo "Disabled sync-client.service (replaced by .bash_profile autostart)"
fi

# Write the autostart helper (always overwritten so re-running setup picks up changes)
cat > "$INSTALL_DIR/autostart-client.sh" <<BASHEOF
#!/bin/bash
if [ "\$(tty)" = "/dev/tty1" ]; then
    mkdir -p $INSTALL_DIR/logs
    source $INSTALL_DIR/config.env
    exec /usr/local/bin/python3 $INSTALL_DIR/controller/client.py --server "\$SERVER_IP" \\
        >> $INSTALL_DIR/logs/client.log 2>&1
fi
BASHEOF
chmod +x "$INSTALL_DIR/autostart-client.sh"

# Add a single source line to .bash_profile (idempotent)
BASH_PROFILE="$HOME/.bash_profile"
MARKER="# pi-video-sync client autostart"
if ! grep -qF "$MARKER" "$BASH_PROFILE" 2>/dev/null; then
    cat >> "$BASH_PROFILE" <<BASHEOF

$MARKER
source $INSTALL_DIR/autostart-client.sh
BASHEOF
    echo "Added client autostart to $BASH_PROFILE"
else
    echo "Client autostart already in $BASH_PROFILE (skipping)"
fi

# 5. Master-only: sync server + autoplay trigger
if [ "$ROLE" = "master" ]; then
    sudo cp "$INSTALL_DIR/systemd/sync-server.service" "$SYSTEMD_DIR/"
    sudo cp "$INSTALL_DIR/systemd/sync-autoplay.service" "$SYSTEMD_DIR/"
    sudo systemctl enable sync-server.service
    sudo systemctl enable sync-autoplay.service
fi

# 6. Boot to console (no desktop)
echo "Configuring headless boot..."
sudo systemctl set-default multi-user.target

# 7. Autologin for pipe user on tty1 (needed for DRM display access)
sudo mkdir -p "$SYSTEMD_DIR/getty@tty1.service.d"
sudo tee "$SYSTEMD_DIR/getty@tty1.service.d/autologin.conf" > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pipe --noclear %I \$TERM
EOF

sudo systemctl daemon-reload

echo ""
echo "=== Done ==="
echo "Before rebooting, edit: $INSTALL_DIR/config.env"
echo "  - Set VIDEO to the full path of your video file"
echo "  - Set DURATION to the video length in seconds"
if [ "$ROLE" = "slave" ]; then
    echo "  - Set SERVER_IP to the master Pi's IP address"
fi
echo ""
echo "Then reboot: sudo reboot"
