# Pi Video Sync — Technical Setup Reference

This document explains the "why" behind each setup decision. For step-by-step instructions, see README.md. For architecture and alternatives, see ARCHITECTURE.md.

---

## mpv from Source

The apt package `mpv` on Pi OS Trixie does not correctly pick up `--hwdec=drm-copy` against the rpt1 ffmpeg build. We build mpv 0.40.0 from source so it links against the rpt1 ffmpeg headers already installed by the RPi apt archive.

The rpt1 ffmpeg build is what provides V4L2 HEVC stateless support — this is the actual hardware decoder. Without it, you get software decode.

### Why each non-obvious build dep

**`-Ddrm=enabled` (meson flag)**
This is mandatory and easy to miss. Without it, `--vo=drm` is silently excluded from the build even when `libdrm` is installed. There is no warning at configure time and no error at runtime — mpv simply doesn't support it. Always pass `-Ddrm=enabled` explicitly.

**`libgbm-dev libegl1-mesa-dev libgles2-mesa-dev`**
GBM (Generic Buffer Management) and EGL are needed for the DRM+EGL output path. Without them, the DRM VO falls back to a more limited path or fails.

**`libdisplay-info-dev`**
Hard dependency when `-Ddrm=enabled` is set. Provides EDID and HDR display metadata parsing. The meson build will fail without this package if DRM is enabled.

**`liblua5.2-dev` (not `liblua5.4-dev`)**
mpv 0.40.0 requires Lua < 5.3. If you install `liblua5.4-dev`, mpv silently skips Lua support at build time — it checks the version and rejects it. Without Lua, the `osc.lua` script can't load, which causes a fatal "option not found" crash on some mpv flag combinations.

**`libplacebo-dev`**
Hard dependency in mpv 0.40.0. Not optional even if you never use the `gpu-next` video output. The build will fail without it.

**`libpipewire-0.3-dev libpulse-dev`**
Required at build time for audio driver detection. Without them, mpv may fail to build or emit warnings about missing audio backends. In practice, audio doesn't work on a headless Pi booted to `multi-user.target` (no PipeWire/PulseAudio session), but the headers must be present at compile time.

**`libzimg-dev`**
Software scaler. Used when the video resolution doesn't match the display output resolution (e.g. playing 4K content on a display set to 1440p). Without it, scaling either uses a lower-quality fallback or fails.

---

## Hardware Decode

### What's actually happening

The Pi 5 HEVC decoder is exposed as a V4L2 stateless device:
- `/dev/media2` — media controller
- `/dev/video19` — decoder node

The driver is `rpi-hevc-dec`. It loads automatically on first use. If the devices are absent after reboot, load manually: `sudo modprobe rpi-hevc-dec`.

### The correct mpv flag

```
--hwdec=drm-copy
```

This is the only value that works correctly. The others fail:

| Flag | What happens |
|---|---|
| `--hwdec=drm-copy` | **Correct.** Decodes on hardware via render node, copies frame to system RAM for `--vo=drm` display. |
| `--hwdec=drm` | Doesn't apply here — `drm` hwdec refers to a different path. |
| `--hwdec=auto` | Works eventually but wastes ~2s probing vaapi → vulkan → nvdec → vdpau before finding drm-copy. Pin it explicitly. |
| `--hwdec=v4l2m2m` | Pi 4 decoder API. Not the right interface for Pi 5's stateless decoder. |

### Why drm-copy doesn't need DRM master

`drm-copy` uses the render node (`/dev/dri/renderD128`), not the card node (`/dev/dri/card1`). Render nodes don't require DRM master ownership, so any process can use them regardless of whether it has a logind seat.

This means `--hwdec=drm-copy` works from a bare systemd service as well as from an autologin shell. Both are valid.

---

## Autostart Architecture

### Services (master Pi)

| Service | What it does |
|---|---|
| `ptp-master.service` | Runs `ptp4l` as PTP grandmaster on eth0 |
| `sync-server.service` | Runs `controller/server.py --sync-interval 10` |
| `sync-autoplay.service` | Waits for PTP lock, then runs `play.py` with config from `config.env` |

### Services (slave Pi)

| Service | What it does |
|---|---|
| `ptp-slave.service` | Runs `ptp4l` as PTP slave on eth0 |

### Client launch — .bash_profile approach

`client.py` is not run as a systemd service. Instead, `setup-autostart.sh` configures tty1 autologin and adds a `source autostart-client.sh` line to `.bash_profile`. On boot:

1. getty starts on tty1
2. Autologin logs in as `pipe`
3. `.bash_profile` sources `autostart-client.sh`
4. `autostart-client.sh` checks `tty == /dev/tty1`, sources `config.env`, and execs `client.py`

Why this over a systemd service:
- **Self-healing:** If `client.py` crashes, getty restarts and re-runs `.bash_profile`, restarting the client automatically. A systemd service needs `Restart=always` and restart delays.
- **Logind seat:** The autologin shell gets a seat, which is useful if you ever need to switch to a hwdec method that requires DRM master.
- **No regression from original reason:** The original reason for `.bash_profile` (DRM master for hwdec) turned out to be wrong for `drm-copy`, but the approach has other advantages and was already set up.

