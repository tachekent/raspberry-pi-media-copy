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
| `sync-server.service` | Runs `controller/server.py --sync-interval 3` |
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

### How position synchronisation works

`play.py` picks a future Unix timestamp `T = time.time() + delay` and broadcasts it once. This is the canonical "playback epoch" — the wall-clock moment the video logically started at position 0.

Every client independently computes:

```
expected_position = (time.time() - T) % DURATION
```

Because chrony keeps all clocks within ~5ms of each other, every client's `time.time()` is virtually identical. They therefore compute the same `expected_position` without any positional data ever being transmitted.

The server rebroadcasts `T` and `DURATION` every 3 seconds (the sync interval — see "Sync interval: 3s, not 10s" below for why). On each receipt, the client queries mpv's current position via IPC, compares it to `expected_position`, and corrects if drift exceeds the threshold (default 30ms) — see "Hybrid drift correction" below for how.

**Loop resets are implicit.** The `% DURATION` in the formula wraps `expected_position` back to zero each time elapsed time crosses a multiple of `DURATION`. No explicit "reset at loop point" logic is needed. The only requirement is that `DURATION` matches the actual video duration closely — a 0.1s error accumulates at 0.5ms/loop with a 10s correction interval, which is negligible. A 1s error accumulates at 50ms/loop and becomes perceptible over a long run.

**Seek precision matters for HEVC.** mpv's `seek <pos> absolute` snaps to the nearest keyframe (typically every 2–5 seconds for HEVC), which can place mpv up to 600ms away from the requested position. We use `set_property time-pos` instead, which performs a frame-accurate seek. This is why drift corrections converge in 1–2 cycles (~10–20s) rather than oscillating indefinitely.

### Drift correction

`server.py --sync-interval 3` broadcasts the current playback state every 3 seconds. Each client calculates `expected_position = (now - start_time) % DURATION` and compares to mpv's actual position via IPC. If drift exceeds `--drift-threshold` (default 30ms), the client corrects it — either with a smooth speed nudge or a hard seek, depending on the size of the drift (see "Hybrid drift correction" below).

The IPC path: `client.py` connects to mpv's Unix socket (`/tmp/mpv-sync-<pid>.sock`) and sends JSON commands. `get_property time-pos` returns the current position; `set_property time-pos <pos>` performs a hard seek; `set_property speed <rate>` nudges playback rate.

### Hybrid drift correction: speed nudge vs. hard seek

Every `set_property time-pos` seek causes a brief visible freeze/hitch on screen — this turned out to be true regardless of how small the correction was (confirmed by watching pi2 visibly stutter on ~50-300ms corrections, well under the seek's own latency). Since the old design corrected *every* threshold-exceeding drift with a hard seek, a Pi with any persistent rate mismatch would visibly jump every single sync cycle.

The fix splits correction into two tiers based on `--hard-seek-threshold` (default 500ms):

- **`abs(drift) > hard_seek_threshold`** — large gap (startup, reconnect, a real outlier). Closing this smoothly would need an obviously fast-forwarded speed change, so it's not worth avoiding a jump here — just seek, using the same seek-latency compensation described below.
- **`drift_threshold < abs(drift) <= hard_seek_threshold`** — moderate, steady-state drift. Instead of jumping, `client.py` nudges mpv's `speed` property slightly (capped at ±4% — `self.max_speed_offset`) to close the gap gradually. **Neither video file has an audio track**, so there's no pitch-shift penalty to this — it's the reason this approach is viable at all here.
- **`abs(drift) <= drift_threshold`** — within tolerance, speed is reset to 1.0 (in case a previous nudge left it adjusted).

### Why the speed nudge alone left a residual (and the fix: a learned bias)

A pure proportional correction (`speed_offset = -drift / speed_catchup_window`) only corrects the *change* in drift each cycle — it doesn't account for a *persistent* underlying rate error (each Pi's playback genuinely runs very slightly faster or slower than wall-clock time, independent of any correction). Left uncompensated, that shows up as the ~0.5%/5ms-per-second creep documented earlier in this file. A proportional-only controller facing a constant disturbance settles at a nonzero steady-state error rather than converging to zero — measured directly: pi1 and pi2 each plateaued at a stable ~75-130ms residual instead of trending toward the threshold.

The fix is the standard one for exactly this problem: an integral term. `self.speed_bias` is a slowly-learned EWMA of the speed offset actually needed, added on top of the proportional term:

```python
speed_offset = self.speed_bias + (-drift / self.speed_catchup_window)
...
self.speed_bias = 0.92 * self.speed_bias + 0.08 * speed_offset
```

