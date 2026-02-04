# Pi Video Sync - Architecture & Design Rationale

## Overview

A synchronized multi-screen video playback system for Raspberry Pi 5, designed for video wall / art installation use cases where multiple displays need frame-accurate synchronization.

**Target Hardware:** Raspberry Pi 5 (3 units)
**Connection:** Wired Ethernet
**Video Format:** 4K HEVC preferred, 1080p H.264 supported

## Chosen Architecture

```
PTP Time Sync + FFmpeg/mpv + Python Sync Controller
```

### Components

1. **PTP (Precision Time Protocol)** - Synchronizes system clocks across all Pis to ~20ns accuracy
2. **FFmpeg/mpv** - Video playback with hardware HEVC decoding via `-hwaccel drm`
3. **Python Sync Controller** - Coordinates playback start times and handles resync

### Why This Architecture

- **Microsecond-accurate time sync** via PTP hardware timestamping on Pi 5's ethernet
- **4K HEVC hardware decoding** via FFmpeg's V4L2 stateless decoder
- **Simple, debuggable** - standard Linux tools, no proprietary dependencies
- **Flexible** - can adjust sync strategy without changing players

---

## Alternatives Considered & Rejected

### 1. LibreELEC / Kodi (Previous Setup)

**What it is:** Full media center OS with Kodi, used with network sync addons.

**Why rejected:**
- Experienced drift between screens that was difficult to diagnose
- Heavy OS with lots of unnecessary components for this use case
- Sync mechanisms are add-ons rather than core functionality
- Harder to debug and customize

**When to reconsider:** If you need a full media center UI, browse media libraries, or want remote control apps.

---

### 2. OmniPlayer (Previous Setup)

**What it is:** Deprecated macOS app for synchronized multi-screen playback.

**Why rejected:**
- Deprecated / no longer maintained
- No 4K support
- macOS only (not Pi compatible)

**When to reconsider:** Never - it's dead.

---

### 3. GStreamer + PTP

**What it is:** Professional multimedia framework with native PTP clock support via `GstPtpClock`. Has a dedicated library `gst-sync-server` for exactly this use case.

**Why rejected:**
- GStreamer doesn't yet support Pi 5's HEVC "SAND" pixel formats (NC12, NC30)
- Would be limited to software H.264 decode (1080p max practical)
- The HEVC support is being worked on but not ready yet

**When to reconsider:** When GStreamer adds Pi 5 HEVC support. This would actually be the cleanest solution architecturally - `gst-sync-server` handles all the complexity.

**Resources:**
- https://github.com/ford-prefect/gst-sync-server
- https://arunraghavan.net/2016/11/gstreamer-and-synchronisation-made-easy/
- https://discourse.gstreamer.org/t/v4l2codecs-feasibility-of-adding-support-for-raspberry-pi-hevc-sand-formats-nc12-nc30/3522

---

### 4. mpv + Syncplay

**What it is:** Syncplay is a tool for synchronized "watch parties" - keeps multiple mpv/VLC instances in sync over the network.

**Why rejected:**
- Designed for "watch party" use case, not frame-perfect sync
- Tolerates larger sync windows (seconds, not frames)
- Adds network round-trips that introduce jitter

**When to reconsider:** If you just need "good enough" sync and want minimal setup. Could be a quick prototype.

**Resources:**
- https://syncplay.pl/
- https://github.com/Syncplay/syncplay

---

### 5. mpv + mpvsync plugin

**What it is:** Simple mpv plugin where master controls slave playback position.

**Why rejected:**
- Less mature than our PTP approach
- Sync quality depends on network latency
- Master/slave model less robust than shared clock

**When to reconsider:** If PTP setup proves too complex and you want simpler tooling.

**Resources:**
- https://github.com/esterkimx/mpvsync

---

### 6. VLC netsync

**What it is:** Built-in VLC module for synchronized playback across network.

**Why rejected:**
- Reports indicate it works better with streams than local files
- Tolerates ~80ms drift (±40ms from master clock)
- Less precise than PTP-based approach

**When to reconsider:** Quick prototype, or if playing network streams rather than local files.

