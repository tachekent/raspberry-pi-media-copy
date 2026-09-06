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
Required at build time for audio driver detection. Without them, mpv may fail to build or emit warnings about missing audio backends. **Note this mpv build has no ALSA output at all** (`--ao=alsa` fails with "Audio output alsa not found!") — `libasound2-dev` was never in the build deps, so only `pipewire`/`pulse` AOs got compiled in. See "Getting audio working on headless boot" below for how to actually get sound out despite that.

**`libzimg-dev`**
Software scaler. Used when the video resolution doesn't match the display output resolution (e.g. playing 4K content on a display set to 1440p). Without it, scaling either uses a lower-quality fallback or fails.

---

## Hardware Decode: Complete Requirements Checklist (verified 2026-09-06 against a live, working pi1)

Everything below was checked against a real running board, not written from memory — commands to reproduce each check are included so this can be re-verified on any Pi or after any reimage.

### 1. OS / kernel

- Raspberry Pi OS (Debian 13 "trixie"), kernel `6.18.34+rpt-rpi-2712` or later. Verify: `cat /etc/os-release; uname -r`.
- The Raspberry Pi Foundation's own apt archive must be enabled (`archive.raspberrypi.com`, present by default on Raspberry Pi OS, check `/etc/apt/sources.list.d/raspi.sources`). This is what serves the `rpt1`-patched `ffmpeg` build — the one with V4L2 HEVC stateless support baked in. A vanilla Debian `ffmpeg` package does **not** have this.

### 2. `config.txt`

The only line actually required for KMS/DRM display output is:
```
dtoverlay=vc4-kms-v3d
```
This is what makes `--vo=drm` possible at all — without it you're on the legacy firmware framebuffer, not full KMS. On a stock Raspberry Pi OS image this is present by default; if a config.txt was hand-built or stripped down, this is the one line that can't be missing. `disable_fw_kms_setup=1` (also present by default) prevents the firmware from doing its own conflicting KMS setup. Nothing else in config.txt is required specifically for HEVC decode — no `dtoverlay=` line is needed for the decoder itself; it's a kernel driver, not a device-tree-gated peripheral. Verify: `cat /boot/firmware/config.txt`.

### 3. Kernel driver & device nodes

The decoder loads as a normal kernel module, `rpi_hevc_dec` (note: underscore in `lsmod`, hyphen in the driver name `rpi-hevc-dec` — both refer to the same thing), pulling in `v4l2_mem2mem`, `videobuf2_*`, and `videodev`. It loads automatically on first use; if the device nodes below are missing after a reboot, `sudo modprobe rpi-hevc-dec` loads it manually. Verify: `lsmod | grep -i hevc`.

Expected device nodes (exact minor numbers can vary; presence is what matters):
- `/dev/media2` — media controller for the decoder
- `/dev/video19` — the actual decoder node
- `/dev/dri/card1` — DRM card node (KMS display)
- `/dev/dri/renderD128` — DRM render node (this is the one `drm-copy` actually opens)

Verify: `ls /dev/media* /dev/video19 /dev/dri/`.

### 4. User permissions

The user running mpv must be in both the `video` and `render` groups (`/dev/dri/renderD128` is group `render`; the media/video device nodes are group `video`). `install-deps.sh` does this via `sudo usermod -aG video,render "$USER"`. Verify: `groups <user>` — both must appear. Missing `render` specifically produces a "Permission denied" opening the render node with no other obvious symptom, easy to mistake for a driver problem.

### 5. GPU memory split

`gpu_mem` does **not** need to be raised for this — `drm-copy` decode uses DMA-BUF/CMA allocation via V4L2, not the legacy GPU memory pool. A stock split (`gpu=8M` observed on a working board) is fine; don't waste time increasing it as a "fix" for decode issues.

### 6. mpv build

Covered in full above ("mpv from Source") — built from source specifically to link against the `rpt1` ffmpeg headers, since the apt `mpv` package does not correctly pick up `--hwdec=drm-copy` against it. Not repeated here; see that section for the exact deps and why each is non-obvious.

### 7. Runtime flags

`--hwdec=drm-copy --vo=drm` — see the flag table below (unchanged from before). This is the only combination confirmed working on Pi 5's stateless decoder.

### 8. How to actually verify hardware decode is active (not just "no errors")

