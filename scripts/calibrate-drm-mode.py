#!/usr/bin/env python3
"""
Pick the best DRM_MODE for a video + connected display, and write it into
the Pi's config.

Why this matters (see README "Display Resolution and Refresh Rate"): mpv's
--vo=drm uses whatever mode the monitor negotiates via EDID if DRM_MODE is
left unset. A refresh rate that isn't an integer multiple of the video's
frame rate causes visible cadence judder (e.g. 60Hz display + 25fps video
= 2.4:1, so frames alternate between showing for 2 and 3 refreshes). A
resolution mismatch forces CPU software scaling on every frame, which is
the actual CPU bottleneck during 4K playback, not decode.

Ranking: cadence match first (judder is a hard correctness issue,
independent of CPU headroom), then resolution closest to the video's
native resolution without exceeding it (minimizes scaling cost).

Usage: scripts/calibrate-drm-mode.py [config-file]
  config-file defaults to config.env or standalone.env, whichever exists,
  in the project root.
"""
import re
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

INSTALL_DIR = Path(__file__).resolve().parent.parent

MODE_RE = re.compile(
    r"Mode \d+: (?P<w>\d+)x(?P<h>\d+)(?P<interlace>i)? \(\d+x\d+@(?P<hz>[\d.]+)Hz\)"
)


def find_config():
    for name in ("config.env", "standalone.env"):
        p = INSTALL_DIR / name
        if p.exists():
            return p
    sys.exit("No config.env or standalone.env found in the project root — run setup first.")


def read_var(config_path, key):
    for line in config_path.read_text().splitlines():
        line = line.strip()
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return None


def get_video_info(video_path):
    if not Path(video_path).exists():
        sys.exit(f"Video file not found: {video_path}")
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate",
         "-of", "default=nk=1:nw=1", video_path],
        capture_output=True, text=True, check=True,
    ).stdout.strip().splitlines()
    width, height, rate = int(out[0]), int(out[1]), out[2]
    num, den = rate.split("/")
    fps = Fraction(int(num), int(den))
    return fps, width, height


def list_drm_modes():
    out = subprocess.run(
        ["mpv", "--vo=drm", "--drm-mode=help", "/dev/null"],
        capture_output=True, text=True,
    ).stdout
    modes = []
    for line in out.splitlines():
        m = MODE_RE.search(line)
        if not m or m.group("interlace"):  # skip interlaced — different cadence math, not handled here
            continue
        w, h = int(m.group("w")), int(m.group("h"))
        hz_raw = m.group("hz")
        hz = float(hz_raw)
        # mpv's --drm-mode value is a bare "WxH@R" — NOT what --drm-mode=help
        # prints for humans ("WxH@R.RRHz"). Passing the "Hz" suffix is a fatal
        # parse error ("Must be a positive number, a string of the format
        # WxH[@R] or 'help'") — confirmed the hard way against a live Pi.
        mode_str = f"{w}x{h}@{hz_raw}"
        modes.append((w, h, hz, mode_str))
    return modes


def score(mode, fps, native_w, native_h):
    w, h, hz, _ = mode
    ratio = hz / float(fps)
    nearest = round(ratio)
    cadence_error = 1.0 if nearest == 0 else abs(ratio - nearest)

    native_pixels = native_w * native_h
    pixels = w * h
    if pixels <= native_pixels:
        res_penalty = (native_pixels - pixels) / native_pixels  # 0 = exact match, up to ~1 = tiny vs native
    else:
        res_penalty = 1.0 + (pixels - native_pixels) / native_pixels  # exceeding native is always worse than any downscale

    return (round(cadence_error, 4), round(res_penalty, 4))


def main():
    config_path = Path(sys.argv[1]) if len(sys.argv) > 1 else find_config()

    video = read_var(config_path, "VIDEO")
    if not video:
        sys.exit(f"No VIDEO= set in {config_path}")

    fps, w, h = get_video_info(video)
    print(f"Video: {video}\n  {w}x{h} @ {float(fps):.3f}fps ({fps.numerator}/{fps.denominator})")

    modes = list_drm_modes()
    if not modes:
        sys.exit("No DRM modes found — is a display actually connected?")

    ranked = sorted(modes, key=lambda m: score(m, fps, w, h))
    best = ranked[0]
    best_cadence, best_res = score(best, fps, w, h)

    print(f"\nTop candidates (cadence error, resolution penalty — lower is better in both):")
    for m in ranked[:5]:
        c, r = score(m, fps, w, h)
        marker = " <-- selected" if m is best else ""
        print(f"  {m[3]:20s} cadence={c:.4f}  res_penalty={r:.4f}{marker}")

    if best_cadence > 0.01:
        print(f"\nWarning: even the best available mode has a non-trivial cadence mismatch "
              f"({best[2]:.3f}Hz vs {float(fps):.3f}fps) — some judder may still be visible.")

    # Guard against ever writing an unusable value again (this bit a live Pi
    # once already — the "Hz" suffix in --drm-mode=help's display text isn't
    # valid in the option value itself).
    if not re.fullmatch(r"\d+x\d+@[\d.]+", best[3]):
        sys.exit(f"Refusing to write malformed DRM_MODE value: {best[3]!r}")

    text = config_path.read_text()
    new_line = f"DRM_MODE={best[3]}"
    if re.search(r"^#?DRM_MODE=.*$", text, re.M):
        text = re.sub(r"^#?DRM_MODE=.*$", new_line, text, flags=re.M)
    else:
        text = text.rstrip("\n") + f"\n{new_line}\n"
    config_path.write_text(text)

    print(f"\nSet {new_line} in {config_path}")
    if config_path.name == "standalone.env":
        print("Apply with: sudo systemctl restart standalone-video.service")
    else:
        print("Apply by rebooting, or restarting client.py on that Pi's console.")


if __name__ == "__main__":
    main()
