#!/bin/bash
# ExecStopPost hook for kodi-standalone.service.
#
# Kodi signals power actions by exiting with a specific code rather than
# calling systemctl itself — it expects an external supervisor to act on it.
# A bare systemd unit (no ExecStopPost) doesn't know this convention: it just
# sees a nonzero exit and, with Restart=on-failure, immediately relaunches
# Kodi — looking like an instant reboot loop with the system never actually
# changing power state (confirmed 2026-09-07: journalctl --list-boots showed
# no new boot at all across several "reboots" of just the Kodi process).
#
# Kodi's exit codes (XBApplicationEx.h): 0=quit, 64=POWERDOWN, 65=RESTARTAPP,
# 66=REBOOT. Only 64/66 need real OS action here; 65 just means "restart
# Kodi", which Restart=on-failure already does correctly on its own.
case "$EXIT_STATUS" in
    64) systemctl poweroff ;;
    66) systemctl reboot ;;
esac