**A generic `ffmpeg` CLI command is not a reliable way to check this on Pi 5** — worth knowing, because it's the first thing anyone reaches for and it's misleading here:
- `ffmpeg -hwaccel drm -i file.mp4 ...` silently falls back to **software decode** (confirmed live: produced a `wrapped_avframe` output stream at 0.5x realtime speed, no error, no acceleration — nothing in the output tells you it didn't accelerate).
- `ffmpeg -c:v hevc_v4l2m2m -i file.mp4 ...` **fails outright** ("Could not find a valid device") — this decoder wrapper targets the Pi 4-style stateful V4L2 M2M API, which doesn't exist on Pi 5's stateless decoder. Its presence in `ffmpeg -decoders` output doesn't mean it works here.

The actual reliable check is mpv's own log, since mpv talks to the stateless decoder via the media-request API directly rather than through either of the above:
```bash
grep -i "Using hardware decoding" ~/pi-video-sync/logs/mpv.log
# Expected: [i][vd] Using hardware decoding (drm-copy).
```
If this line is absent or says `(no)`, decode fell back to software regardless of what flags were passed — check `mpv.log` for `Looking at hwdec hevc-drm-copy... failed` just above it for the reason.

### 9. Source video requirements (the encoding side, not just playback config)

**Codec — this is the biggest trap**: Pi 5 has hardware decode for **HEVC (H.265) only**. Unlike Pi 4, **Pi 5 does not have H.264 hardware decode at all** — H.264 content silently falls back to software decode on Pi 5 (the CPU is fast enough that 1080p H.264 often still plays fine, masking the fact that it's not accelerated — but 4K H.264 will not). If a source file is H.264, re-encode it to HEVC first; there is no flag that makes H.264 hardware-accelerated on this hardware.

**Profile / pixel format**: stick to HEVC **Main profile, 8-bit, 4:2:0** (`yuv420p`) — this project's actual production files are already encoded this way (confirmed via `ffprobe`) and are exactly what's been validated working. 10-bit (Main10) support in this driver stack is reported incomplete elsewhere in the Pi ecosystem (GStreamer's implementation is documented 8-bit only) — nothing here confirms Main10 is broken specifically for mpv's path, but there's no confirmed-working evidence for it either, so treat 10-bit/Main10 sources as untested risk, not a safe assumption. Re-encode to 8-bit 4:2:0 rather than assume it'll "just work."

**Bitrate mode — directly relevant to this project's own frame-timing investigation**: the sync client's own code comments (`client.py`, `speed_bias` logic) document that this project's actual production file shows "content-dependent plateaus" in decode/timing behavior — i.e. real, measured, scene-dependent variability under this file's variable bitrate (VBR) encoding. That's a real, evidenced mechanism for exactly the kind of moment-to-moment inconsistency seen throughout this investigation's `mistimed-frame-count` measurements (different tests landing on different scenes of the same long VBR file gave meaningfully different results). Constraining the encode to a bounded rate — VBV-capped or true CBR — makes memory-bandwidth demand far more uniform across the whole file, which won't fix a hardware-level margin problem but removes a real, independent source of variability that's currently confounding every measurement taken against this file. Recommended `ffmpeg`/x265 encode:
```bash
ffmpeg -i input.mov -c:v libx265 -profile:v main -pix_fmt yuv420p -preset medium \
  -x265-params "vbv-maxrate=25000:vbv-bufsize=50000:strict-cbr=1" \
  -g 50 -c:a aac -b:a 192k output.mp4
```
- `vbv-maxrate`/`vbv-bufsize`: set `vbv-maxrate` near the current file's actual average bitrate (this project's real file measures ~23.3Mbps via `ffprobe`), `vbv-bufsize` at roughly 2x that — a widely-used default ratio, not a hard rule. `strict-cbr=1` forces x265 to hold the rate rather than just capping peaks, at some cost to quality-per-bit versus unconstrained VBR.
- `-profile:v main -pix_fmt yuv420p`: forces 8-bit 4:2:0 explicitly rather than trusting the encoder's default profile selection from the source.
- `-g 50`: keyframe interval — this project's existing files already use a ~50-frame (2s at 25fps) GOP, which the sync client's own comment cites as its assumed worst-case hard-seek latency bound (`client.py`: "bounded by GOP size — currently 50 frames / 2s worst case"). A shorter GOP tightens hard-seek convergence time at the cost of file size/quality-per-bit; no evidence in this investigation suggests the current value is a problem, so this isn't a recommended change, just documentation of the existing assumption should it ever need revisiting.
- **Not recommended based on evidence gathered here**: tuning B-frame count/reference structure. Decode framerate (`estimated-vf-fps`) stayed locked at the exact source rate in every single test this whole investigation, on every board, good or bad — decode throughput was never shown to be the bottleneck at any point. Encoder-side complexity tuning aimed at decode load is solving a problem that hasn't actually been observed here; the bottleneck in every confirmed-bad case was presentation/page-flip timing, not decode capacity.

**Resolution/framerate**: match (or use an exact integer/rational multiple of) the actual display's native refresh — already established practice in this project via `calibrate-drm-mode.py`, not a new requirement, just confirming it belongs on this checklist.

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

### ⚠️ Known constraint: speed-nudge correction assumes no audio — audio is now already live in production

The entire "small speed nudges are free" argument above rests on neither video file having an audio track — that was confirmed via `audio-codec-name: None` on both back on 2026-08-19/20. **That assumption is no longer true.** As of tonight, `/home/pipe/video.mp4` on **both** pi1 and pi2 has an AAC audio track (48kHz stereo) — checked directly via `ffprobe`. This isn't a future hypothetical anymore; the moderate-drift branch in `_handle_sync()` is nudging `speed` on audio-bearing content on both Pis right now.

The good news, from the test below: mpv's default `--audio-pitch-correction=yes` already handles this well in practice. No code changes needed for that reason alone. If audio is undesired on a given Pi (headless boot still has no working PipeWire/Pulse session — see the top of this file — so audio silently fails to play anyway), that's a separate, deliberate decision, not something forced by the drift-correction design.

**Test plan — first attempt run 2026-08-20, inconclusive; second attempt run 2026-08-20, conclusive.**

Confirmed useful facts: `--audio-pitch-correction` defaults to `yes` in this mpv build, so pitch correction would already be active if audio were added today with zero code changes.

First attempt used a synthetic sine tone with a slow, known sinusoidal frequency sweep (440Hz ±20Hz over ~20s) plus an independent 1-second click train (pitch-independent ground truth for elapsed time) — a pure tone makes even a tiny unintended pitch shift obvious, where music or speech would mask it. Two methodology problems came up:

1. **`--ao=pcm` renders far faster than real time** (a 90s file rendered in ~0.4s), so driving mpv's `speed` property via live IPC at wall-clock intervals matching a real correction log didn't work — neither wall-clock timing nor polling `time-pos` could reliably land each change at its intended point; multiple changes ended up bunched together.
2. **Fallback (render each speed segment as an independent mpv process, then concatenate) is harsher than reality**: each segment restarts the pitch-correction filter from scratch, so it necessarily shows a phase discontinuity at *every* segment boundary regardless of whether real, continuous playback would. Measured 12 discontinuities in the pitch-corrected version vs. 1 in the uncorrected one — likely just that reinit artifact, not evidence pitch correction is worse, but this test design can't tell the difference.

**Second attempt fixed both problems and got a clean answer.** Pulled the real `client.log` off pi2 and extracted the actual sequence of 132 recorded `speed` values from a real hard-seek-to-converged run (drift from -547ms down to a ~30-55ms residual). Instead of driving mpv externally by wall clock, an mpv Lua script (`mp.observe_property("time-pos", ...)`) applies each recorded speed value when *simulated playback position* crosses each successive 3-second boundary (matching the real `--sync-interval 3`) — this is driven by actual decoder position, not wall-clock, so it works correctly even though `--ao=pcm` still renders the whole ~410s clip in a few seconds. Ran as **one continuous mpv process** for the whole sequence (no reinit artifact), with the same sine-sweep+click test tone muxed as the audio track into an actual copy of `video-left.mp4` (the "mux into a real video copy" approach flagged as the right next step last time). Rendered once with `--audio-pitch-correction=yes` and once with `=no`, then measured instantaneous-frequency deviation (Hilbert-transform phase derivative vs. a smoothed baseline) in a window around each of the 132 real transition points.

Result: **with pitch correction on, all 132 transitions show no detectable artifact at all** (peak deviation ~0.7 Hz — noise floor). Without pitch correction, multiple transitions show clear, audible-scale glitches (peak instantaneous-frequency deviations of 60–165 Hz right at the transition instant) — confirming a real `speed` change without correction does produce an audible artifact on every jump, as expected.

An initial pass of this run showed one isolated 174Hz spike right after the *last* recorded transition, despite pitch correction being on. It was reproducible (same run, same spot, every time) — but tracing it down found the cause in the **test harness, not mpv**: the test script's `time-pos` observer had a tidiness line that reset `speed` back to `1.0` once the recorded sequence was exhausted. That reset itself is an extra, unplanned speed transition that real `client.py` never issues (it just keeps whatever speed was last commanded) — so the "anomaly" was the test creating its own artificial glitch immediately after the real data ended, not a defect in mpv's pitch correction. Removed that reset line and reran: zero detected glitches across all 132 real transitions, clean.

Artifacts from this run, for reference/re-verification: `test_video_with_audio.mp4` (muxed test clip), `out_corrected.wav` / `out_uncorrected.wav` (original two-condition comparison), `out_corrected3.wav` (final clean rerun after the test-script fix), `log_corrected*.csv` / `log_uncorrected.csv` (applied speed per transition), `clips/*.wav` (short listen-test excerpts, kept for reference even though the anomaly they were extracted to investigate turned out to be a test artifact) — all currently in the session scratchpad, not yet committed to the repo.

**Conclusion: `--audio-pitch-correction=yes` (mpv's default) is safe to rely on for the current ±4% `max_speed_offset` range — confirmed clean across every real transition, no open questions remaining.** No code change needed in `client.py` for the speed-nudge branch itself.

### Getting audio actually working on headless boot (fixed 2026-08-21)

With real audio content now live in production, the "no PipeWire/PulseAudio session on headless boot" limitation (noted above and in the mpv build-deps section) needed an actual fix, not just a documented workaround.

First instinct — force ALSA directly with `--ao=alsa` and skip PipeWire/Pulse entirely — doesn't work: **this mpv build has no ALSA output compiled in at all.** `--ao=alsa --audio-device=alsa/plughw:vc4hdmi0,0` fails with `Audio output alsa not found!` regardless of device string; checking mpv's own "List of enabled features" confirms `pipewire` and `pulse` are present but `alsa` is not — `libasound2-dev` was never in `install-deps.sh`'s build dependencies, so mpv's meson build never detected it. Rebuilding mpv with ALSA support is one fix, but a faster one exists: PipeWire's `alsa` device backend is already compiled in and just needs a running PipeWire session, which the headless boot never provides.

**Actual fix — no mpv rebuild needed, no `client.py` changes needed:**

```
sudo loginctl enable-linger pipe   # let pipe's systemd --user instance run without a login session
systemctl --user enable pipewire.service pipewire.socket wireplumber.service pipewire-pulse.service pipewire-pulse.socket
systemctl --user start wireplumber pipewire-pulse   # (only needed once; enable+reboot covers it after)
```

`pipewire.service` itself was already running (socket-activated, apparently from the tty1 autologin shell), but `wireplumber.service` — the session/policy manager that actually discovers ALSA hardware and creates sink nodes — was not, so PipeWire had zero sinks (`PipeWire does not have any audio sinks, skipping` in mpv.log) and always fell through to Pulse, which also wasn't running (`Connection refused`). Starting `wireplumber` makes `wpctl status` immediately show both HDMI outputs (`Built-in Audio` ×2, one per `vc4hdmi` card) and a live default sink (`Built-in Audio Digital Stereo (HDMI)`). At that point mpv's default AO probe order (pipewire first) just works with **zero flags** — confirmed via `mpv.log` showing `AO: [pipewire] 48000Hz stereo 2ch floatp` / `audio ready`, and confirmed surviving a full reboot on both Pis (the enabled units restart automatically, no manual step needed after a power cycle).

Applied identically to both pi1 and pi2 — both currently have `HDMI-A-1` connected and audio rides the same cable as video (PipeWire picks the default sink automatically; no explicit device selection needed since only one HDMI port is active on each).

**Related fix, same session: stale `DURATION` in `config.env`.** Both Pis' `config.env` had `DURATION=200.875` left over from earlier short test content. When the production video was swapped for the real ~42-minute (2544.9s) file, this went unnoticed until checked directly — `_handle_sync`'s `position % duration` loop-math would have wrapped every ~200s against a file that's actually 2544s long, once the *next* boot re-read `config.env` (the already-running instance was unaffected since it had the old file's short duration burned into its live `PlaybackState`, matched to the old short file it opened at boot). Fixed by setting `DURATION=2544.917333` (from `ffprobe`) on both Pis and doing a clean reboot of both to pick up the new file, corrected duration, and the audio fix all at once. Post-reboot, confirmed single `client.py`/`mpv` per Pi (no double-mpv), both audio-ready, both drift-correcting normally.

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

### Follow-up (not yet implemented): check the connector is actually connected before launching mpv

Real incident (2026-08-20): a monitor was connected but showing no image. Cause: the active HDMI connector had changed (was `HDMI-A-2`, became `HDMI-A-1` — the physical cabling/port in use changed), but the *already-running* mpv process never re-detects this — it negotiates a connector once at its own startup and keeps using it, so a runtime hotplug or port change is invisible to it until it's restarted. A plain restart fixed it (mpv re-detects on every startup, confirmed via the "Connector N currently connected to encoder M" log line), but nothing currently guards against booting into this state in the first place.

Two related risks worth hardening in `scripts/setup-autostart.sh` / `autostart-client.sh` before relying on this unattended:
1. **At boot, mpv might start before EDID handshake completes** on a slow-to-wake display, finding no valid modes for the forced `DRM_MODE` and failing outright.
2. **A connector change after boot** (different port, monitor swap) is silently invisible until the next restart — there's no automatic recovery today.

Proposed fix: before launching `client.py`, poll `/sys/class/drm/*/status` (bounded timeout, e.g. 10-15s) until at least one HDMI connector reports `connected`, logging which one. This directly addresses risk 1. Risk 2 (detecting a *later* change while already running) would need something extra, like watching for DRM hotplug uevents and triggering a client/mpv restart — a bigger addition, worth deciding whether it's justified given restarts have so far been a rare, manually-triggered fix.

### Follow-up (not yet investigated): both Pis lost IPv4 simultaneously (2026-08-20)

Real incident, same day: both Pis' `eth0` had no IPv4 address at all (only IPv6 remained) — a network-wide DHCP problem, not anything in this project's software. pi1 kept appearing to "work" only because its own client talks to `localhost`, masking the loss; pi2 had no path to reach pi1 at all (mDNS resolution failure was a symptom, not the cause — direct ping to pi1's known IP also failed). Fixed both with `sudo nmcli connection up "Wired connection 1"` to force a fresh DHCP renewal.

Root cause not determined — could be the router/switch rebooting, a lease conflict, or something else upstream of these Pis. Worth keeping an eye on whether this recurs; if it does, it may be worth a periodic connectivity self-check (e.g. a systemd timer that notices "no IPv4 for N minutes" and retries `nmcli connection up` automatically) rather than requiring a manual SSH fix each time — but not worth building until it's shown to be a recurring problem rather than a one-off.

### Resolved: sync-server's broadcast thread died silently, leaving Pis unsynced for ~12 hours (2026-08-20)

Discovered because the two Pis were visibly ~7 frames apart. `journalctl -u sync-server` on pi1 showed `_sync_broadcast_loop` had thrown `OSError: [Errno 101] Network is unreachable` from `broadcast()`'s `udp_socket.sendto()` at 10:29:12 that morning — almost certainly during the "both Pis lost IPv4" incident above. Because `_sync_broadcast_loop` ran as a plain `threading.Thread` with no try/except around the broadcast call, that one exception killed the thread permanently. `systemctl status` kept reporting the service as `active (running)` the whole time — the main process and its other threads (client registration, keepalive) were fine — but no sync packet had gone out since, so both Pis had been free-running independently for about 12 hours by the time it was noticed.

**Fix**: `_sync_broadcast_loop` now catches (broadly — `Exception`, not just `OSError`, since *any* uncaught exception here is equally fatal to the thread and this is an unattended gallery install with no one to notice or restart it by hand) around the broadcast call and logs+continues instead of dying, so a future transient network blip self-heals on the next `sync_interval` tick instead of silently disabling corrections until someone happens to notice and restarts the service by hand. Deployed to pi1 but not force-restarted into the live service (would wipe in-memory `PlaybackState` and require a fresh `play.py` re-arm) — takes effect at the next natural restart/reboot.

**How to apply**: if other background threads in `server.py`/`client.py` are added later, give them the same treatment — an uncaught exception in a daemon thread doesn't crash the process or show up in `systemctl status`, so failures like this are invisible unless someone is actively watching drift or reading `journalctl`.

### Direct 1-1 Pi connection, no switch (resolved and confirmed 2026-08-21/22 — switched to static IPs)

**Reframed partway through debugging this**: the direct 1-1 connection isn't a fallback scenario to accommodate — it's the *normal, permanent deployment*. The two Pis are wired directly to each other with a single cable at the venue; a switch is only ever plugged in temporarily during setup/dev (internet access, SSH convenience). That reframing is why the fix below is much simpler than everything tried before it.

**Everything tried first, all abandoned**: two rounds chasing an automatic DHCP-with-link-local-fallback setup (NetworkManager 1.52's `ipv4.link-local=fallback` flag — never worked at all across two tests; then a second, lower-priority link-local connection profile — worked sometimes, but recovery back to DHCP once reconnected to a switch was inconsistent, occasionally needing a full power-cycle even after a carrier bounce). The final straw: rebooting *while* directly connected (no DHCP source present from the very start of boot, a case never tested until it happened for real) left both Pis hung at the console — `client.py` on the slave just sits in its receive loop forever waiting for a 'play' broadcast that can never arrive with no working network, which looks identical to a hang since all its output goes to a log file, not the screen. Recovered by reconnecting to a switch and power-cycling again.

**Actual fix: drop DHCP and link-local entirely, use static IPs.** Given direct connection is the permanent case, there's no DHCP server to negotiate with in production anyway — a static address configured directly on `eth0` comes up in well under a second on every boot, with nothing to time out, negotiate, or race, regardless of what's plugged in. `setup-autostart.sh` now sets this automatically per role:

- pi1 (master): `192.168.2.2/24`
- pi2 (slave): `192.168.2.3/24`
- Gateway/DNS both set to `192.168.2.1` — not needed by the sync system itself, kept only so setup-time internet access still works when a switch/router happens to be present.

`config.env`'s `SERVER_IP` also changed from `pi1.local` (mDNS) to the static `192.168.2.2` directly, removing avahi from the critical runtime path entirely — mDNS is still used for `pi1.local`/`pi2.local` SSH access during dev, but the sync system no longer depends on it at all. The master's chrony `allow 192.168.0.0/8` ACL was also fixed to the intended `/16` (a `/8` mask accidentally covered all of `192.0.0.0/8`) — real and unrelated to which network mechanism is in use.

Applied live to both Pis and verified: static addresses hold, playback and drift correction both undisturbed by the network reconfiguration itself.

**Confirmed with a real physical test**: both Pis connected 1-1 with no switch, rebooted cold, correct static IPs shown on the boot screen (no `127.0.0.1`/no-address hang this time), and playback converged to frame-perfect sync after about 2 minutes — matching the normal hard-seek + PTP/chrony convergence timeline, not a degraded or unusual one. The exact scenario that caused the original boot hang now works cleanly.

**Unrelated side quest, still unresolved**: tried to make `journalctl` persist across reboots (`Storage=persistent` in `journald.conf`, plus manually creating `/var/log/journal/<machine-id>/`) so a future test's logs wouldn't get wiped by a recovery reboot. Didn't work — kept reporting `/run/log/journal/...` (volatile) even after two service restarts and an explicit `--flush`. Root cause not found; low priority now that static IPs remove most of the reason to need it, but worth another look if deep NetworkManager debugging is ever needed again.

### pi3: standalone single-video-loop mode (added 2026-08-22/23)

New machine, clean Raspberry Pi OS **Lite** install (not Desktop like pi1/pi2) — just one screen, one video, looping forever, nothing to sync with. See "Standalone Mode" in README.md and `scripts/setup-standalone.sh`/`systemd/standalone-video.service`. Confirmed working: hardware decode, correct `DRM_MODE` (see below), audio, and Bluetooth audio (see below).

Being on Lite (not Desktop) surfaced two more "present on Desktop, missing on Lite" package gaps beyond the PipeWire one found earlier — both now fixed in `install-deps.sh`:
- `libspa-0.2-bluetooth` (PipeWire's Bluetooth/A2DP plugin) — without it, pairing succeeds but `connect()` fails with `br-connection-profile-unavailable`.
- (PipeWire/WirePlumber runtime packages themselves were already fixed earlier in the session for pi1/pi2 — same fix, this just confirms it generalizes.)

**`calibrate-drm-mode.py`** (new script, `scripts/calibrate-drm-mode.py`): auto-picks the best `DRM_MODE` for a video+display by ranking available modes on cadence match (refresh rate as an integer multiple of the video's fps) then resolution closeness to native. Validated live on pi3's Dell monitor (4K/25fps video, monitor tops out at 2560x1440): correctly picked `1920x1080@50.00`, fixing real jumpy playback. **Real bug caught and fixed during development**: mpv's `--drm-mode` value must be bare `WxH@R` — the `Hz` suffix shown by `--drm-mode=help`'s human-readable output is NOT valid in the option value and is a fatal parse error. First version wrote it with `Hz` and briefly crashed pi3's live playback service before being caught; now has a regex self-check before ever writing to config.

**Bluetooth audio** (paired to a Samsung Soundbar M550, MAC `CC:6E:A4:24:E7:BC`, confirmed working with audio actually playing through it): two real fixes beyond the missing package above, both baked into `scripts/setup-standalone.sh`:
1. WirePlumber's bluez monitor gates on `monitor.bluez.seat-monitoring`, which requires a real logind **seat**. A lingering-but-never-logged-in background session (this whole headless setup) has none — the monitor loaded (visible only with `WIREPLUMBER_DEBUG=3`, logs nothing at normal verbosity) but silently never enumerated the adapter, so every connect attempt failed with `br-connection-profile-unavailable` even with the plugin installed. Fixed with a `/etc/wireplumber/wireplumber.conf.d/51-headless-bluetooth.conf` override disabling `monitor.bluez.seat-monitoring` and `support.logind` — the same thing WirePlumber's own built-in `main-systemwide` profile mixin does for exactly this class of setup. **Not yet confirmed whether pi1/pi2 would need this too** — their tty1-autologin setup likely provides a real seat0 (a physical console login normally does), which would make this a non-issue there, but this was never actually tested against pi1/pi2.
2. Nothing reconnects a paired device after a power cycle with no one around to click anything (pairing/trust itself persists fine on its own via `bluetoothd`'s `/var/lib/bluetooth/` state). Added `bluetooth-reconnect.service` (`scripts/bluetooth-reconnect.sh`, reads `BLUETOOTH_MAC=` from `standalone.env`): best-effort, ~50s of retries, deliberately does **not** block video playback (agreed design: start immediately, audio joins whenever it joins). Verified live: disconnect → service reconnects automatically, and the sink's volume (set to 100%, same reasoning as the HDMI sinks earlier — no ALSA hardware mixer in the chain, so 100% is unity gain, not added boost) persists across the reconnect. mpv's PipeWire audio stream automatically re-routes to whichever sink is current default, with zero playback-side code changes needed.

**Bluetooth audio latency — codec question resolved (2026-08-23): dead end at the soundbar, not at PipeWire.**
- The negotiated Bluetooth transport codec is **SBC** (`wpctl inspect <sink-id>` → `api.bluez5.codec = "sbc"`) — the highest-latency common A2DP codec, and the mandatory baseline every device must support.
- The source video file's own audio codec (AAC, confirmed via `ffprobe`) is irrelevant to this — PipeWire decodes that internally to raw PCM regardless, then re-encodes separately for the Bluetooth transport. Two independent codec choices at different pipeline stages.
- **Debian's `libspa-0.2-bluetooth` package ships with no AAC encoder plugin** (`dpkg -L libspa-0.2-bluetooth | grep codec` — no `aac`) because PipeWire's `bluez5-codec-aac` build option needs `libfdk-aac`, which lives in Debian's `non-free` component; a package in `main` can't build-depend on it. This is a **packaging** exclusion, not a technical one.
- **Built AAC support from source and confirmed it's fully possible**: `apt install libfdk-aac-dev` (already available — `non-free` is enabled in `/etc/apt/sources.list.d/debian.sources` on this system, just not installed by default) provides `fdk-aac.pc`, which PipeWire's meson build auto-detects. Each bluez5 codec is its own standalone plugin (`libspa-codec-bluez5-<name>.so`), so there's no need to replace the whole PipeWire install — just build the one target and drop it into the existing plugin directory:
  ```bash
  sudo apt install libfdk-aac-dev libdbus-1-dev libudev-dev libsbc-dev libbluetooth-dev
  git clone --branch 1.4.2 --depth 1 https://github.com/PipeWire/pipewire.git   # match `pipewire --version`
  cd pipewire
  meson setup builddir -Dsession-managers=[] -Dsystemd=disabled \
    -Dexamples=disabled -Dtests=disabled -Ddocs=disabled -Dman=disabled \
    -Djack=disabled -Dvulkan=disabled -Dgstreamer=disabled -Dv4l2=disabled \
    -Dlibcamera=disabled -Dffmpeg=disabled -Dpipewire-alsa=disabled -Dsndfile=disabled \
    -Davahi=disabled -Dbluez5=enabled -Dbluez5-codec-aac=enabled
  ninja -C builddir spa/plugins/bluez5/libspa-codec-bluez5-aac.so   # ~5s, only builds this target + deps
  sudo install -m 644 -o root -g root builddir/spa/plugins/bluez5/libspa-codec-bluez5-aac.so \
    /usr/lib/aarch64-linux-gnu/spa-0.2/bluez5/
  systemctl --user restart wireplumber
  ```
  Verified live on pi3: WirePlumber picked up the new plugin with no crash, registered `/MediaEndpoint/A2DPSink/aac` + `/MediaEndpoint/A2DPSource/aac` over D-Bus (confirmed via `WIREPLUMBER_DEBUG=3`), and the same recipe would work for aptX/LDAC/LC3/Opus too (`-Dbluez5-codec-<name>=enabled` + the matching `-dev` package — `libfreeaptx-dev`, `libldacbt-abr-dev`/`libldacbt-enc-dev`, `liblc3-dev`, `libopus-dev`; not installed here since they weren't needed). The `.so` isn't dpkg-tracked, so it needs re-dropping after any `libspa-0.2-bluetooth` reinstall/upgrade or Pi reflash — a one-time ~5s rebuild, not worth scripting into `install-deps.sh` given the finding below.
- **But it doesn't help this soundbar**: BlueZ only ever calls `SelectConfiguration` on our SBC endpoint during negotiation, never AAC. Introspecting the *remote* device's own advertised endpoint confirms why — `busctl introspect org.bluez /org/bluez/hci0/dev_CC_6E_A4_24_E7_BC/sep2` shows `Codec = 0` (SBC) and `Capabilities` is a raw SBC-only capability blob, and it's the **only** SEP the soundbar exposes at all. (This is the "different method" the previous session's note called for — introspect the remote device's own `sep*` object under `/org/bluez/hci0/dev_.../`, not PipeWire's local `/MediaEndpoint/...` registrations, which is what the earlier attempt introspected by mistake.) **The Samsung Soundbar M550 only speaks SBC over A2DP — this is a firmware limit on the soundbar, not something fixable from the Pi side.** Codec-based latency improvement is a dead end for this specific speaker; the AAC plugin was left installed anyway since it's free (244KB, zero behavior change for SBC-only devices) and will automatically be used if a different/better speaker is ever paired here.
- **Remaining latency options**: (a) swap to a different Bluetooth speaker that actually advertises aptX/LDAC/AAC — the build recipe above now makes the Pi side a non-issue; (b) bypass A2DP latency entirely via wired output (analog/optical) if the soundbar has such an input; (c) accept SBC and compensate for its fixed latency in software — see next point.
- **Latency measurement, not yet done**: proposed approach reuses existing infra — extend `make_drift_test.sh`'s video (already has a per-second visual flash) with a synchronized audio click at the same instants, play it, film screen+speaker together with a phone at high frame rate, count the frame gap between the visual flash and audible click in the recording. Once measured, `mpv --audio-delay=<negative seconds>` compensates by delaying video to match the now-known-fixed audio lag.

### pi3: frame-timing / "hopping" investigation (2026-09-01/02) — board-isolated, root cause still open

**Symptom**: pi3's video visibly stutters/judders ("hopping") during playback, on both its real ~22Mbps 4K/24fps HEVC content and (less severely but still measurably) on a much lighter synthetic test file. Not present on pi1/pi2.

**Measurement method** (reusable — this is the actual diagnostic tool, not a one-off): mpv's own `mistimed-frame-count` property, read live over its JSON IPC socket, is a direct measure of real page-flip/vsync presentation timing — how many frames were displayed at the wrong time relative to their target — independent of decode throughput (`estimated-vf-fps` staying pegged at the exact source fps the whole time confirms decode itself never falls behind; this is purely a presentation-timing problem).
```bash
# launch with an IPC socket (add to any mpv invocation):
--input-ipc-server=/tmp/mpv-diag.sock
# then poll:
echo '{"command":["get_property","mistimed-frame-count"]}' | nc -U -w1 /tmp/mpv-diag.sock
```
Baseline on pi3's real content: climbs ~50-60 counts per 15s window against ~360 frames displayed in that window (**~14-17% of frames mistimed**), reproduced identically across every retest this session (10+ separate measurements). Baseline on a known-good Pi on the same content: **flat or near-flat (0-3 counts per 15s, effectively 0%)**.

**Ruled out, with evidence** (each independently tested and eliminated):
- **DRM refresh-rate/cadence mismatch** — real bug, found and fixed early (video was 24fps, `DRM_MODE` was set to `25Hz`, a non-integer ratio); fixing it to an exact `24.00Hz` match did not resolve the deeper issue, it was a separate, smaller problem layered on top.
- **CPU load** — pi3 shows ~300% CPU (of 4 cores) during 4K playback, but so does a **confirmed-clean** pi1 session on equivalent content; CPU cost of the DRM VO's software color-conversion path (`zimg`, 3 worker threads, both Pis) is identical and not the differentiator.
- **Throttling** — `vcgencmd get_throttled` = `0x0` continuously sampled through sustained peak load on pi3; never throttled, clock held at full 2.4GHz.
- **Storage read speed** — pi1 and pi3 both ~85-88MB/s sequential (`dd ... iflag=direct`), same SD card model (SC32G), both far above the ~3MB/s the file needs.
- **Background processes / Bluetooth** — confirmed via DRM debugfs (`/sys/kernel/debug/dri/1/clients`) that mpv is the *only* DRM client during every test; Bluetooth reconnect service had already exhausted its retry budget and was fully idle; audio routes cleanly to HDMI with zero PipeWire errors.
- **Board/OS/kernel/mpv build** — same Pi 5 Model B Rev 1.1, same Debian 13 (trixie), same kernel `6.18.34+rpt-rpi-2712`, byte-identical `config.txt`. mpv build genuinely *did* differ (pi1's binary has `vaapi`/`vaapi-drm` compiled in, pi3's didn't — a real dependency-drift bug, not intentional) — **copying pi1's exact mpv binary onto pi3 made no difference** (still ~15% mistimed), ruling out the mpv build itself.
- **HDMI port / DRM plane capabilities** — both use connector `HDMI-A-1`/encoder 34/CRTC 94, both select the identical overlay plane 107 for drmprime scanout, and `modetest`'s full format list for that plane is byte-identical between the two Pis (both support NV12 etc.) — no plane-capability mismatch.
- **Time sync (chrony/PTP/timesyncd)** — identical `timedatectl` status on both, `systemd-timesyncd` inactive on both (not competing with chrony), no PTP actually running on pi1 at the time of testing either — nothing to explain a difference.
- **Debian Lite vs Desktop image** — the leading hypothesis for most of the session. Two sub-hypotheses, both tested and **both ruled out**:
  - *logind seat*: pi3's bare `standalone-video.service` has no console/tty session and thus no real `logind` seat (this is the same root cause as the earlier Bluetooth `seat-monitoring` bug). Temporarily configured tty1-autologin on pi3 (mirroring pi1/pi2 exactly) to give it a genuine seat (`loginctl` confirmed `SEAT=seat0`) — **no change** (~16% mistimed, same as ever). Fully reverted afterward (autologin config, `.bash_profile` removed, `standalone-video.service` restored).
  - *the OS image itself*: imaged pi1's entire SD card (`dd` from a card reader, full 32GB raw clone) and wrote it onto pi3's card, then reconfigured it back into a standalone pi3 (hostname, DHCP networking instead of pi1's static IP, disabled 2-Pi sync services, re-enabled `standalone-video.service`/`bluetooth-reconnect.service`, recreated `standalone.env`, restored pi3's actual video content, re-added the WirePlumber headless-Bluetooth override which pi1's image never needed). Now running an OS **byte-identical** to a known-working pi1. **No change** — same ~14-17% mistimed rate. This conclusively ruled out Lite-vs-Desktop and every other OS/software difference.
- **Firmware version** — pi3's board was on `2026-05-11`; updated to the latest available (`2026-05-26`) via `rpi-eeprom-update -a` + reboot — no change. (A further downgrade attempt to `2025-12-08`, the nearest archived older image, triggered a boot failure — see incident note below — so that specific data point was never collected.)

**The one test that produced a real, clean, reproducible difference — physical board swap**: moved *only the SD card* (the one already proven byte-identical to pi1) from pi3's physical board into pi1's physical board, keeping pi1's cable, display, and power supply completely unchanged (confirmed explicitly by the user, not assumed). Result: **0 mistimed frames over 15s (1→1)** — completely clean, on the exact same file that shows ~15% mistimed on pi3's own board. Moved back (cards restored to original boards) and pi3's board immediately reproduced the same ~15% rate again. **This is the most controlled, single-variable result of the entire investigation**: identical SD card, cable, display, PSU — the only thing that changed was which physical Raspberry Pi 5 board was running it.

**Open lead, not yet chased down — MFG_VER mismatch.** During the firmware downgrade attempt, `rpi-eeprom-update` printed: `WARNING: Bootloader image version MFG_VER: 0 is older than the board manufacture version (1)`. This means pi3's board reports a **manufacture-version marker of 1**, while the firmware images being tested were built assuming version 0 — i.e. pi3's board is from a genuinely different (newer) manufacturing batch than whatever baseline the firmware/tooling on hand assumes, despite both boards reporting the same superficial `Raspberry Pi 5 Model B Rev 1.1` string. **This was never actually compared against pi1's board's own MFG_VER** (check via `sudo rpi-eeprom-config` or equivalent — look for a manufacture/board-version field), and never investigated further. Given the user's stated concern — that this might not be a one-off defective unit but something that recurs on *every new* Pi 5 purchased going forward (newer purchases will systematically be from newer manufacturing batches) — this is the most promising concrete thread for a fresh session to pull on: whether there's a known hardware-revision-dependent VC4/display-timing calibration difference, whether newer-batch boards need a different EEPROM *config* (not just firmware image version — `rpi-eeprom-config` has separate config fields from the firmware blob itself) or a `config.txt` overlay change, and whether this is documented anywhere in Raspberry Pi's own errata/forums for boards at this manufacture-version tier.

**Firmware recovery incident (cautionary, resolved)**: the `2025-12-08` firmware downgrade attempt (staged via `rpi-eeprom-update -f <file> -d`, applied on reboot) left pi3 unable to boot — ACT LED blinking a repeating 8-count pattern (Raspberry Pi's documented ROM-bootloader boot-failure code), almost certainly *because* of the MFG_VER mismatch above (deliberately flashing firmware older than the board's own manufacture-version marker). Recovered cleanly via Raspberry Pi Imager's **Misc utility images → Bootloader → SD Card Boot** recovery image (rapid continuous LED blinking = documented success signal, distinct from the paused/counted failure pattern) — the ROM-level first-stage bootloader lives in mask ROM on the SoC, is unaffected by SPI EEPROM corruption, and is specifically designed to recover from exactly this failure mode. The recovery process reset pi3's board firmware back to `2026-05-11` (its original pre-session version) as a side effect. **Do not attempt another arbitrary-old firmware downgrade on this board without addressing the MFG_VER mismatch first** — same failure is likely to recur.

**Current state**: pi3 is fully rebuilt and working (as the OS-identical-to-pi1 clone, reconfigured back to standalone mode — hostname, DHCP, `standalone-video.service`/`bluetooth-reconnect.service` enabled, `standalone.env` recreated, original video content restored, WirePlumber Bluetooth override reapplied) but **still exhibits the ~15% mistimed-frame rate**, since the board swap conclusively showed this is the specific physical board's fault, not anything in the OS. Bluetooth needs re-pairing (pairing state doesn't survive an SD card wipe) and the AAC codec plugin needs rebuilding if wanted again (both trivial, see recipes above). pi1's board (currently proven clean) is running the pi3 identity/content; the original pi3 board is set aside, unused.

**Recommended next steps for a fresh session** (superseded — see 2026-09-02 follow-up below):
1. ~~Compare `sudo rpi-eeprom-config`...~~ — done, see below (the field isn't in `rpi-eeprom-config`; it's `/proc/device-tree/chosen/rpi-min-boot-ver`).
2. ~~Search Raspberry Pi's own forums/GitHub issues/errata for `MFG_VER`...~~ — done, see below.
3. ~~If a newer-batch-specific config or overlay fix exists, apply it...~~ — done, see below: no such fix exists to apply.
4. ~~If no such fix exists, this really is most likely a defective/out-of-spec unit...~~ — see below for the actual conclusion; it's more specific than "defective."

### Follow-up (2026-09-02): MFG_VER confirmed as a real batch marker; found and fixed an unrelated concurrent bug; hardware conclusion holds

By this session, both boards had already been redeployed back to their normal identities without a dedicated handoff note: pi1's board (config.env `ROLE=master`, the old 2-Pi sync setup) is a genuinely different physical board from pi3's (the original defective board — confirmed by firmware date `2026-05-11`, matching where the earlier recovery left it — now active again as standalone pi3, `~/pi-video-sync/standalone.env`, uptime 12h+ at session start). If picking this up again, verify current identity via `cat /proc/device-tree/serial-number` on each board rather than trusting hostnames alone — they get reassigned.

**MFG_VER quantified.** `sudo rpi-eeprom-config` does *not* expose a manufacture-version field on either board (both print an identical, minimal `[all]` block — `BOOT_UART`, `BOOT_ORDER`, `NET_INSTALL_AT_POWER_ON`). The actual field is device-tree, not EEPROM config: `/proc/device-tree/chosen/rpi-min-boot-ver` — **present and reading `1` on pi3's board, absent entirely on pi1's board** (absent means 0, per `rpi-eeprom-update`'s own source, `/usr/bin/rpi-eeprom-update` line ~547). This is a real, OTP-backed hardware batch marker, not a config-file difference.

**What MFG_VER 1 means, per Raspberry Pi's own bootloader changelog** (`raspberrypi/rpi-eeprom`, `firmware-2712/release-notes.md`): the 2026-05-11 release ("Set bootloader mfg version id to 1") introduced this marker specifically to flag boards manufactured with a **new SDRAM variant**, alongside a paired Broadcom SDRAM-tuning firmware update to v4.72 in the same cycle. pi3's board being MFG_VER 1 and pi1's being un-marked means they are, per Raspberry Pi's own tooling, from different SDRAM manufacturing batches — not just cosmetically different serials.

**Why re-flashing won't help further**: the SDRAM 4.72 tuning fix shipped in the *exact* firmware pi3 is currently running (`2026-05-11`). Checked the full changelog from 2026-05-11 through 2026-08-12 (latest at time of check) — no later release touches Pi5 SDRAM/DDR tuning at all (one DDR-related entry on 2026-06-17 is Pi4-specific). So the batch-appropriate fix is already active; there is nothing newer to flash. This is consistent with last session's finding that updating to `2026-05-26` made no measurable difference. Do not spend more time on firmware updates for this specific symptom.

**Found and fixed a real, separate bug while investigating**: pi3's board still had `tty1` autologin active (`/etc/systemd/system/getty@tty1.service.d/autologin.conf`), running continuously since that morning's boot — meaning `.bash_profile` → `autostart-client.sh` → the legacy `client.py` had been launching its own `mpv` this entire time, *concurrently* with `standalone-video.service`'s own `mpv`, both fighting over the same DRM connector (confirmed via `/sys/kernel/debug/dri/1/clients`: with both running, the surviving process showed `master=n`, i.e. it wasn't even cleanly holding the display). The 2026-09-01/02 session's claim to have reverted this ("autologin config, `.bash_profile` removed, `standalone-video.service` restored") either didn't stick or didn't survive the later SD-card recovery — **never actually re-verified after the recovery**. Fixed properly this time: removed the autologin drop-in (`sudo systemctl daemon-reload` + restart `getty@tty1.service`), commented out the `autostart-client.sh` source line in `.bash_profile` with a dated note explaining why. Confirmed fix: `standalone-video.service`'s `mpv` now shows `master=y a=y` as the sole DRM client on restart.

**This bug was not the root cause, though — confirmed by a clean controlled re-test.** After the fix (single DRM client, no contention), re-ran the `mistimed-frame-count` test. To rule out the earlier "different monitor" confound entirely, found a resolution/refresh mode supported by *both* pi1's and pi3's currently-attached monitors — `1920x1080@60.00Hz` — copied pi3's actual video file to pi1 (`scp` relayed through the dev machine; direct pi-to-pi scp fails, no shared key), and ran the identical `mpv` invocation (`--hwdec=drm-copy --vo=drm --drm-mode=1920x1080@60.00 --video-sync=display-resample --loop`) on both boards with the same file:
- **pi1: 1 mistimed frame total over 30s** (~1800 frames displayed) — clean, matches every prior pi1 baseline.
- **pi3, same file, same mode, single clean `mpv` process, no contention: 53 mistimed at t=0s (i.e. already accumulating during the ~8s warm-up), 111 at t=15s, 181 at t=30s** — roughly 6-8% of frames mistimed per window, plus 19 genuine frame drops in one 15s window. Lower than the ~15% seen at native 4K/24, consistent with lower resolution reducing (but not eliminating) memory-bandwidth pressure, but still dramatically worse than pi1's near-zero baseline on the exact same content, mode, and mpv flags.

**Conclusion**: the double-mpv bug was real and worth fixing (now fixed permanently), but it was a red herring for *this* symptom — it doesn't explain the differential. The board-swap result from 2026-09-01/02 stands, now with the process-contention confound eliminated and reproduced at a second, much lower-bandwidth resolution/refresh combination. This is a genuine, reproducible hardware difference between the two physical boards, most likely explained by the confirmed MFG_VER/SDRAM-batch difference — i.e., a real characteristic of pi3's specific memory chip, not a bug fixable in software or firmware. Given mistimed-rate dropped (not vanished) at lower resolution, memory-bandwidth pressure is plausibly still part of the mechanism even if the underlying board sensitivity itself isn't fixable.

**Practical next step, if pursuing further**: since this looks like a hardware sensitivity to memory-bandwidth pressure rather than an outright broken board, the actionable path for "getting the 4K file running properly on pi3" is likely a *mitigation*, not a fix — reduce the memory-bandwidth cost of the actual playback pipeline (e.g., a lower-bitrate/lower-resolution re-encode of the source file, or reducing/avoiding the CPU-side `zimg` color conversion pass if a GPU-side path is available for this content) and re-measure `mistimed-frame-count` at the real production settings to see how much of the ~15% gap actually closes. If it doesn't close enough to be visually acceptable, this remains an RMA candidate — but now backed by a specific, credible technical reason (documented SDRAM-batch marker) rather than "unexplained defect," which is useful framing for a return/replacement request.

**State at end of this session**: both boards restored to how they were found (pi3 back on `standalone-video.service` only, autologin fix is permanent; pi1's `client.py`/`server.py` relaunched manually since they were running before intervention — not proven to be systemd-managed, so won't survive a reboot of pi1 without checking `.bash_profile` there too). Test file cleaned up from pi1.

### Outcome (2026-09-03/05): RMA'ing the original board; a third (8GB) board now serves as production pi3

Decision made: RMA the original defective board (serial `9d27aa16d028732e`) through the reseller (netonnet.no) rather than keep debugging — the board-swap evidence above is sufficient grounds regardless of whether the SDRAM-batch theory is provably systemic. No community reports were found tying `MFG_VER 1`/`rpi-min-boot-ver` to this kind of symptom, and there's no way to pre-verify a new purchase's manufacture batch before buying, so "is this systemic to all new-batch Pi 5s" remains genuinely open — treated as a separate, lower-priority question, not a blocker for shipping this unit back.

**A third physical Raspberry Pi 5 surfaced during this** (serial `5817818f440fbae7`) — a different class of board entirely: 8GB (revision `d04171`, vs `c04171`/4GB on both pi1 and the original pi3), no `MFG_VER` marker at all (like pi1), and older firmware (`2025-05-08`, predating the whole MFG_VER mechanism). Booting pi3's actual SD card on it reproduced **0 mistimed frames, 0 drops, exact 24.000fps** at native `3840x2160@24.00` — a third clean result against the one consistently-bad board, reinforcing (not proving) that this is unit-specific rather than universal to new stock.

**This third board is now the production standalone pi3** — same SD card, so `standalone.env`/hostname/services needed no changes, just verification: `calibrate-drm-mode.py` independently confirmed `DRM_MODE=3840x2160@24.00` is still the optimal pick (zero cadence error, zero resolution penalty) for whatever display is attached, and a fresh `mistimed-frame-count` re-test after moving it to the actual projector came back clean (2 total over 30s, flat, 0 drops) — same result pattern as every other clean board. Network address is DHCP-assigned and has changed before (`.4` → `.5`); don't assume it's stable — verify with `arp -a` / re-resolve rather than trusting a cached IP.

**Before shipping the original board back**: pull its SD card first (don't ship customer content/config with the board) — it's no longer in the card, since the production card now lives in the third board.

### pi1/pi2 frame-timing digression (2026-09-05) — a mid-session attribution error, corrected; MFG_VER pattern actually strengthened

Asked to restart pi1/pi2 (the 2-Pi direct-connect sync setup, unrelated boards to the pi3 story) and check frame timing. This surfaced a real, current problem worth recording — but an earlier version of this section contained a genuine mistake, described and corrected below so the wrong conclusion doesn't linger.

**What was found, correctly attributed:**

1. Both boards auto-started cleanly after a reboot (autostart path is healthy). `mistimed-frame-count` on the actual production instances showed pi1 (master) at ~10-11% and pi2 (slave) at ~35-37% at the time.
2. `client.py`'s continuous small speed-nudging is not the cause: freezing corrections entirely (stopping `sync-server.service`, which cuts the broadcast source without touching either `mpv`) left `speed` pinned at exactly 1.0 on both, and pi2's mistimed count kept climbing at essentially the same rate regardless. Ruled out as the driver.
3. The debug OSD overlay (`SYNC_OVERLAY=1`, `--osd-level=1` with a live playback-time/frame-number readout) does add real overhead — tested in isolation on **pi2**, no sync client involved: ~32-44% with OSD on vs ~28-32% with it off. Real, but not the majority cause on pi2.
4. **Correcting an error from earlier the same session**: a previous draft of this section claimed pi1 itself showed ~28-32% mistimed frames at native 4K standalone, and used that to argue the whole RMA conclusion needed walking back ("everyone's margin is thin"). That was wrong — re-checking the actual commands run, the OSD-on/off isolation test in point 3 was run on **pi2** (`192.168.2.3`), not pi1. The only standalone test actually run on pi1 was at downscaled `1920x1080@60.00` (clean, ~0%). **pi1 was never actually tested standalone at native 4K in this session**, so there was never real evidence that pi1 shares pi2/pi3's problem. Caught when the user reported pi1 looking visually smooth and pi2 visibly jumpy — which is exactly what a clean re-test after fixing pi2's OSD bug (see below) confirmed: **pi1 flat at 2 mistimed frames total over 45s (~0%), pi2 climbing steadily at ~100/15s (~27%)**, both post-reboot, both with OSD correctly off this time.

**MFG_VER checked on pi1/pi2 directly, and the pattern holds**: pi2 carries `rpi-min-boot-ver` = **1** — the same manufacture-batch marker as pi3's original (RMA'd) board — and the same firmware date (`2026-05-11`). pi1 has no marker at all (absent → 0), same as the third (8GB) board. So current standing evidence is a clean 2-for-2: both MFG_VER=1 boards (pi3-original, pi2) show heavy judder; both MFG_VER-absent boards (pi1, the third board) are clean. This is a stronger, more direct version of the same hardware-batch hypothesis from the pi3 investigation — not a reason to doubt it.

**Still genuinely open**: whether MFG_VER=1 is *reliably* bad or these two are independently-unlucky units from a batch that's merely more variable — two data points isn't large-sample proof either way. Worth keeping in mind if a third MFG_VER=1 board is ever encountered.

**Also found and fixed, unrelated to the frame-timing question**: pi2 was running an old, unpatched `controller/client.py` where `SYNC_OVERLAY=0` never actually worked (a truthy-string bug — pi1 had the fix from an earlier session, never redeployed to pi2). Fixed by copying pi1's file to pi2 directly; confirmed via reboot that pi2's `mpv` no longer launches with OSD flags. `server.py` also differs between the boards and `calibrate-drm-mode.py` is missing on pi2 — flagged, not fixed (not currently causing problems). This is at least the second time this project's rsync-based deployment has silently drifted between boards — worth a full diff across all boards' `controller/`+`scripts/` at some point.

**A real, separate deployment bug found and fixed along the way**: pi2 was running an old, unpatched `controller/client.py` — line ~536 read `if os.environ.get('SYNC_OVERLAY', ''):`, which is truthy for the *string* `'0'`, so `SYNC_OVERLAY=0` never actually disabled the overlay on pi2 even though the config said so. pi1 already had the corrected `not in ('', '0')` form from an earlier session's fix that was apparently only ever deployed to pi1. Copied pi1's file to pi2 directly (`md5sum` now matches) and confirmed via a fresh reboot: no OSD flags in pi2's `mpv` command line anymore. **`controller/server.py` also differs between the two boards, and `scripts/calibrate-drm-mode.py` is missing on pi2 entirely** — neither is currently causing a problem (pi2 doesn't run `server.py` in its slave role, and the calibrate script is one-time setup tooling), but it's evidence this project's rsync-based deployment has drifted between boards more than once now — worth a full `diff`/re-sync across all three boards' `controller/` and `scripts/` directories at some point rather than assuming they match.

**Operational lessons learned the hard way this session** (both boards were briefly left not actually displaying video, twice, before being caught and fixed):
- Killing `client.py` by PID is not a safe way to pause it: pi1/pi2 both run it via `tty1` autologin's `.bash_profile` → `exec client.py`, so killing the process kills the login shell, and the getty auto-respawns the whole chain within seconds — spawning a *new* `mpv` while an old, now-orphaned one may still hold the DRM connector, leaving the new one running "blind" (`vo-configured: false`, no visible output, but still reports a valid `time-pos` and decode state — check `vo-configured` explicitly, don't assume a running process is actually on screen).
- To actually pause a board without triggering this, stop `getty@tty1.service` *first*, then kill `client.py`/`mpv`, do whatever testing is needed, then `systemctl start getty@tty1.service` again to bring it back cleanly.
- `sync-server.service`'s playback-state tracking is in-memory only (populated by snooping `play.py`'s own broadcasts) — restarting it wipes that state, so it stops broadcasting sync messages entirely (thinking nothing is playing) until `sync-autoplay.service` is restarted to re-fire `play.py`. Don't restart `sync-server.service` casually; if you do, follow it with a `sync-autoplay.service` restart.
- `pkill` silently failed/blocked in this session's tool environment for reasons never diagnosed (exit 255, no output at all) where plain `kill <pid>` worked fine every time — prefer `kill` with explicit PIDs over `pkill -f` patterns here.

---

## Pi4 fleet-member investigation (2026-09-06) — hardware decode confirmed, severe unexplained jitter, likely wrong software stack

Context: exploring adding Pi4 boards to the fleet (H.264 was the original ask, but Pi4's hardware decode is H.264-up-to-1080p60 / HEVC-up-to-4Kp60 only — confirmed against Raspberry Pi's own product brief — so HEVC, same as the Pi5 boards, is the only codec with real 4K hardware decode on Pi4 too; there was never a case for a separate H.264 pipeline). Also checked this project's own git history back to the initial commit (`d774b0e`, Feb 2026) — it has been Pi5-only since day one, no Pi4-origin evidence anywhere in this repo.

### Setup

First attempt was on a Desktop image (matches how pi1/pi2 originally started, later stripped down — only pi3 ever got a clean from-scratch Lite install). Desktop's `lightdm`+`labwc` compositor holds DRM master at boot, so `--vo=drm` can never acquire it (`Failed to acquire DRM master: Permission denied`) — this is a hard blocker, not a workaround-able config issue, without stopping the graphical session. Reimaged as Lite to match the rest of the fleet and avoid stacking an unknown Desktop-specific quirk on top of an already-unknown board. `rpi_hevc_dec` loads automatically with zero special `dtoverlay` needed (contrary to some older, 2022-2023-era forum guidance suggesting `dtoverlay=rpivid-v4l2` is required — not the case on this current kernel, `6.18.34+rpt-rpi-v8`). This project's existing `install-deps.sh`/mpv-from-source build worked unmodified on Pi4/Trixie — no Pi4-specific code changes were needed to get hardware decode itself working.

Board: Raspberry Pi 4 Model B Rev 1.5, 2GB RAM (smaller than every Pi5 in the fleet), serial `10000000b86031c1`.

**Passwordless sudo isn't set up by default the way it apparently is on the rest of the fleet** — needed `echo 'pipe ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010_pipe-nopasswd` run manually (twice — once per image, Desktop then Lite) before any automation could proceed.

### Hardware decode: confirmed genuinely working

`grep -i "Using hardware decoding" mpv.log` → `Using hardware decoding (drm-copy)`, `hwdec-current: drm-copy` (not software fallback), decode locked at exact 25.000fps. Same driver family, same device nodes (`/dev/media2`, `/dev/video19`) as Pi5. No mpv/flag changes needed — `--hwdec=drm-copy --vo=drm` works unmodified on Pi4.

### Problem 1 (resolved): thermal throttling, board was passively cooled and enclosed

Initial test showed `throttled=0xe0006`/`0xe0008` (currently under-voltage-capped AND thermally throttled, plus history bits), 84°C, and playback genuinely running at **~31% of real-time speed** (measured directly: 3.6s of `playback-time` advanced per 11.49s of wall-clock time) — this is a real, severe symptom, not just occasional jitter, quantified precisely. Root cause: CPU was pegged at ~270-290% (near-saturating all 4 cores) the whole time.

**What's actually consuming that CPU**: per-thread breakdown (`top -H -p <pid>`) showed the `vo` thread (~70%) plus three `zimg` colorspace-conversion `worker` threads (~70/60/60%) — decode itself isn't in this list at all (it's on the dedicated hardware block, off the CPU). This `zimg` conversion step is **not new or Pi4-specific** — this project's own docs already noted "CPU cost of the DRM VO's software color-conversion path (zimg, 3 worker threads, both Pis)" from the original pi3 investigation. It was simply cheap enough on Pi5's A76 cores to be invisible; on Pi4's much weaker A72 cores, the identical fixed conversion cost saturates the CPU and triggers thermal throttling.

Checked whether the conversion is avoidable: the DRM overlay/drmprime plane genuinely supports `NV12`/`YU12`/`YV12` natively (confirmed via `modetest -p`, needed installing `libdrm-tests` first — not present on a fresh image), but a debugfs state dump showed that plane sitting at `fb=0` (unused) while the *primary* plane is what's actually active — mpv is routing through `zimg` into an RGB primary-plane path instead of using the overlay plane's native YUV support directly. Most likely a format-modifier/stride mismatch between what the Pi4 decoder exports and what mpv's `drmprime` negotiation recognizes as directly usable on this SoC generation — not something fixable with a flag; would need a newer mpv/ffmpeg or real patch work to pursue further.

**Fix applied**: removed the board from its case (passive cooling, no fan). Idle temp dropped from ~84°C to 43°C immediately, and a repeat test showed clean real-time playback pace (0.997x, essentially exact), `throttled=0x0` throughout, and CPU usage during that specific window was also much lower (~72% vs ~270% before) — though note the CPU figure isn't perfectly apples-to-apples since this is variable-bitrate content and different tests landed on different scene complexity, a confound this whole investigation has run into repeatedly. **This board needs active cooling (fan) for production use** — it cannot sustain this workload passively enclosed.

### Problem 2 (NOT resolved, root cause unknown): severe frame-timing jitter persists even with thermal issue fixed

After the case-removal fix, a fresh test showed **88-163% of frames per 15s window flagged by `mistimed-frame-count`** — worse than any board in this entire project's history (the original defective pi3 board topped out around 15-59% across various tests). This is despite: clean thermal state throughout (67-68°C, `throttled=0x0`), decode still locked at exact 25.000fps, and the user visually confirming severe, obvious jumping on screen (not just a measurement artifact).

**Ruled out, in order**:
1. Thermal/throttling — clean bitmask and stable temp during this specific test.
2. Physical HDMI/power cable seating — user confirmed both fully seated.
3. Under-voltage or HDMI hotplug/disconnect events — `dmesg` showed neither during the test window (this also argues against a marginal/intermittent cable connection specifically, since that would show hotplug churn).
4. Missing `hdmi_enable_4kp60=1` in `config.txt` — the kernel itself logged `[drm] Please change your config.txt file to add hdmi_enable_4kp60.` at boot, a concrete and specific-sounding lead; added it, rebooted, confirmed the warning was gone on the next boot — **no change in jitter severity**.

**Not yet investigated**: nothing else was tried before the session ended — this is a genuinely open problem, not a red herring that's been fully chased down.

### The actual likely explanation: wrong software stack for Pi4, per prior project history

A sibling project directory (`../raspberry-pi-media`, this repo's predecessor/relative) has a `README.md` documenting a **previously working** Pi4 4K HEVC standalone player — but built on **LibreELEC (Kodi's own player engine)**, not Raspberry Pi OS + mpv. Relevant details from that doc:
- Working content there was **Main10, 10-bit** (`yuv420p10le`) — different from the Main-profile-8-bit assumption made in the Hardware Decode Requirements Checklist above (which was written from Pi5 evidence only). Kodi's decode path may differ enough from mpv's `drm-copy` path that this isn't directly transferable, but it's a data point against assuming 8-bit is required.
- That doc explicitly records that **VLC was tried first and "had difficulty with the data rate and the video quickly became choppy"** on this same hardware class — independent historical confirmation that Pi4 at 4K/HEVC is a genuinely tight fit for a naive player, not unique to today's mpv attempt.
- That doc's own "next time" section says they wanted to try mpv next — which is exactly what this project did, just built and validated Pi5-first, then retrofitted onto Pi4 today without ever validating the `--vo=drm`+`zimg` path against Pi4's older VC4 HDMI driver specifically.

**Working hypothesis for a fresh session**: the mpv+`--vo=drm` pipeline this whole project is built around may simply not be the right stack for Pi4 — Kodi/LibreELEC achieved smooth playback on this same hardware class before, where a generic player (VLC) failed with similar symptoms to what's being seen here. Pursuing this would mean either (a) scripting Kodi's own JSON-RPC/`kodi-send` remote-control interface into something equivalent to `client.py`'s drift-correction sync, or (b) accepting a Pi4 fleet member as standalone/non-synced only. Not yet decided or started.

**Full LibreELEC reimage is not required to try this.** Kodi has an official standalone **GBM** mode — no X11/Wayland/desktop session needed, boots straight into fullscreen Kodi via a systemd service, matching this project's existing `standalone-video.service` pattern exactly. Install via `sudo apt install kodi21` (or current package name) directly on the same Raspberry Pi OS Lite image already used for the rest of the fleet — no OS change needed, keeps SSH/scripting/deployment identical. GBM is documented as the most feature-complete of Kodi's three windowing backends (X11/Wayland/GBM) and the only one supporting HDR. Reference systemd setup: `graysky2/kodi-standalone-service` on GitHub, linked from Kodi's own wiki (`HOW-TO:Autostart_Kodi_for_Linux`). Kodi's JSON-RPC API is available identically whether running this way or under LibreELEC, so the sync-scripting question is unaffected by this choice. **Not yet attempted** — next concrete step for a fresh session.

### Planned next test (not yet started): Kodi on pi2 as a diagnostic, not just a Pi4 workaround

Idea from a follow-up discussion, worth running before drawing final conclusions on the pi1/pi2 MFG_VER story above: keep **pi1 on mpv** exactly as-is (it's clean, proven, no reason to touch it), and put **pi2** (the MFG_VER=1 board with persistent, unexplained jitter — see "pi1/pi2 frame-timing digression" above) on Kodi standalone/GBM instead of mpv, then try syncing the two.

**Why this is a genuine diagnostic, not just a Pi4-style workaround attempt**: it directly separates two possibilities this project has never been able to distinguish for pi2 specifically —
1. The jitter is caused by something in the mpv `--vo=drm`+`zimg` pipeline interacting badly with this board → Kodi's different GBM rendering path might sidestep it, same hope as the Pi4 case.
2. The jitter is a genuine hardware-level (SDRAM/memory-bandwidth) margin problem on this specific board → Kodi would very likely reproduce the *same* jitter, just via a different code path, since a different renderer can't fix a genuine memory-timing problem.

Either result is informative: a clean result under Kodi would reframe the whole MFG_VER/SDRAM-batch narrative built up over this project's history; the same jitter under a completely different software stack would be strong, independent confirmation it really is that board's hardware, not the render pipeline.

**Architecturally sound to mix stacks**: the sync protocol (`server.py` broadcasting a timestamp+duration formula) doesn't require identical player software on every node — each client just needs to compute its own target position and correct *its own* player against it. A Kodi-flavored counterpart to `client.py` (using Kodi's JSON-RPC `Player.*` methods instead of mpv's IPC `set_property speed`/`time-pos`) would need building — this doesn't exist yet and hasn't been scoped. mpv's IPC has a specific "smooth speed nudge without an audible pitch shift" trick this project relies on for drift correction; check whether Kodi's JSON-RPC exposes an equivalent (a playback-speed control that doesn't require a hard seek) before assuming this is a drop-in swap.

**Not yet started** — this is a plan, not a result. Next concrete steps for a fresh session: (1) install Kodi standalone/GBM on pi2 per the recipe above, (2) get a comparable test file onto it, (3) run the same `mistimed-frame-count`-equivalent measurement (Kodi doesn't have this exact mpv property — need to find Kodi's own equivalent diagnostic, likely via its debug/OSD render-stats overlay or logging), (4) only then decide whether to build the Kodi-flavored sync client.

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
