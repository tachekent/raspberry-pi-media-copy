#!/usr/bin/env python3
"""
Sync Client - Receives playback commands from the sync server

Runs on each Pi (including master if it also plays video).
Listens for UDP broadcast commands and executes them at the specified time.

With drift correction enabled, responds to periodic sync broadcasts
and seeks to correct any drift beyond the threshold.
"""

import argparse
import json
import os
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional


class MpvIPC:
    """Interface to mpv's JSON IPC protocol"""

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self._socket: Optional[socket.socket] = None
        self._lock = threading.Lock()
        self._request_id = 0

    def connect(self) -> bool:
        """Connect to mpv's IPC socket"""
        try:
            self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._socket.settimeout(1.0)
            self._socket.connect(self.socket_path)
            return True
        except Exception as e:
            self._socket = None
            return False

    def disconnect(self):
        """Disconnect from mpv"""
        if self._socket:
            try:
                self._socket.close()
            except:
                pass
            self._socket = None

    def _send_command(self, command: list) -> Optional[dict]:
        """Send a command and get response"""
        if not self._socket:
            if not self.connect():
                return None

        with self._lock:
            try:
                self._request_id += 1
                msg = json.dumps({
                    'command': command,
                    'request_id': self._request_id
                }) + '\n'

                self._socket.send(msg.encode())

                # Read response (may need multiple reads)
                response_data = b''
                while True:
                    chunk = self._socket.recv(4096)
                    if not chunk:
                        break
                    response_data += chunk
                    if b'\n' in response_data:
                        break

                # Parse last complete line
                lines = response_data.decode().strip().split('\n')
                for line in reversed(lines):
                    try:
                        data = json.loads(line)
                        if data.get('request_id') == self._request_id:
                            return data
                    except:
                        continue

                return None

            except Exception as e:
                self._socket = None
                return None

    def get_position(self) -> Optional[float]:
        """Get current playback position in seconds"""
        result = self._send_command(['get_property', 'time-pos'])
        if result and 'data' in result:
            return result['data']
        return None

    def seek(self, position: float):
        """Seek to exact position (no keyframe snap)"""
        # 'set_property time-pos' does an exact seek, unlike 'seek absolute'
        # which snaps to the nearest keyframe. Keyframe snap causes ±600ms
        # oscillation in drift corrections, making sync unreliable for HEVC.
        self._send_command(['set_property', 'time-pos', position])

    def get_duration(self) -> Optional[float]:
        """Get video duration in seconds"""
        result = self._send_command(['get_property', 'duration'])
        if result and 'data' in result:
            return result['data']
        return None