**Resources:**
- https://wiki.videolan.org/Documentation:Modules/netsync/

---

### 7. info-beamer

**What it is:** Commercial hosted platform for Pi-based digital signage with built-in sync.

**Why rejected:**
- Subscription cost
- Requires internet for NTP-based sync
- Less control over sync mechanism
- Vendor lock-in

**When to reconsider:** If you want a polished, supported solution and don't mind the cost.

**Resources:**
- https://info-beamer.com/use-cases/raspberry-pi-video-wall

---

### 8. omxplayer-sync (turingmachine)

**What it is:** The classic solution for Pi video walls - synchronizes omxplayer instances over UDP.

**Why rejected:**
- omxplayer is deprecated and doesn't work on Pi 5
- Requires old Raspbian (Buster or earlier)
- No HEVC support
- No path forward

**When to reconsider:** Never for Pi 5. Still works on Pi 3/4 with older OS if you're stuck with that hardware.

**Resources:**
- https://github.com/turingmachine/omxplayer-sync

---

## Sync Strategy Options

We're starting with **Scheduled Start** and can upgrade if needed:

### A. Scheduled Start (Chosen - Simple)

All Pis start playback at exact same Unix timestamp.

```
Server: "Play video.mp4 at timestamp 1707091200.000000"
All clients: Start ffplay at that exact moment
```

**Pros:** Simple, no runtime overhead
**Cons:** No drift correction - relies on identical decode speed
**Best for:** Short videos, looping content (resync at loop)

### B. Periodic Resync (Medium Complexity)

Master broadcasts position every N seconds, slaves seek if drifted.

**Pros:** Catches drift before it's noticeable
**Cons:** Seeking can cause visual glitch
**Best for:** Long-form content where drift accumulates

### C. Continuous Speed Adjustment (Complex)

Slaves adjust playback speed (0.99x-1.01x) to match master position.

**Pros:** Invisible correction, no seeking
**Cons:** Complex, may affect audio pitch
**Best for:** Professional installations needing invisible sync

---

## Sync Implementation Decisions

### Decision: Use `-sync ext` with ffplay (Feb 2025)

**The insight:** ffplay's `-sync ext` option forces playback to advance at system clock rate rather than audio clock rate. Combined with PTP-synchronized system clocks, this should provide inherent synchronization without active correction.

**How it works:**
1. PTP synchronizes all Pi system clocks to ~20ns accuracy
2. `-sync ext` makes ffplay use system clock as its timing reference
3. All players start at the same scheduled moment
4. Since all clocks tick at identical rates, playback stays synchronized

**Why this is better than audio clock sync:**
- Audio clock: driven by audio hardware crystal, varies between devices
- System clock with PTP: synchronized across network, identical tick rate

**Expected outcome:** Drift-free playback for the duration of the video. The periodic sync mechanism becomes a safety net for edge cases (restarts, network issues) rather than continuous drift correction.

