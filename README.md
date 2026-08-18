# Pi Video Sync

Synchronized multi-screen video playback for Raspberry Pi 5 using PTP time synchronization and FFmpeg/mpv.

## Requirements

- 2x Raspberry Pi 5 (expandable to 3+)
- Raspberry Pi OS (64-bit) — Trixie or later
- Ethernet cable between the Pis (direct connection — no switch needed for two Pis)
- HEVC/H.265 encoded video files for 4K (or H.264 for 1080p)

## Connecting from a Mac

The Pis can be managed from a Mac over direct ethernet (no router needed). You'll need a USB-to-ethernet adapter if your Mac has no built-in ethernet port.

### 1. Enable Internet Sharing on the Mac

Do this first so the Pi gets an IP and internet access as soon as it boots:

System Settings → General → Sharing → Internet Sharing
- Share your connection from: **Wi-Fi** (or whichever interface your Mac uses for internet)
- To computers using: **your USB ethernet adapter**

The Mac will now act as a DHCP server and router on the ethernet interface.

### 2. Flash the SD card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and choose **Raspberry Pi OS (64-bit)** (Trixie, recommended). Before writing, click the settings gear and configure:

- Hostname: `pi1`, `pi2` (one per card)
- Enable SSH with a password or your public key
- Leave WiFi blank if you're connecting via ethernet only

### 3. Boot and connect

Plug in the Pi and give it 30–60 seconds to boot. It will get a `192.168.2.x` address from the Mac via DHCP. SSH in:

```bash
ssh pipe@pi1.local   # mDNS hostname set in Imager
```

If mDNS isn't resolving, find the IP from the Mac:

```bash
arp -a | grep 192.168.2
```

Then SSH by IP:

```bash
ssh pipe@192.168.2.x
```

### 4. Copy files to the Pi

```bash
# Copy this project (excludes .git)
rsync -av --exclude='.git' . pipe@pi1.local:~/pi-video-sync

# Copy a video file
scp film.mp4 pipe@pi1.local:~/
```

> **No Internet Sharing?** If you booted the Pi without Internet Sharing enabled, it may have no IP on eth0. Switch it to DHCP and reconnect:
> ```bash
> sudo nmcli con mod "Wired connection 1" ipv4.method auto
> sudo nmcli con up "Wired connection 1"
> ```

> **3+ Pis:** You'll need a small ethernet switch so all Pis share the same network segment (required for PTP). A basic unmanaged switch is fine.

---

## Autostart Setup (Production / Gallery)

This is the recommended setup for installation use. The Pis boot headless, establish PTP sync, and start playing automatically. Power-cycling restarts everything cleanly — no keyboard or monitor needed after initial setup.

### 1. Install dependencies (on each Pi)

```bash
./scripts/install-deps.sh
```

### 2. Copy your video

```bash
scp film.mp4 pipe@pi1.local:~/video.mp4
scp film.mp4 pipe@pi2.local:~/video.mp4
```

### 3. Run the setup script

**On the master Pi:**
```bash
./scripts/setup-autostart.sh master
```

**On the slave Pi:**
```bash
./scripts/setup-autostart.sh slave
```

This installs and enables the systemd services and configures headless boot.

### 4. Edit config.env on each Pi

The setup script creates `~/pi-video-sync/config.env` from the example. Edit it:

```bash
nano ~/pi-video-sync/config.env
```

| Setting | Master | Slave |
|---|---|---|
| `VIDEO` | `/home/pipe/video.mp4` | `/home/pipe/video.mp4` |
| `DURATION` | length in seconds (e.g. `2400` for 40 min) | same |
| `SERVER_IP` | leave blank | master's IP (e.g. `192.168.2.x`) |

### 5. Reboot both Pis

```bash
sudo reboot
```

On boot, the sequence is:
1. PTP establishes — slave locks to master clock (~10–30s)
2. Both sync clients start listening for play commands
3. Master waits 30s then broadcasts the play command
4. Both screens start in sync

---

## Manual / Development Mode

To run everything by hand (useful for testing):

### 1. Install dependencies

```bash
./scripts/install-deps.sh
```

The script uses `sudo` internally — run it as your normal user and enter your password when prompted.

### 2. Configure PTP

On the **master** Pi:
```bash
./scripts/ptp-master.sh
```

On each **slave** Pi:
```bash
./scripts/ptp-slave.sh
```

### 3. Start the sync controller

On the **master** Pi:
```bash
python3 controller/server.py --sync-interval 10
```

On each **slave** Pi:
```bash
python3 controller/client.py --server <master-ip>
```

### 4. Play a video

```bash
python3 controller/play.py /path/to/video.mp4 --loop --duration 2400
```

## Project Structure