The `autostart-client.sh` guard (`[ "$(tty)" = "/dev/tty1" ]`) prevents the client from launching on SSH sessions or other ttys.

### Boot sequence

```
Power on
  → multi-user.target
  → ptp-master.service (or ptp-slave.service) starts
  → sync-server.service starts (master only)
  → getty@tty1 starts → autologin → .bash_profile → client.py
  → sync-autoplay.service waits for PTP lock (~10-30s)
  → sync-autoplay.service runs play.py
  → play.py broadcasts UDP play command
  → both client.py instances start mpv at the scheduled timestamp
```

---

## Sync Architecture

### Message flow

`play.py` broadcasts the play command directly as a UDP packet to the broadcast address. It does **not** go through the server's Python API.

```
play.py  ──UDP broadcast──▶  all clients (port 5001)
                         ├──▶  client.py on master Pi
                         ├──▶  client.py on slave Pi
                         └──▶  server.py (_udp_listener_loop)
```

The server snoops its own broadcast port (`_udp_listener_loop`) to update `PlaybackState`. Without this, the server never knows playback started, `is_playing()` stays `False`, and the `_sync_broadcast_loop` never fires — no drift correction.

### Scheduled start

`play.py` sets `start_at = time.time() + delay` (default 2s) and broadcasts the timestamp. Each client waits until `start_at` using a sleep + busy-wait combination for sub-millisecond precision. With PTP-synced clocks, all clients hit the same timestamp within ~20ns of each other.

### Drift correction

`server.py --sync-interval 10` broadcasts the current playback state every 10 seconds. Each client calculates `expected_position = now - start_time` and compares to mpv's actual position via IPC. If drift exceeds the threshold (default 30ms), the client seeks to the expected position.

The IPC path: `client.py` connects to mpv's Unix socket (`/tmp/mpv-sync-<pid>.sock`) and sends JSON commands. `get_property time-pos` returns current position; `seek <pos> absolute` corrects it.

### Reconnect / late join

When `client.py` connects to the server's TCP port, the server returns the current `PlaybackState` in the registration response. The client calls `_handle_sync()`, calculates the expected position (`now - start_time`), and starts mpv at that position via `--start=<pos>`. This lets a Pi that reboots mid-playback rejoin immediately.

---

## Forcing Output Resolution and Refresh Rate

By default, mpv's `--vo=drm` uses whatever mode the monitor negotiates via EDID. Two problems arise from this:

1. **Wrong resolution** — if the display is at a lower res than the video (e.g. 4K source on a 2560×1440 monitor), mpv does CPU software scaling, causing frame drops.
2. **Wrong refresh rate** — if the display refresh rate doesn't divide evenly into the video frame rate (e.g. 60Hz display with 25fps video = 2.4:1), each video frame alternates between 2 and 3 display refreshes, causing cadence judder.

### The fix: `DRM_MODE` in config.env

Set `DRM_MODE` in each Pi's `config.env` to tell mpv which KMS mode to use:

```bash
# In ~/pi-video-sync/config.env on each Pi:
DRM_MODE=3840x2160@25   # production: projectors at native 4K, 25fps video
```

mpv's `--drm-mode` overrides EDID negotiation at playback time. It's per-Pi, requires no reboot, and takes effect whenever the client restarts.

**List available modes** (run on the Pi):
```bash
/usr/local/bin/mpv --vo=drm --drm-mode=help /dev/null 2>&1 | grep Mode
```

Use the exact Hz value shown — mpv matches literally, so `@50` won't match `@49.99Hz`.

**Verify after client restart:**
```bash
grep -a 'FPS for display\|Window size' ~/pi-video-sync/logs/mpv.log | tail -4
# Should show the target Hz and resolution
```

### Choosing the right mode

| Situation | DRM_MODE value |
|---|---|
| Production projector, 4K, 25fps video | `3840x2160@25` |
| Production projector, 4K, 30fps video | `3840x2160@30` |
| 16:9 dev monitor, 25fps video | `2560x1440@60` (or find a 50Hz mode if available) |
| 21:9 ultrawide dev monitor, 25fps video | `3440x1440@49.99` (50Hz equivalent — 2:1 ratio) |
| Unset | Monitor's preferred/negotiated mode |

### Why not `video=` in cmdline.txt?

The `video=<connector>:<mode>` kernel parameter is documented as the way to force KMS output on Pi OS, but in practice the monitor's EDID negotiation wins even when the parameter is present in `/proc/cmdline`. `--drm-mode` is applied by mpv directly at the DRM/KMS level and reliably overrides it.

---

## Logs

| File | Contents |
|---|---|
| `~/pi-video-sync/logs/client.log` | `client.py` stdout/stderr (connection, play commands, drift corrections) |
| `~/pi-video-sync/logs/mpv.log` | mpv log output including hwdec status, window size, errors |

Check mpv.log first when diagnosing hardware decode or display issues:
```bash
grep -a -E 'hwdec|Window size|Error|error' ~/pi-video-sync/logs/mpv.log
```