Once `speed_bias` converges to (the negative of) a Pi's true underlying rate error, applying `speed = 1.0 + speed_bias` at zero drift exactly cancels that error, holding drift at zero indefinitely instead of just slowing its growth. This is the same self-calibrating philosophy as `seek_latency_estimate` — no hardcoded constant, adapts to whatever the actual hardware/content combination needs.

**The underlying rate error isn't actually constant, though.** Watching the correction log closely showed drift settling into a plateau for ~10-15 cycles, then *stepping* to a different plateau — not a smooth decay. That points at a content-dependent effect, plausibly the variable/auto bitrate encoding (different scenes → different average decode cost → different effective playback rate). A single learned bias can only track the *current* segment's disturbance and has to re-adapt every time it shifts.

The gain (0.08, up from an initial 0.02) was tuned specifically to re-adapt faster across these content-driven shifts: at 0.02 gain, drift got stuck at an elevated plateau (~75-130ms, 2-3 frames at 25fps) for over a minute after each shift; at 0.08, it reaches a small residual (~30-50ms, close to a single frame) within about 30-45 seconds, with no added noise or oscillation in the learned bias.

### Sync interval: 3s, not 10s

Originally 10s. Reducing it to 3s compounds with the bias gain rather than substituting for it: `speed_bias` updates once per sync cycle, so more frequent cycles mean faster *real-time* adaptation for the same per-update gain, and each proportional correction is smaller since drift is caught before it accumulates as much. It does **not** help detect content-driven rate shifts sooner — those happen on a ~60-130s timescale, well above either interval — the benefit is purely in how fast the response converges once a shift is happening.

Measured result: at 3s, both Pis now converge from a fresh hard-seek to a stable, small residual (~35ms) within 30-45 seconds, and — notably — **both converge to nearly the same residual value**, which is what actually matters for the two screens' relative sync. The cost is negligible: sync broadcasts are tiny JSON packets, and the IPC round-trips involved measure in single-digit milliseconds.

### ⚠️ Known constraint: speed-nudge correction assumes no audio

The entire "small speed nudges are free" argument above rests on neither video file having an audio track — confirmed via `audio-codec-name: None` on both during today's testing. **One Pi is planned to have audio in future content.** For that Pi, a `speed` change pitch-shifts audio audibly (unless mpv's pitch-preserving `scaletempo`/`scaletempo2` audio filter is enabled, which has its own quality/latency tradeoffs), so the moderate-drift branch in `_handle_sync()` cannot silently keep nudging speed once audio is added there.

Before adding audio to a Pi, revisit `client.py`'s correction logic for that Pi specifically — options include: enabling `--audio-pitch-correction`/`scaletempo2` and verifying it sounds acceptable at the ±4% range currently used, lowering `max_speed_offset` further for that Pi, or falling back to hard-seek-only correction there (accepting the freeze) while keeping the audio-less Pi(s) on the smooth path. Don't assume the current default `max_speed_offset`/`hard_seek_threshold` values are still fine once audio is in the mix without testing.

**Test plan (not yet run — write this up before the audio Pi goes live):**

Use a synthetic, predictable test track rather than real content — a pure tone makes even a tiny unintended pitch shift obvious, where music or speech would mask it. Two independent signals, mixed together:
- A sine tone with a slow, known sinusoidal *frequency* modulation (e.g. 440Hz ±20Hz over a ~20s period) — any unexpected wobble or step layered on top of the expected smooth sweep is a correction-induced artifact, easy to spot on a spectrogram.
- A short click every exactly 1.000s, independent of the tone — a pitch-independent ground truth for actual elapsed playback time, to confirm audio timing tracks the corrected video timeline rather than drifting from it.