```
.
├── ARCHITECTURE.md          # Design rationale and alternatives considered
├── README.md                # This file
├── config.env.example       # Copy to config.env and edit on each Pi
├── scripts/
│   ├── install-deps.sh      # Install required packages
│   ├── setup-autostart.sh   # Configure headless autostart (run once per Pi)
│   ├── wait-ptp-lock.sh     # Wait for PTP to lock before autoplay
│   ├── make_drift_test.sh   # Generate a sync drift test video
│   ├── ptp-master.sh        # Start PTP master (manual mode)
│   ├── ptp-slave.sh         # Start PTP slave (manual mode)
│   ├── setup-pi.sh          # Full setup wizard
│   └── test-hwdec.sh        # Test hardware decoding
├── controller/
│   ├── server.py            # Sync server (runs on master)
│   ├── client.py            # Sync client (runs on all Pis)
│   ├── play.py              # Trigger playback
│   └── player.py            # mpv wrapper
└── systemd/
    ├── ptp-master.service   # PTP grandmaster (master Pi)
    ├── ptp-slave.service    # PTP slave (slave Pi)
    ├── sync-server.service  # Sync server (master Pi)
    ├── sync-client.service  # Sync client (all Pis)
    └── sync-autoplay.service # Autoplay trigger (master Pi)
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

---

## Display Resolution and Refresh Rate

`mpv --vo=drm` uses whatever mode the monitor negotiates via EDID. This causes two problems if left unset:

- **Wrong resolution** → CPU software scaling → frame drops on 4K content
- **Wrong refresh rate** → cadence judder (e.g. 60Hz display + 25fps video = 2.4:1 ratio; each frame alternates between 2 and 3 display refreshes)

**Set `DRM_MODE` in each Pi's `config.env`** to force the right mode at playback time — no reboot needed, takes effect on next client restart:

```bash
# On each Pi, edit ~/pi-video-sync/config.env:
DRM_MODE=3840x2160@25    # production projectors, 25fps video
```

List available modes on a Pi:
```bash
/usr/local/bin/mpv --vo=drm --drm-mode=help /dev/null 2>&1 | grep Mode
```

Use the exact Hz shown — mpv matches literally (`@50` won't match `@49.99Hz`).

Verify it took effect:
```bash
grep -a 'FPS for display\|Window size' ~/pi-video-sync/logs/mpv.log | tail -4
```

**TODO before gallery install:** Set `DRM_MODE=3840x2160@25` (or `@30`) in `config.env` on both Pis once the production projectors are connected. Check available modes first to confirm the projector supports it.

---

## Encoding for Pi 5

The Pi 5 hardware decoder supports **HEVC (H.265) Main profile, 8-bit, 4:2:0** up to 4K60. Encode to these specs for guaranteed hardware decode.

### Recommended FFmpeg command

```bash
ffmpeg -i input.mov \
  -c:v libx265 \
  -crf 22 \
  -preset slow \
  -profile:v main \
  -level:v 5.1 \
  -pix_fmt yuv420p \
  -x265-params "keyint=60:min-keyint=60:no-open-gop=1" \
  -c:a aac -b:a 192k \
  output.mp4
```

### Parameter notes

| Parameter | Value | Why |
|---|---|---|
| `-profile:v main` | main | Hardware decoder requires 8-bit Main — not Main 10 |
| `-pix_fmt yuv420p` | yuv420p | 8-bit 4:2:0 — 10-bit will fall back to software |
| `-level:v 5.1` | 5.1 | Correct level for 4K content |
| `-crf` | 22–26 | 22 = high quality, 26 = smaller file; 24 is a good default |
| `-preset` | slow | Runs on your Mac at encode time — no effect on Pi playback |
| `keyint=60` | 60 frames | Keyframe every 2s at 30fps; shorter = faster drift-correction seeks |
| `no-open-gop=1` | 1 | Closed GOP — more reliable seeking |

### File size estimates (4K, 30fps)

| CRF | Approx bitrate | 40 min file size |
|---|---|---|
| 22 | ~15 Mbps | ~4.5 GB |
| 24 | ~10 Mbps | ~3 GB |
| 26 | ~6 Mbps | ~1.8 GB |

### Exporting from DaVinci Resolve

On the **Deliver** page, use these settings:

**Format & codec**
- Format: `MP4`
- Codec: `H.265 (HEVC)`
- Resolution: `3840 × 2160`
- Frame rate: match your project

**The critical settings — click the gear/Advanced icon next to the codec:**
- Bit Depth: **8-bit** — the most important setting; 10-bit exports as Main 10 profile which won't hardware-decode on the Pi
- Profile: **Main** (should follow automatically from 8-bit)
- Key Frames: **Every 60 frames** (adjust for your frame rate: 50 for 25fps, 60 for 30fps)

**Quality**
- Set `Restrict to` **10000 kbps** for good quality, or **6000 kbps** for smaller files
- Alternatively use the Quality slider at around 60–70%

> **Note:** If your Resolve project is HDR or uses a wide-gamut colour space, Resolve may default to 10-bit output. Override it explicitly in the codec advanced settings, or convert to Rec.709 before export. The Pi 5 will play HDR-graded content but the display and hardware decoder need 8-bit input.

After export, verify the file before copying to the Pi:

```bash
ffprobe -v quiet -show_streams output.mp4 | grep -E "codec_name|profile|pix_fmt"
# Should show: codec_name=hevc, profile=Main, pix_fmt=yuv420p
```

### Hardware Decoding

Test that the Pi is using hardware decode:

```bash
./scripts/test-hwdec.sh /path/to/video.mp4
```

H.264 content falls back to software decode — fine for 1080p, but use HEVC for 4K.

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
