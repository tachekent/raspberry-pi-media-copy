#!/bin/bash
# Wait for clock sync before triggering autoplay.
# Usage: wait-ptp-lock.sh [master|slave]
#   master: waits a fixed time for slaves to sync
#   slave:  waits until chrony offset < 2ms (sub-frame accuracy at 25fps)

MODE="${1:-slave}"
FIXED_WAIT=30  # seconds master waits for slaves to sync

if [ "$MODE" = "master" ]; then
    echo "Clock master: waiting ${FIXED_WAIT}s for slaves to sync..."
    sleep "$FIXED_WAIT"
    echo "Done."
    exit 0
fi

# Slave: use chronyc waitsync (blocks until offset < 2ms, timeout 120s)
echo "Waiting for chrony sync (offset < 2ms)..."
if chronyc waitsync 120 0.002 0 1; then
    offset=$(chronyc tracking 2>/dev/null | awk '/System time/{printf "%.3fms", $4*1000}')
    echo "Chrony synced. Current offset: ${offset}"
else
    echo "Warning: chrony sync timeout — proceeding anyway"
fi
