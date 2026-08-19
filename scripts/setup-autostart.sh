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

# 1. Create config.env if missing, then stamp ROLE into it
if [ ! -f "$INSTALL_DIR/config.env" ]; then
    cp "$INSTALL_DIR/config.env.example" "$INSTALL_DIR/config.env"
    echo "Created config.env — edit VIDEO, DURATION, and SERVER_IP before rebooting."
fi
# Write/update ROLE so autostart-client.sh knows which clock sync wait mode to use
if grep -q '^ROLE=' "$INSTALL_DIR/config.env" 2>/dev/null; then
    sed -i "s/^ROLE=.*/ROLE=$ROLE/" "$INSTALL_DIR/config.env"
else
    echo "ROLE=$ROLE" >> "$INSTALL_DIR/config.env"
fi

# Master runs server.py locally — set SERVER_IP so client.py can connect to it
if [ "$ROLE" = "master" ]; then
    if grep -q '^SERVER_IP=' "$INSTALL_DIR/config.env" 2>/dev/null; then
        sed -i "s|^SERVER_IP=.*|SERVER_IP=localhost|" "$INSTALL_DIR/config.env"
    else
        echo "SERVER_IP=localhost" >> "$INSTALL_DIR/config.env"
    fi
fi

# 2. Make scripts executable
chmod +x "$INSTALL_DIR/scripts/"*.sh

# 3. Configure chrony for clock sync.
#    master: syncs from internet NTP, serves to LAN via 'local stratum 8' fallback
#    slave:  syncs from master only (internet pool is disabled — see below)
#
#    Debian chrony.conf does not include conf.d by default — add confdir once.
#    (confdir is supported since chrony 4.2; Pi OS Trixie ships 4.6.x)
sudo mkdir -p /etc/chrony/conf.d
if ! grep -q 'confdir /etc/chrony/conf.d' /etc/chrony/chrony.conf 2>/dev/null; then
    echo 'confdir /etc/chrony/conf.d' | sudo tee -a /etc/chrony/chrony.conf > /dev/null
fi

if [ "$ROLE" = "master" ]; then
    sudo tee /etc/chrony/conf.d/pi-video-sync.conf > /dev/null <<EOF
local stratum 8
allow 192.168.0.0/8
EOF
    # Disable ptp4l if previously installed
    sudo systemctl disable --now ptp-master.service 2>/dev/null || true
else
    sudo tee /etc/chrony/conf.d/pi-video-sync.conf > /dev/null <<EOF
server pi1.local iburst prefer minpoll 2 maxpoll 4
EOF
    # Disable the default internet pool so chrony syncs from master only.
    # chrony's 'prefer' keyword doesn't override a stratum gap — internet pool
    # (stratum 1-2) beats master's local clock (stratum 8) and the slave would
    # sync from the router instead of pi1, defeating the purpose of peer sync.
    sudo sed -i 's/^pool /#pool /g' /etc/chrony/chrony.conf
    sudo sed -i 's/^server /#server /g' /etc/chrony/chrony.conf
    # Also disable DHCP-injected NTP sources — dhcpcd writes the router's NTP
    # address to /run/chrony-dhcp/ and chrony loads it via sourcedir, bypassing
    # the pool disable above.
    sudo sed -i 's|^sourcedir /run/chrony-dhcp|#sourcedir /run/chrony-dhcp|' /etc/chrony/chrony.conf
    sudo rm -f /run/chrony-dhcp/*.sources 2>/dev/null || true
    # Disable ptp4l if previously installed
    sudo systemctl disable --now ptp-slave.service 2>/dev/null || true
fi

# 4. Disable systemd-timesyncd — conflicts with chrony via adjtimex().
#    Do NOT run `timedatectl set-ntp false`: on systems where chrony is the registered
#    NTP provider, that command stops chrony too.
sudo systemctl disable --now systemd-timesyncd 2>/dev/null || true
sudo systemctl enable chrony
sudo systemctl restart chrony

# 5. Launch client via .bash_profile on tty1 autologin.
#    drm-copy uses the render node (/dev/dri/renderD128) — it does NOT need DRM master
#    or a logind seat. A bare systemd service works too. We use .bash_profile because:
#    - getty auto-restarts on crash (self-healing without a service)
#    - gets a logind seat anyway, which is useful if hwdec method ever changes
#
#    Mask sync-client.service (not just disable) so the system preset can't re-enable
#    it on boot. The .bash_profile autostart is the correct launch path.
sudo systemctl stop sync-client.service 2>/dev/null || true
sudo rm -f "$SYSTEMD_DIR/sync-client.service"
sudo systemctl mask sync-client.service 2>/dev/null || true
echo "Masked sync-client.service (replaced by .bash_profile autostart)"

# Write the autostart helper (always overwritten so re-running setup picks up changes)
cat > "$INSTALL_DIR/autostart-client.sh" <<BASHEOF
#!/bin/bash
if [ "\$(tty)" = "/dev/tty1" ]; then
    mkdir -p $INSTALL_DIR/logs
    set -a; source $INSTALL_DIR/config.env; set +a
    $INSTALL_DIR/scripts/wait-ptp-lock.sh "\$ROLE" >> $INSTALL_DIR/logs/client.log 2>&1
    exec /usr/bin/python3 -u $INSTALL_DIR/controller/client.py --server "\$SERVER_IP" \\
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

# 6. Master-only: sync server + autoplay trigger
if [ "$ROLE" = "master" ]; then
    sudo cp "$INSTALL_DIR/systemd/sync-server.service" "$SYSTEMD_DIR/"
    sudo cp "$INSTALL_DIR/systemd/sync-autoplay.service" "$SYSTEMD_DIR/"
    sudo systemctl enable sync-server.service
    sudo systemctl enable sync-autoplay.service
fi

# 7. Boot to console (no desktop)
echo "Configuring headless boot..."
sudo systemctl set-default multi-user.target

# 8. Autologin for pipe user on tty1 (needed for DRM display access)
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