Procedure:
1. Generate the track (mirror `scripts/make_drift_test.sh`'s pattern — a new `scripts/make_audio_test_track.sh` makes sense).
2. Drive mpv's `speed` property through an actual *recorded* sequence of values from a real correction log (several are already captured in this project's history) rather than inventing one, so the test reflects real-world transition frequency (~every 3s) and magnitude (~±1-3%, occasionally up to ±4%).
3. Render output directly to a file via `--ao=pcm` (deterministic, no microphone/capture hardware needed) under two conditions: pitch correction disabled (negative control — confirms the shift is audible/measurable without it) and enabled (confirms it's actually suppressed).
4. Analyze: pitch-track the rendered output (FFT or autocorrelation per short window) against the expected clean sweep, verify click timestamps land where expected, and listen specifically around each speed-transition instant — repeated small tempo-ratio changes are exactly the kind of thing that can introduce an audible tick or pop in some pitch-correction implementations, and this design changes speed roughly every sync cycle, so that risk is real and specific to check for, not hypothetical.
5. Verify mpv 0.40.0's actual current pitch-correction option name/default behavior in the manual at test time rather than assuming — this may have changed across versions.

### mpv IPC desync bug (fixed 2026-08-19/20)

For a long stretch this project's drift correction appeared to work sometimes and silently stop other times, with no errors — deeply confusing to debug because the symptom (large, unexplained, non-converging drift on one Pi but not the other) looked like a hardware/timing problem. It wasn't.

mpv's JSON IPC stream interleaves **unsolicited event lines** (e.g. `{"event":"seek"}`, `{"event":"playback-restart"}`) with command responses on the same socket. The old `MpvIPC._send_command()` read until it saw the *first* newline and assumed that was the response. If an event line happened to arrive first, it read that instead, found no matching `request_id`, and returned `None` — and left the real response sitting unread in the socket buffer. Every subsequent call would then read the *previous* call's leftover response, which never matches its own `request_id` either, so it also returns `None`. Once desynced this way, a connection is broken **permanently** until reconnect — `get_position()` silently returns `None` forever, `_handle_sync()` hits `if actual_pos is None: return` before ever reaching the drift check, and no error is ever logged.

This explains why it looked non-deterministic session to session: whether a connection got desynced depended on whether an unsolicited event happened to land at the wrong moment early in that connection's life — bad luck on some boots, fine on others.

**Fix**: `_send_command()` now keeps a receive buffer that persists across calls, and reads complete lines from it, discarding anything whose `request_id` doesn't match the current call (event or stale leftover) instead of trusting the first line it sees.

### Self-adjusting seek-latency compensation

A separate, smaller effect: `set_property time-pos` returning success only means the seek was *queued* — mpv's hr-seek then decodes forward from the nearest keyframe to the exact target frame, which takes real wall-clock time (bounded by GOP size — currently 50 frames / 2s worst case). The old code computed the seek target before issuing the seek and never accounted for this, so every correction systematically undershot by roughly one seek's latency.

`MpvIPC.seek()` now polls mpv's `seeking` property until the seek actually lands and returns how long that took. `SyncClient` keeps a running EWMA (`self.seek_latency_estimate`, 70/30 weighting) of that latency and adds it to the *next* correction's target position — so it self-calibrates from measured behavior instead of a hardcoded constant, and adapts if content, GOP position, or system load changes.

### Resolved: pi2 visibly jumping every ~10s (2026-08-20)

Originally logged here as an open follow-up: pi2 visibly jumped every ~10s to maintain sync, because its underlying playback throughput has more inherent per-cycle variance than pi1's, so it needed a real correction almost every cycle while pi1 often went many cycles without one. The hard-seek-only design meant every one of those corrections was a visible freeze regardless of size.

Fixed by the hybrid speed-nudge/hard-seek split, the learned bias term, and the 3s sync interval documented above. Net effect measured live: no more freezes for routine corrections (speed nudges instead), and both Pis now converge to nearly the same small residual (~35ms) rather than pi2 persistently lagging behind a much larger, jumpier correction pattern. The root question of *why* pi2's variance is structurally higher than pi1's (different, differently-encoded footage on each) was never answered — the fix neutralizes the symptom rather than the cause, which is fine for now but worth remembering if the residual ever grows again.

### Reconnect / late join

When `client.py` connects to the server's TCP port, the server returns the current `PlaybackState` in the registration response. The client calls `_handle_sync()`, calculates the expected position (`(now - start_time) % DURATION`), and starts mpv at that position via `--start=<pos>`. This lets a Pi that reboots mid-playback rejoin immediately.

The slave Pi always boots slightly later than the master (~15–30s) because it waits for chrony to achieve sub-2ms offset before starting. This means it initially starts at a different loop position than the master. Drift corrections converge them within ~30s of the slave beginning playback.

---

## Cold Boot Clock Instability & RTC Battery

### The problem

Pi 5 has an onboard RTC chip, but **no battery backup by default**. On a cold boot (no battery installed), the RTC has no valid stored time. Observed kernel log:

```
kernel: rpi-rtc soc@...: setting system clock to 1970-01-01T00:00:17 UTC (17)
```

The system falls back to some other reference (e.g. the root filesystem's last-modified timestamp) as a sanity floor, then chrony detects the real error once it reaches the internet and performs a **step** correction:

```
chronyd: System clock wrong by 19461.487274 seconds
chronyd: System clock was stepped by 19461.487274 seconds
```

This step itself resolves in seconds — the actual problem is what happens *after* it. Following a large step, chrony's **frequency estimate** (how fast/slow the local oscillator runs relative to real time) is unreliable for some minutes while it re-converges from fresh measurements. During that window, `time.time()` on that Pi runs at a measurably *wrong rate*, not just a wrong offset. Since master and slave each experience their own unrelated frequency-instability period after their own cold boot, the position-sync math (`expected_position = (time.time() - T) % DURATION`, see above) drifts at different, changing rates on each Pi. The result: **inter-Pi drift that grows over the first many minutes of a session**, rather than a fixed offset — worse the longer playback has been running, until chrony settles down.

This is expected to recur **every morning** under a gallery-style deployment where the Pis are hard power-cut nightly and cold-booted each morning with no graceful shutdown — it isn't an occasional fluke, it's the normal cold-boot behavior of an RTC with no battery.

### The fix: RTC battery

Installing a battery (official Raspberry Pi RTC Battery — Panasonic ML2020 rechargeable cell, pre-fitted JST plug) on the Pi 5's RTC header means the RTC holds a real time across power-off instead of resetting to an invalid value. Available in Norway from [Kjell & Company](https://www.kjell.com/no/produkter/data/raspberry-pi/raspberry-pi-rtc-batteri-for-raspberry-pi-5-p88407) — sticks on with the included double-sided tape, plugs straight into the 2-pin JST header, no soldering. Needs one per Pi.

**No software/config changes are needed** — verified on both Pis:
- `rtcsync` is already present in `/etc/chrony/chrony.conf` (Debian/Pi OS default). This tells chrony to periodically write the system clock into the RTC (via the kernel, every ~11 min) *while running*, not just at a clean shutdown — important since these Pis never get a clean shutdown.
- No `fake-hwclock` package installed (it would conflict with a real battery-backed RTC — good that it's absent).
- No legacy `/lib/udev/hwclock-set` override interfering with systemd's own RTC handling.

### After installing the battery

The RTC chip's stored time only becomes trustworthy once `rtcsync` has written a good value to it at least once while the battery is present and the system is running and synced. So:
- **First boot after installing the battery**: expect to see the same big step correction one more time (the RTC hasn't been seeded yet).
- **Every boot after that**: the RTC should hold a roughly-correct time across the overnight power-off (only off by however long the Pi was actually powered down, not since epoch/filesystem-mtime), so chrony should only need a small slew, not a disruptive step — avoiding the frequency-instability window entirely.

**Verify it worked** — after the second post-install boot:
```bash
journalctl -b 0 | grep -i "clock wrong"
# Should be absent, or show an error of a few seconds at most (not tens of thousands)
```

### Known limitation (not yet implemented)

`wait-ptp-lock.sh`'s master mode is a blind `sleep 30` — it doesn't verify chrony has actually stabilized before `sync-autoplay.service` broadcasts the play command. The RTC battery fix should make this moot in practice (no more big steps to wait out), but as defense-in-depth it would be more robust for the master to poll `chronyc tracking` until the frequency estimate stops changing between reads (or hit a timeout), rather than trusting a fixed 30s.

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
| 16:9 dev monitor, 25fps video | `1920x1080@50.00` (verified working — see below) |
| 21:9 ultrawide dev monitor, 25fps video | `3440x1440@49.99` (50Hz equivalent — 2:1 ratio) |
| Unset | Monitor's preferred/negotiated mode |

**Don't just pick the highest resolution — pick the mode whose refresh rate divides evenly into the content's fps.** Dev monitors on this project support 2560x1440, but only at ~60Hz (no 50Hz or 25Hz mode at that resolution — confirmed via `--drm-mode=help`). 60Hz against 25fps content is a 2.4:1 pulldown ratio: every video frame alternates between 2 and 3 display refreshes. Beyond the visible judder, this measurably increased mpv's CPU usage (250–340% observed) and caused large, erratic per-cycle drift corrections between the two Pis (200ms–1.5s, changing sign and magnitude each cycle) that never converged. Dropping to `1920x1080@50.00` (an exact 2:1 ratio, available on both dev monitors used here) cut mpv's CPU usage roughly in half and brought the drift-correction pattern from erratic to a stable, predictable sawtooth. This is a real trade-off (resolution vs. cadence) worth deciding deliberately per display — always run `mpv --vo=drm --drm-mode=help /dev/null` on the actual hardware first; don't assume the highest resolution mode is best.

### `--video-sync=display-resample`

Paired with `DRM_MODE`, `client.py` also passes `--video-sync=display-resample` to mpv. Without it, mpv paces frames using its own internal software timer rather than locking to the display's actual vsync pulses — even at a cadence-matched refresh rate, that timer can run at a slightly different rate than the system clock, showing up as smooth, drop-free playback that nonetheless drifts steadily against wall-clock time. `display-resample` ties frame pacing to real hardware vsync instead. Combined with the `DRM_MODE` fix above, this cut mpv's CPU usage further and turned the erratic multi-second drift into a small, well-behaved correction pattern (see "Sync Architecture" above for what's still open on top of this).

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
