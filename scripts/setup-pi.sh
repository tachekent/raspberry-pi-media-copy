#!/bin/bash
# Full setup script for a Raspberry Pi
# Run this on each Pi after copying the project files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Pi Video Sync Setup ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# Check if running on a Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    echo "Warning: This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Install dependencies
echo "=== Installing dependencies ==="
"$SCRIPT_DIR/install-deps.sh"

# Determine role
echo ""
echo "=== Configure Role ==="
echo "Is this Pi the MASTER (time source) or a SLAVE?"
echo "  1) Master - This Pi will be the PTP time source"
echo "  2) Slave  - This Pi will sync to the master"
read -p "Select [1/2]: " ROLE

if [ "$ROLE" = "1" ]; then
    SERVICE_NAME="ptp-master"
    echo "Configuring as PTP Master"
else
    SERVICE_NAME="ptp-slave"
    echo "Configuring as PTP Slave"
fi

# Install systemd services
echo ""
echo "=== Installing systemd services ==="

# Copy PTP service
sudo cp "$PROJECT_DIR/systemd/$SERVICE_NAME.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
echo "Enabled $SERVICE_NAME.service"

# Update sync-client service with correct path
INSTALL_PATH="/home/$USER/pi-video-sync"
if [ "$PROJECT_DIR" != "$INSTALL_PATH" ]; then
    echo ""
    echo "Note: Project is not in $INSTALL_PATH"
    echo "The sync-client service expects files in $INSTALL_PATH"
    read -p "Copy project to $INSTALL_PATH? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        mkdir -p "$INSTALL_PATH"
        cp -r "$PROJECT_DIR"/* "$INSTALL_PATH/"
        echo "Copied to $INSTALL_PATH"
    fi
fi

# Install sync-client service
sudo cp "$PROJECT_DIR/systemd/sync-client.service" /etc/systemd/system/
# Update user in service file
sudo sed -i "s/User=pi/User=$USER/" /etc/systemd/system/sync-client.service
sudo sed -i "s|/home/pi/pi-video-sync|/home/$USER/pi-video-sync|g" /etc/systemd/system/sync-client.service
sudo systemctl daemon-reload
sudo systemctl enable sync-client
echo "Enabled sync-client.service"

# Create video directory
VIDEO_DIR="/home/$USER/videos"
mkdir -p "$VIDEO_DIR"
echo "Created video directory: $VIDEO_DIR"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services installed:"
echo "  - $SERVICE_NAME (PTP time sync)"
echo "  - sync-client (video sync client)"
echo ""
echo "To start services now:"
echo "  sudo systemctl start $SERVICE_NAME"
echo "  sudo systemctl start sync-client"
echo ""
echo "Or reboot to start automatically."
echo ""
echo "To trigger playback from any machine:"
echo "  python3 controller/play.py /home/$USER/videos/your-video.mp4"
