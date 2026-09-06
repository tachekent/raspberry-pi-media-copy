#!/bin/bash
if [ "$(tty)" = "/dev/tty1" ]; then
    mkdir -p /home/pipe/pi-video-sync/logs
    set -a; source /home/pipe/pi-video-sync/config.env; set +a
    /home/pipe/pi-video-sync/scripts/wait-ptp-lock.sh "$ROLE" >> /home/pipe/pi-video-sync/logs/client.log 2>&1
    # PLAYER selects mpv (default), ffplay, or kodi — see config.env.example.
    # kodi runs as its own persistent systemd service (kodi-standalone.service),
    # not spawned here — client.py --player kodi only talks to it over JSON-RPC.
    exec /usr/bin/python3 -u /home/pipe/pi-video-sync/controller/client.py --server "$SERVER_IP" \
        --player "${PLAYER:-mpv}" \
        ${KODI_SEEK_THRESHOLD:+--kodi-seek-threshold "$KODI_SEEK_THRESHOLD"} \
        >> /home/pipe/pi-video-sync/logs/client.log 2>&1
fi
