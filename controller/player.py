#!/usr/bin/env python3
"""
Player wrapper - Abstraction over mpv/ffplay for synchronized playback

Can be used standalone for testing or imported by the sync client.
"""

import argparse
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional


class VideoPlayer:
    """Wrapper for video playback with hardware acceleration"""

    def __init__(self, player: str = 'mpv'):
        """
        Args:
            player: 'mpv' or 'ffplay'
        """
        self.player = player
        self.process: Optional[subprocess.Popen] = None

    def play(
        self,
        video: str,
        loop: bool = False,
        fullscreen: bool = True,
        wait: bool = False
    ) -> bool:
        """
        Start video playback

        Args:
            video: Path to video file
            loop: Loop playback
            fullscreen: Play in fullscreen
            wait: Block until playback completes

        Returns:
            True if playback started successfully
        """
        if not Path(video).exists():
            print(f"Error: Video file not found: {video}")
            return False

        # Stop any existing playback
        self.stop()

        cmd = self._build_command(video, loop, fullscreen)
        print(f"Running: {' '.join(cmd)}")

        try:
            self.process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid
            )

            if wait:
                self.process.wait()
                self.process = None

            return True

        except Exception as e:
            print(f"Error starting player: {e}")
            return False

    def _build_command(self, video: str, loop: bool, fullscreen: bool) -> list:
        """Build the player command"""
        if self.player == 'mpv':
            cmd = [
                'mpv',
                '--hwdec=drm',           # Hardware HEVC decode on Pi 5
                '--vo=drm',              # Direct rendering (no X needed)
                '--no-terminal',
                '--no-osc',
                '--no-input-terminal',
                '--no-audio-display',
            ]
            if fullscreen:
                cmd.append('--fullscreen')
            if loop:
                cmd.append('--loop')
            cmd.append(video)
            return cmd

        elif self.player == 'ffplay':
            cmd = [
                'ffplay',
                '-hwaccel', 'drm',       # Hardware HEVC decode on Pi 5
                '-sync', 'ext',          # Sync to system clock (PTP-synced)
                '-autoexit',
                '-infbuf',               # Infinite buffer
                '-framedrop',            # Allow framedrop if behind
                '-loglevel', 'error',
            ]
            if fullscreen:
                cmd.append('-fs')
            if loop:
                cmd.extend(['-loop', '0'])
            cmd.append(video)
            return cmd

        else:
            raise ValueError(f"Unknown player: {self.player}")

    def stop(self):
        """Stop playback"""
        if self.process:
            try:
                os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
                self.process.wait(timeout=2)
            except:
                try:
                    os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
                except:
                    pass
            self.process = None

    def is_playing(self) -> bool:
        """Check if playback is active"""
        if self.process:
            return self.process.poll() is None
        return False

    def wait(self):
        """Wait for playback to complete"""
        if self.process:
            self.process.wait()
            self.process = None


def play_at_time(
    video: str,
    start_time: float,
    player: str = 'mpv',
    loop: bool = False
) -> VideoPlayer:
    """
    Start playback at a specific Unix timestamp

    This is the core sync function - it waits until the specified time
    and then starts playback as precisely as possible.

    Args:
        video: Path to video file
        start_time: Unix timestamp to start at
        player: 'mpv' or 'ffplay'
        loop: Loop playback

    Returns:
        VideoPlayer instance
    """
    now = time.time()
    wait_time = start_time - now

    if wait_time < 0:
        print(f"Warning: Start time is {-wait_time:.3f}s in the past")
        wait_time = 0

    if wait_time > 0:
        print(f"Waiting {wait_time:.3f}s until start time...")

        # Coarse wait (sleep)
        if wait_time > 0.1:
            time.sleep(wait_time - 0.1)

        # Fine wait (busy loop for precision)
        while time.time() < start_time:
            pass

    print(f"Starting at {time.time()}")

    vp = VideoPlayer(player)
    vp.play(video, loop=loop)
    return vp


def main():
    """Standalone player for testing"""
    parser = argparse.ArgumentParser(description='Video player with hardware acceleration')
    parser.add_argument('video', help='Path to video file')
    parser.add_argument('--player', choices=['mpv', 'ffplay'], default='mpv',
                        help='Player to use (default: mpv)')
    parser.add_argument('--loop', '-l', action='store_true', help='Loop playback')
    parser.add_argument('--no-fullscreen', action='store_true', help='Disable fullscreen')
    parser.add_argument('--at', type=float, default=None,
                        help='Start at Unix timestamp (for sync testing)')
    parser.add_argument('--delay', '-d', type=float, default=None,
                        help='Start after delay seconds')
    args = parser.parse_args()

    if args.at:
        start_time = args.at
    elif args.delay:
        start_time = time.time() + args.delay
    else:
        start_time = None

    if start_time:
        vp = play_at_time(args.video, start_time, args.player, args.loop)
        try:
            vp.wait()
        except KeyboardInterrupt:
            vp.stop()
    else:
        vp = VideoPlayer(args.player)
        vp.play(args.video, loop=args.loop, fullscreen=not args.no_fullscreen, wait=True)


if __name__ == '__main__':
    main()