class SyncClient:
    def __init__(
        self,
        server_host: str,
        server_port: int = 5000,
        broadcast_port: int = 5001,
        client_id: str = None,
        player: str = 'mpv',
        drift_threshold: float = 0.03,  # 30ms default
    ):
        self.server_host = server_host
        self.server_port = server_port
        self.broadcast_port = broadcast_port
        self.client_id = client_id or socket.gethostname()
        self.player = player
        self.drift_threshold = drift_threshold
        self.running = False
        self.player_process: subprocess.Popen = None

        # Playback state tracking
        self.current_video: Optional[str] = None
        self.start_time: Optional[float] = None
        self.loop: bool = False
        self.duration: Optional[float] = None

        # Incremented on every new play/sync-start to cancel pending scheduled plays
        self._play_generation = 0

        # mpv IPC for position control
        self.ipc_socket_path = f'/tmp/mpv-sync-{os.getpid()}.sock'
        self.mpv_ipc: Optional[MpvIPC] = None

        # TCP socket for server registration
        self.tcp_socket = None

        # UDP socket for receiving broadcasts
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def start(self):
        """Start the sync client"""
        self.running = True

        # Bind UDP socket to receive broadcasts
        self.udp_socket.bind(('', self.broadcast_port))
        print(f"Listening for broadcasts on port {self.broadcast_port}")
        print(f"Drift threshold: {self.drift_threshold * 1000:.1f}ms")

        # Connect to server
        if self.server_host:
            self._connect_to_server()

        # Start broadcast listener
        print(f"Client '{self.client_id}' ready")
        print("Waiting for commands...")
        print()

        self._listen_loop()

    def _connect_to_server(self):
        """Connect to the sync server for registration"""
        try:
            self.tcp_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.tcp_socket.connect((self.server_host, self.server_port))

            # Send registration
            registration = {'id': self.client_id}
            self.tcp_socket.send(json.dumps(registration).encode())

            # Wait for acknowledgment
            response = self.tcp_socket.recv(1024).decode()
            data = json.loads(response)
            if data.get('status') == 'registered':
                print(f"Registered with server at {self.server_host}:{self.server_port}")

                # Check if server sent current playback state
                if 'playback' in data:
                    playback = data['playback']
                    print("Server has active playback, syncing...")
                    self._handle_sync(playback)

            # Start keepalive thread
            threading.Thread(target=self._keepalive, daemon=True).start()

        except Exception as e:
            print(f"Warning: Could not connect to server: {e}")
            print("Will still listen for broadcast commands")

    def _keepalive(self):
        """Handle server keepalive pings"""
        while self.running and self.tcp_socket:
            try:
                self.tcp_socket.settimeout(60)
                data = self.tcp_socket.recv(1024)
                if not data:
                    break
                msg = json.loads(data.decode())
                if msg.get('type') == 'ping':
                    # Send status update
                    status = {
                        'type': 'status',
                        'status': 'playing' if self.player_process else 'idle'
                    }
                    self.tcp_socket.send(json.dumps(status).encode())
            except socket.timeout:
                continue
            except:
                break

    def _listen_loop(self):
        """Main loop listening for broadcast commands"""
        while self.running:
            try:
                self.udp_socket.settimeout(1.0)
                data, addr = self.udp_socket.recvfrom(4096)
                message = json.loads(data.decode())
                self._handle_message(message)
            except socket.timeout:
                continue
            except KeyboardInterrupt:
                print()
                self.running = False
                break
            except Exception as e:
                print(f"Error receiving message: {e}")

        self.stop_playback()
        print("Client shutting down...")

    def _handle_message(self, message: dict):
        """Handle an incoming message"""
        msg_type = message.get('type')

        if msg_type == 'play':
            video = message.get('video')
            start_at = message.get('start_at')
            loop = message.get('loop', False)
            duration = message.get('duration')

            # play.py broadcasts 3x for reliability — ignore duplicates
            if start_at == self.start_time and video == self.current_video:
                return

            print(f"Received play command: {video}")
            print(f"  Start at: {start_at}")

            # Store state
            self.current_video = video
            self.start_time = start_at
            self.loop = loop
            self.duration = duration

            # Schedule playback
            self._schedule_play(video, start_at, loop)

        elif msg_type == 'stop':
            print("Received stop command")
            self.stop_playback()
            self.current_video = None
            self.start_time = None

        elif msg_type == 'sync':
            self._handle_sync(message)

    def _handle_sync(self, message: dict):
        """Handle sync broadcast - check and correct drift"""
        video = message.get('video')
        start_time = message.get('start_time')
        server_time = message.get('server_time', time.time())
        loop = message.get('loop', False)
        duration = message.get('duration') or self.duration  # fall back to locally stored value

        # If we're not playing anything, start playback
        if not self.player_process or self.player_process.poll() is not None:
            print(f"Sync: Not playing, starting {video}")
            self.current_video = video
            self.start_time = start_time
            self.loop = loop
            self.duration = duration
            self._start_at_position(video, start_time, loop, duration)
            return

        # If playing different video, switch
        if self.current_video != video:
            print(f"Sync: Different video, switching to {video}")
            self.current_video = video
            self.start_time = start_time
            self.loop = loop
            self.duration = duration
            self._start_at_position(video, start_time, loop, duration)
            return

        # Check position drift (mpv only)
        if self.player != 'mpv':
            return

        # Try to reconnect IPC if it was lost or never connected
        if not self.mpv_ipc:
            ipc = MpvIPC(self.ipc_socket_path)
            if ipc.connect():
                self.mpv_ipc = ipc
                print("Reconnected to mpv IPC")
            else:
                return

        # Calculate expected position
        now = time.time()
        expected_pos = now - start_time

        if loop and duration and duration > 0:
            expected_pos = expected_pos % duration

        # Get actual position
        actual_pos = self.mpv_ipc.get_position()
        if actual_pos is None:
            return

        drift = actual_pos - expected_pos

        # Check if drift exceeds threshold
        if abs(drift) > self.drift_threshold:
            print(f"Sync: Drift {drift*1000:.1f}ms exceeds threshold, seeking to {expected_pos:.3f}s")
            self.mpv_ipc.seek(expected_pos)
        else:
            # Optional: log small drift for debugging
            pass  # print(f"Sync: Drift {drift*1000:.1f}ms within threshold")

    def _start_at_position(self, video: str, start_time: float, loop: bool, duration: float = None):
        """Start playback at the correct position for sync"""
        # Cancel any pending scheduled play (e.g. waiting 2s for a play command)
        self._play_generation += 1

        now = time.time()
        position = now - start_time

        if loop and duration and duration > 0:
            position = position % duration

        if position < 0:
            position = 0

        print(f"Starting at position {position:.2f}s")

        # Stop current playback
        self.stop_playback()

        # Start new playback with initial seek
        self._play(video, loop, start_position=position)

    def _schedule_play(self, video: str, start_at: float, loop: bool):
        """Schedule video playback at the specified time"""
        now = time.time()
        wait_time = start_at - now

        if wait_time < 0:
            print(f"Warning: Start time is in the past by {-wait_time:.3f}s")
            self._start_at_position(video, start_at, loop, self.duration)
            return

        print(f"Starting in {wait_time:.3f}s...")

        self.stop_playback()
        self._play_generation += 1
        generation = self._play_generation

        def _wait_and_play():
            # Coarse sleep until 100ms before deadline
            deadline = start_at - 0.1
            while time.time() < deadline:
                if self._play_generation != generation:
                    return
                time.sleep(0.05)
            # Busy-wait final 100ms for sub-millisecond precision
            while time.time() < start_at:
                if self._play_generation != generation:
                    return
            if self._play_generation == generation:
                self._play(video, loop)

        threading.Thread(target=_wait_and_play, daemon=True).start()

    def _play(self, video: str, loop: bool, start_position: float = None):
        """Start video playback"""
        if not Path(video).exists():
            print(f"Error: Video file not found: {video}")
            return

        print(f"Starting playback: {video}")

        if self.player == 'mpv':
            log_dir = Path(__file__).parent.parent / 'logs'
            log_dir.mkdir(exist_ok=True)
            cmd = [
                '/usr/local/bin/mpv',
                # Pi 5 + rpt1 ffmpeg: V4L2 HEVC stateless via /dev/media2 + /dev/video19.
                # drm-copy: decode on hardware (render node /dev/dri/renderD128), copy frame to
                # system RAM for --vo=drm display. Does NOT need DRM master / logind seat —
                # works from both systemd services and autologin shell.
                # Pin drm-copy explicitly: --hwdec=auto wastes ~2s probing vaapi/vulkan/nvdec/vdpau.
                '--hwdec=drm-copy',
                '--vo=drm',                             # Direct display — no compositor needed
                '--fullscreen',
                '--no-terminal',
                '--no-input-terminal',
                '--no-input-default-bindings',
                f'--log-file={log_dir / "mpv.log"}',
                f'--input-ipc-server={self.ipc_socket_path}',
            ]
            # DRM_MODE env var sets the KMS output mode (overrides EDID negotiation).
            # Format: <w>x<h>@<hz>  e.g. "3840x2160@25" for production projectors,
            # "3440x1440@50" for a 21:9 dev monitor with 25fps content (50/25 = 2:1).
            # Run: mpv --vo=drm --drm-mode=help /dev/null  to list available modes.
            # Leave DRM_MODE unset to use the monitor's preferred mode.
            drm_mode = os.environ.get('DRM_MODE', '')
            if drm_mode:
                cmd.append(f'--drm-mode={drm_mode}')
            if os.environ.get('SYNC_OVERLAY', ''):
                cmd.extend([
                    '--osd-level=1',
                    '--osd-msg1=${playback-time/full}  f${estimated-frame-number}',
                    '--osd-font-size=72',
                    '--osd-color=#FFFFFFFF',
                    '--osd-back-color=#80000000',
                    '--osd-border-size=2',
                    '--osd-align-x=left',
                    '--osd-align-y=top',
                ])
            if loop:
                cmd.append('--loop')
            if start_position is not None and start_position > 0:
                cmd.append(f'--start={start_position}')
            cmd.append(video)

        elif self.player == 'ffplay':
            cmd = [
                'ffplay',
                '-hwaccel', 'drm',                      # Hardware HEVC decode
                '-fs',                                  # Fullscreen
                '-sync', 'ext',                         # Sync to system clock (PTP-synced)
                '-autoexit',                            # Exit when done
                '-infbuf',                              # Infinite buffer (don't drop frames)
                '-framedrop',                           # But allow framedrop if behind
            ]
            if loop:
                cmd.extend(['-loop', '0'])
            if start_position is not None and start_position > 0:
                cmd.extend(['-ss', str(start_position)])
            cmd.append(video)

        else:
            print(f"Unknown player: {self.player}")
            return

        try:
            # Start player process
            self.player_process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=None,           # Let mpv errors print to terminal
                preexec_fn=os.setsid  # Create new process group
            )
            print(f"Player started (PID: {self.player_process.pid})")

            # Connect to mpv IPC (with retry)
            if self.player == 'mpv':
                threading.Thread(target=self._connect_mpv_ipc, daemon=True).start()

        except Exception as e:
            print(f"Error starting player: {e}")

    def _connect_mpv_ipc(self):
        """Connect to mpv IPC socket (called in background thread)"""
        self.mpv_ipc = MpvIPC(self.ipc_socket_path)

        # Retry for up to 15s — mpv with --start=<large_pos> can take 3-5s to seek
        # and create the IPC socket. 2s was too short for late-join seeks.
        for _ in range(150):
            if self.mpv_ipc.connect():
                print("Connected to mpv IPC")

                # Get duration if not known
                if self.duration is None:
                    time.sleep(0.5)  # Wait for mpv to load file
                    self.duration = self.mpv_ipc.get_duration()
                    if self.duration:
                        print(f"Video duration: {self.duration:.2f}s")
                return
            time.sleep(0.1)

        print("Warning: Could not connect to mpv IPC after 15s")
        self.mpv_ipc = None

    def stop_playback(self):
        """Stop current playback"""
        # Disconnect IPC
        if self.mpv_ipc:
            self.mpv_ipc.disconnect()
            self.mpv_ipc = None

        # Remove IPC socket file
        try:
            Path(self.ipc_socket_path).unlink(missing_ok=True)
        except:
            pass

        if self.player_process:
            try:
                # Kill the process group to ensure children are killed too
                os.killpg(os.getpgid(self.player_process.pid), signal.SIGTERM)
                self.player_process.wait(timeout=2)
            except:
                try:
                    os.killpg(os.getpgid(self.player_process.pid), signal.SIGKILL)
                except:
                    pass
            self.player_process = None
            print("Playback stopped")


def main():
    parser = argparse.ArgumentParser(description='Sync client for coordinated video playback')
    parser.add_argument('--server', '-s', type=str, default=None,
                        help='Server hostname/IP (optional, will still listen for broadcasts)')
    parser.add_argument('--port', type=int, default=5000,
                        help='Server TCP port (default: 5000)')
    parser.add_argument('--broadcast-port', type=int, default=5001,
                        help='UDP broadcast port (default: 5001)')
    parser.add_argument('--id', type=str, default=None,
                        help='Client ID (default: hostname)')
    parser.add_argument('--player', choices=['mpv', 'ffplay'], default='mpv',
                        help='Video player to use (default: mpv)')
    parser.add_argument('--drift-threshold', type=float, default=0.03,
                        help='Max drift in seconds before seeking to correct (default: 0.03 = 30ms)')
    args = parser.parse_args()

    client = SyncClient(
        server_host=args.server,
        server_port=args.port,
        broadcast_port=args.broadcast_port,
        client_id=args.id,
        player=args.player,
        drift_threshold=args.drift_threshold,
    )

    try:
        client.start()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
