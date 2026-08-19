#!/bin/bash
# Wait for PTP to be ready before triggering autoplay.
# Usage: wait-ptp-lock.sh [master|slave]
#   master: waits a fixed time for slaves to lock
#   slave:  polls until offsetFromMaster < threshold

MODE="${1:-slave}"
THRESHOLD=2000000  # 2ms in nanoseconds (software PTP jitter ~50-200µs; 2ms << 1 frame at 25fps)
CONSECUTIVE=3
FIXED_WAIT=30      # seconds to wait on master

if [ "$MODE" = "master" ]; then
    echo "PTP master: waiting ${FIXED_WAIT}s for slaves to lock..."
    sleep "$FIXED_WAIT"
    echo "Done."
    exit 0
fi

# Slave: poll pmc until offset is stable
echo "Waiting for PTP lock (offset < ${THRESHOLD}ns)..."
count=0
attempts=0
max_attempts=60  # 2 min timeout, then proceed anyway

while [ $count -lt $CONSECUTIVE ] && [ $attempts -lt $max_attempts ]; do
    offset=$(/usr/sbin/pmc -u -b 0 -i "/tmp/pmc.$$" -s /var/run/ptp4lro \
        'GET CURRENT_DATA_SET' 2>/dev/null \
        | awk '/stepsRemoved/{steps=int($2)} /offsetFromMaster/{gsub(/-/,"",$2); off=int($2)} \
               END{if(steps>0) printf "%d\n", off}')

    if [ -n "$offset" ] && [ "$offset" -lt "$THRESHOLD" ] 2>/dev/null; then
        count=$((count + 1))
        echo "  offset=${offset}ns (${count}/${CONSECUTIVE})"
    else
        count=0
        echo "  offset=${offset:-unknown}ns — waiting..."
    fi

    attempts=$((attempts + 1))
    sleep 2
done

if [ $attempts -ge $max_attempts ]; then
    echo "Warning: PTP lock timeout — proceeding anyway"
else
    echo "PTP locked."
fi
