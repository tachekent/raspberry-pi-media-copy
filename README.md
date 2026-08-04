# Pi Video Sync

Synchronized multi-screen video playback for Raspberry Pi 5 using PTP time synchronization and FFmpeg/mpv.

## Requirements

- 3x Raspberry Pi 5
- Raspberry Pi OS (Bookworm)
- Wired Ethernet connection between all Pis
- HEVC/H.265 encoded video files for 4K (or H.264 for 1080p)

## Quick Start

### 1. Install Dependencies (on each Pi)

```bash
./scripts/install-deps.sh
```

### 2. Configure PTP

On the **master** Pi:
```bash
./scripts/ptp-master.sh
```

On each **slave** Pi:
```bash
./scripts/ptp-slave.sh
```

### 3. Start the Sync Controller

On the **master** Pi:
```bash
# Basic (no drift correction)
python3 controller/server.py

# With drift correction every 10 seconds (recommended for long videos)
python3 controller/server.py --sync-interval 10
```

On each **slave** Pi:
```bash
python3 controller/client.py --server <master-ip>
```

### 4. Play a Video

From the master Pi (or any connected client):
```bash
python3 controller/play.py /path/to/video.mp4
```

For looping videos with drift correction:
```bash
python3 controller/play.py /path/to/video.mp4 --loop --duration 3600
```

## Project Structure

```
.
├── ARCHITECTURE.md      # Design rationale and alternatives considered
├── README.md            # This file
├── scripts/
│   ├── install-deps.sh      # Install required packages
│   ├── make_drift_test.sh   # Generate a sync drift test video
│   ├── ptp-master.sh        # Start PTP master
│   ├── ptp-slave.sh         # Start PTP slave
│   ├── setup-pi.sh          # Full setup wizard
│   └── test-hwdec.sh        # Test hardware decoding
├── controller/
│   ├── server.py        # Sync server (runs on master)
│   ├── client.py        # Sync client (runs on slaves)
│   ├── play.py          # Command to trigger playback
│   └── player.py        # Video player wrapper
└── systemd/
    ├── ptp-master.service
    ├── ptp-slave.service
    └── sync-client.service
```

## Drift Test Video

Generate a test video designed to make sync drift immediately visible when played side-by-side on multiple screens:

```bash
./scripts/make_drift_test.sh [output.mp4] [duration_seconds]

# Examples
./scripts/make_drift_test.sh drift_test.mp4 600   # 10-minute test (default)
./scripts/make_drift_test.sh drift_test.mp4 3600  # 1-hour test
```

The video contains four drift indicators:

| Element | What to look for |
|---|---|
| **Corner panels** (top-left & top-right) | Toggle black/white at 2 Hz. In sync: both screens match. 1 frame off: one switches before the other. |
| **Scrolling stripes** | Horizontal bands moving upward at 120 px/s. A phase offset between screens means the stripe edges don't line up horizontally. 1-frame drift = 4 px offset. |
| **Second flash** | Full-screen brightness spike for ~3 frames at each second boundary. Staggered flashes = desync. |
| **Timecode / Frame counter** | Read exact elapsed time and frame number to measure drift precisely. |

## Drift Correction

For long videos (1+ hours), enable periodic sync to prevent drift:

**Server side:**
```bash
python3 controller/server.py --sync-interval 10  # Check every 10 seconds
```

**Client side:**
```bash
# Default threshold is 30ms (1 frame at 30fps)
python3 controller/client.py --drift-threshold 0.03

# Tighter threshold for 60fps content
python3 controller/client.py --drift-threshold 0.016
```

When drift exceeds the threshold, the client seeks to the correct position. With PTP providing nanosecond-accurate clocks, corrections should be rare and minimal.

## Late Join / Restart Recovery

If a Pi restarts during playback:
1. It connects to the server
2. Server sends current playback state
3. Client seeks to the correct position and joins

This happens automatically when `--sync-interval` is enabled.

## Hardware Decoding

Pi 5 has hardware HEVC decode only. Test it:

```bash
./scripts/test-hwdec.sh /path/to/video.hevc
```

For H.264 content, software decode is used (fine for 1080p).

## How It Works

1. **PTP Sync**: All Pis synchronize their system clocks via PTP to ~20ns accuracy
2. **Sync Server**: Master Pi runs a server that coordinates playback
3. **Scheduled Start**: Server broadcasts "play X at timestamp Y"
4. **Drift Correction**: Server periodically broadcasts current state, clients seek if drifted

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design rationale.

## Command Reference

### Server

```bash
python3 controller/server.py [options]

Options:
  --port PORT              TCP port for clients (default: 5000)
  --broadcast-port PORT    UDP broadcast port (default: 5001)
  --sync-interval SECS     Position sync interval, 0=disabled (default: 0)

Interactive commands:
  play <path> [delay] [loop] [duration]  - Start playback
  stop                                    - Stop playback
  status                                  - Show current playback
  sync                                    - Force sync broadcast
  list                                    - List connected clients
  quit                                    - Exit
```

### Client

```bash
python3 controller/client.py [options]

Options:
  --server, -s HOST        Server hostname/IP
  --port PORT              Server TCP port (default: 5000)
  --broadcast-port PORT    UDP broadcast port (default: 5001)
  --id NAME                Client ID (default: hostname)
  --player {mpv,ffplay}    Video player (default: mpv)
  --drift-threshold SECS   Max drift before correction (default: 0.03)
```

### Play Command

```bash
python3 controller/play.py <video> [options]

Options:
  --delay, -d SECS         Delay before start (default: 2.0)
  --loop, -l               Loop playback
  --duration SECS          Video duration (for loop sync)
  --stop                   Stop playback instead
  --port, -p PORT          Broadcast port (default: 5001)
```

## Troubleshooting

### Check PTP sync status
```bash
# On slave, look for "s2" (locked) state and low offset
journalctl -u ptp-slave -f
```

### Check hardware decode is working
```bash
ffmpeg -v verbose -hwaccel drm -i video.mp4 -f null - 2>&1 | grep -i hwaccel
# Should show: "Hwaccel V4L2 HEVC stateless"
```

### Verify HEVC driver loaded
```bash
lsmod | grep hevc
# Should show: rpi_hevc_dec
```

### Test mpv IPC
```bash
# Start mpv with IPC
mpv --input-ipc-server=/tmp/mpv.sock video.mp4

# In another terminal, query position
echo '{"command": ["get_property", "time-pos"]}' | socat - /tmp/mpv.sock
```
