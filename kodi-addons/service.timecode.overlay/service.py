"""Persistent millisecond-precision timecode overlay.

Kodi equivalent of this project's mpv SYNC_OVERLAY (see controller/client.py,
config.env.example). Kodi has no native frame-position API, so this shows
HH:MM:SS.mmm instead of a frame count — same purpose (glance at two Pis'
screens and see if they're in sync), just millisecond precision instead of
a frame number.

Polls xbmc.Player().getTime() on a fast timer rather than waiting for a
Kodi Player callback event, since there's no built-in "tick" notification
for smooth playback position — only start/stop/seek events, which would
leave the displayed time frozen between them.

Poll interval is 40ms (one frame period at this project's 25fps content),
not the more obvious 100ms — a slower interval adds up to its own length in
staleness to the displayed number, which showed up directly as a misleading
~250ms visual gap against pi1's frame-tied mpv OSD (2026-09-07) even though
the actual measured drift was under 65ms. Keep this at or below one frame
period so the overlay itself doesn't become a source of apparent drift.
"""

import xbmc
import xbmcgui


def format_timecode(seconds: float) -> str:
    if seconds < 0:
        seconds = 0.0
    total_ms = int(round(seconds * 1000))
    h, rem_ms = divmod(total_ms, 3600000)
    m, rem_ms = divmod(rem_ms, 60000)
    s, ms = divmod(rem_ms, 1000)
    return f'{h:02d}:{m:02d}:{s:02d}.{ms:03d}'


class TimecodeOverlay(xbmcgui.WindowDialog):
    def __init__(self):
        super().__init__()
        self.label = xbmcgui.ControlLabel(20, 20, 900, 60, '', textColor='0xFFFFFFFF')
        self.addControl(self.label)

    def update_text(self, text: str):
        self.label.setLabel(text)


def run():
    monitor = xbmc.Monitor()
    player = xbmc.Player()
    overlay = TimecodeOverlay()
    overlay.show()

    try:
        while not monitor.abortRequested():
            try:
                if player.isPlayingVideo():
                    overlay.update_text(format_timecode(player.getTime()))
                else:
                    overlay.update_text('')
            except Exception:
                # Player can go away mid-call (stop/seek race) — skip this tick
                pass
            if monitor.waitForAbort(0.04):
                break
    finally:
        overlay.close()


if __name__ == '__main__':
    run()