**ffplay flags used:**
```bash
ffplay -sync ext -infbuf -framedrop -hwaccel drm video.mp4
```
- `-sync ext`: Use system clock as master
- `-infbuf`: Infinite buffer (don't drop frames due to buffer)
- `-framedrop`: Allow frame drop if decoder falls behind
- `-hwaccel drm`: Hardware HEVC decode on Pi 5

### Decision: Periodic Seek as Fallback

Even with `-sync ext`, we keep the periodic sync broadcast mechanism for:
- Late-joining clients (Pi restarts mid-playback)
- Recovery from network issues
- Safety net if decode timing causes unexpected drift

The seek-based correction is a fallback, not the primary sync mechanism.

---

## Future Enhancement: Speed Adjustment Backoff

If testing reveals that seek-based correction causes visible glitches, we can implement continuous speed adjustment instead. This section documents the design for future implementation.

### The Problem with Simple Speed Adjustment

Naive approach:
```python
if position > expected:
    speed = 0.99  # Slow down
else:
    speed = 1.01  # Speed up
```

This causes **oscillation** - the player overshoots, corrects, overshoots again.

### Solution: Dead Zone + Proportional Correction

```python
DEAD_ZONE = 0.015      # ±15ms - don't react to drift smaller than this
MAX_ADJUST = 0.02      # ±2% maximum speed change
GAIN = 0.3             # How aggressively to correct (0.0-1.0)

def calculate_speed(drift_seconds):
    """
    Calculate playback speed to correct drift.

    Args:
        drift_seconds: actual_position - expected_position
                      positive = ahead, negative = behind

    Returns:
        Playback speed multiplier (e.g., 0.98 to 1.02)
    """
    # Dead zone: if drift is small, use normal speed
    if abs(drift_seconds) < DEAD_ZONE:
        return 1.0

    # Proportional correction
    # If ahead (positive drift), slow down (speed < 1.0)
    # If behind (negative drift), speed up (speed > 1.0)
    correction = -drift_seconds * GAIN

    # Clamp to maximum adjustment
    correction = max(-MAX_ADJUST, min(MAX_ADJUST, correction))

    return 1.0 + correction
```

### Why This Works

1. **Dead zone prevents hunting**: Small drift is ignored, so we don't constantly adjust
2. **Proportional response**: Larger drift = larger correction, smooth convergence
3. **Clamped maximum**: Can't go crazy with speed changes
4. **Returns to 1.0x**: Once in dead zone, normal speed resumes

### Convergence Example

Starting 100ms ahead:
```
t=0:  drift=+100ms → speed=0.97 (slowing down)
t=10: drift=+70ms  → speed=0.979
t=20: drift=+45ms  → speed=0.986
t=30: drift=+25ms  → speed=0.992
t=40: drift=+12ms  → speed=1.0 (in dead zone, stop correcting)
```

### Implementation Notes

- mpv: Use IPC to set `speed` property
- ffplay: No runtime speed control - would need different approach
- Audio pitch: 2% speed change is barely perceptible
- Check interval: Every 1-5 seconds is sufficient

### When to Implement

Only if testing shows:
1. `-sync ext` doesn't prevent drift as expected
2. Seek-based correction causes visible glitches
3. The installation requires invisible correction

For most cases, `-sync ext` + PTP should be sufficient.

---

## Pi 5 Video Decode Specifics

### Hardware Capabilities

- **HEVC/H.265:** Hardware decode via V4L2 stateless API (4K60 capable)
- **H.264:** Software decode only (CPU can handle 1080p fine)
- **No hardware encoder** for any codec

### FFmpeg Commands

```bash
# HEVC hardware decode
ffplay -hwaccel drm -i video.hevc

# Check if hardware decode is working
ffmpeg -v verbose -hwaccel drm -i video.mp4 -f null -
# Look for: "Hwaccel V4L2 HEVC stateless"
```

### mpv Commands

```bash
# HEVC hardware decode
mpv --hwdec=drm video.hevc
```

### Important Notes

- Pi 5 uses `-hwaccel drm`, NOT `-hwaccel v4l2m2m` (that's Pi 4)
- Verify driver loaded: `lsmod | grep hevc` should show `rpi_hevc_dec`
- DRM output is most efficient (direct to display, no GL conversion)

---

## PTP Setup Summary

### On Master Pi

```bash
sudo ptp4l -i eth0 --masterOnly 1 -m
sudo phc2sys -s eth0 -c CLOCK_REALTIME -O 0 -m -w
```

### On Slave Pis

```bash
sudo ptp4l -i eth0 --slaveOnly 1 -m
sudo phc2sys -s eth0 -c CLOCK_REALTIME -O 0 -m -w
```

### Expected Accuracy

- Two Pi 5s can sync to within ~20ns of each other
- System clock sync adds some jitter but stays sub-microsecond
- More than sufficient for frame-accurate video (16.67ms at 60fps)

---

## Future Considerations

### File Distribution

Not implemented yet. Options:
- rsync over SSH
- Shared NFS mount
- Custom sync protocol

### Multiple Video Support

Current design assumes all Pis play same video. For video wall (each Pi shows different portion):
- Pre-split video into segments
- Or use ffmpeg crop filter at playback time

### Audio

Not addressed yet. Options:
- Single audio output from master Pi
- Synchronized audio via same PTP clock
- Dedicated audio system with genlock
