#!/usr/bin/env python3
"""
Sync Server - Coordinates synchronized video playback across multiple Pis

Runs on the master Pi. Clients connect and receive playback commands.
Uses UDP broadcast for low-latency message delivery.

With --sync-interval, periodically broadcasts current playback state
so clients can correct drift or late-joiners can sync up.
"""

import argparse
import json
import socket
import threading
import time
from pathlib import Path
from typing import Optional


class PlaybackState:
    """Tracks current playback state for sync broadcasts"""

    def __init__(self):
        self.video: Optional[str] = None
        self.start_time: Optional[float] = None  # Unix timestamp when playback started
        self.loop: bool = False
        self.duration: Optional[float] = None  # Video duration in seconds (if known)

    def clear(self):
        self.video = None
        self.start_time = None
        self.loop = False
        self.duration = None

    def is_playing(self) -> bool:
        return self.video is not None and self.start_time is not None

    def get_position(self) -> Optional[float]:
        """Calculate current playback position in seconds"""
        if not self.is_playing():
            return None

        elapsed = time.time() - self.start_time

        if self.loop and self.duration and self.duration > 0:
            # Wrap position for looping video
            return elapsed % self.duration

        return elapsed

    def to_dict(self) -> dict:
        return {
            'type': 'sync',
            'video': self.video,
            'start_time': self.start_time,
            'loop': self.loop,
            'duration': self.duration,
            'server_time': time.time(),  # Include server time for clock comparison
        }


class SyncServer:
    def __init__(
        self,
        port: int = 5000,
        broadcast_port: int = 5001,
        sync_interval: float = 0
    ):
        self.port = port
        self.broadcast_port = broadcast_port
        self.sync_interval = sync_interval  # 0 = disabled
        self.clients: dict[str, dict] = {}  # addr -> client info
        self.running = False
        self.playback = PlaybackState()

        # TCP socket for client registration
        self.tcp_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

        # UDP socket for broadcast commands
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def start(self):
        """Start the sync server"""
        self.tcp_socket.bind(('0.0.0.0', self.port))
        self.tcp_socket.listen(10)
        self.running = True

        print(f"Sync server listening on port {self.port}")
        print(f"Broadcast port: {self.broadcast_port}")
        if self.sync_interval > 0:
            print(f"Position sync interval: {self.sync_interval}s")
        else:
            print("Position sync: disabled (use --sync-interval to enable)")
        print("Waiting for clients...")
        print()

        # Start client handler thread
        handler_thread = threading.Thread(target=self._handle_clients, daemon=True)
        handler_thread.start()

        # Snoop our own broadcast port so play.py commands update PlaybackState.
        # play.py broadcasts directly without going through server.play(), so without
        # this the sync broadcast loop never fires (is_playing() stays False).
        udp_listener = threading.Thread(target=self._udp_listener_loop, daemon=True)
        udp_listener.start()

        # Start sync broadcast thread if enabled
        if self.sync_interval > 0:
            sync_thread = threading.Thread(target=self._sync_broadcast_loop, daemon=True)
            sync_thread.start()

        # Main command loop
        self._command_loop()

    def _sync_broadcast_loop(self):
        """Periodically broadcast playback state for drift correction"""
        while self.running:
            time.sleep(self.sync_interval)

            try:
                if self.playback.is_playing():
                    self.broadcast(self.playback.to_dict())
            except OSError as e:
                # A transient network blip (e.g. "Network is unreachable" during a
                # DHCP hiccup) used to raise out of this loop uncaught, silently
                # killing the thread for good — the service kept reporting "active"
                # but never broadcast another sync packet, leaving clients to drift
                # unchecked until someone noticed and restarted it by hand. Log and
                # keep looping instead so it self-recovers once the network returns.
                print(f"Sync broadcast failed ({e}), will retry next interval")

    def _udp_listener_loop(self):
        """Snoop broadcast port to keep PlaybackState current from play.py commands"""
        recv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        recv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        recv.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        recv.bind(('', self.broadcast_port))
        recv.settimeout(1.0)

        while self.running:
            try:
                data, _ = recv.recvfrom(4096)
                msg = json.loads(data.decode())
                msg_type = msg.get('type')

                if msg_type == 'play':
                    self.playback.video = msg.get('video')
                    self.playback.start_time = msg.get('start_at')
                    self.playback.loop = msg.get('loop', False)
                    self.playback.duration = msg.get('duration')
                    print(f"[state] Playing: {self.playback.video}")
                elif msg_type == 'stop':
                    self.playback.clear()
                    print("[state] Stopped")
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    print(f"UDP listener error: {e}")

        recv.close()

    def _handle_clients(self):
        """Handle incoming client connections"""
        while self.running:
            try:
                conn, addr = self.tcp_socket.accept()
                threading.Thread(
                    target=self._handle_client,
                    args=(conn, addr),
                    daemon=True
                ).start()
            except Exception as e:
                if self.running:
                    print(f"Error accepting connection: {e}")

    def _handle_client(self, conn: socket.socket, addr: tuple):
        """Handle a single client connection"""
        try:
            # Receive client registration
            data = conn.recv(1024).decode()
            client_info = json.loads(data)

            client_id = client_info.get('id', addr[0])
            self.clients[addr[0]] = {
                'id': client_id,
                'addr': addr,
                'conn': conn,
                'connected_at': time.time()
            }

            print(f"Client connected: {client_id} ({addr[0]})")

            # Send acknowledgment with current playback state
            response = {'status': 'registered'}
            if self.playback.is_playing():
                response['playback'] = self.playback.to_dict()
            conn.send(json.dumps(response).encode())

            # Keep connection alive for status updates
            while self.running:
                try:
                    conn.settimeout(30)
                    data = conn.recv(1024)
                    if not data:
                        break
                    # Handle client messages
                    msg = json.loads(data.decode())
                    if msg.get('type') == 'status':
                        self.clients[addr[0]]['status'] = msg.get('status')
                    elif msg.get('type') == 'get_state':
                        # Client requesting current state
                        if self.playback.is_playing():
                            conn.send(json.dumps(self.playback.to_dict()).encode())
                        else:
                            conn.send(json.dumps({'type': 'state', 'playing': False}).encode())
                except socket.timeout:
                    # Send ping
                    try:
                        conn.send(json.dumps({'type': 'ping'}).encode())
                    except:
                        break
                except:
                    break

        except Exception as e:
            print(f"Client error ({addr[0]}): {e}")
        finally:
            if addr[0] in self.clients:
                print(f"Client disconnected: {self.clients[addr[0]]['id']}")
                del self.clients[addr[0]]
            conn.close()

    def broadcast(self, message: dict):
        """Broadcast a message to all clients via UDP"""
        data = json.dumps(message).encode()
        self.udp_socket.sendto(data, ('<broadcast>', self.broadcast_port))

    def play(
        self,
        video_path: str,
        delay: float = 2.0,
        loop: bool = False,
        duration: float = None
    ):
        """
        Command all clients to play a video

        Args:
            video_path: Path to video file (must exist on all clients)
            delay: Seconds to wait before starting (allows sync)
            loop: Whether to loop the video
            duration: Video duration in seconds (for loop position calculation)
        """
        start_time = time.time() + delay

        # Update playback state
        self.playback.video = video_path
        self.playback.start_time = start_time
        self.playback.loop = loop
        self.playback.duration = duration

        message = {
            'type': 'play',
            'video': video_path,
            'start_at': start_time,
            'loop': loop,
            'duration': duration,
        }

        print(f"Broadcasting play command:")
        print(f"  Video: {video_path}")
        print(f"  Start at: {start_time} (in {delay:.1f}s)")
        print(f"  Loop: {loop}")
        if duration:
            print(f"  Duration: {duration}s")

        # Broadcast multiple times for reliability
        for _ in range(3):
            self.broadcast(message)
            time.sleep(0.01)

        print("Command sent.")

    def stop(self):
        """Stop playback on all clients"""
        self.playback.clear()

        message = {'type': 'stop'}
        for _ in range(3):
            self.broadcast(message)
            time.sleep(0.01)
        print("Stop command sent.")

    def _command_loop(self):
        """Interactive command loop"""
        import sys
        if not sys.stdin.isatty():
            # Running as a service with no interactive stdin — just wait for signals
            print("Running in non-interactive mode")
            try:
                while self.running:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
            self.running = False
            print("Server shutting down...")
            self.tcp_socket.close()
            self.udp_socket.close()
            return

        print()
        print("Commands:")
        print("  play <path> [delay] [loop] [duration]  - Play video on all clients")
        print("  stop                                    - Stop playback")
        print("  status                                  - Show playback status")
        print("  list                                    - List connected clients")
        print("  sync                                    - Force sync broadcast now")
        print("  quit                                    - Exit server")
        print()

        while self.running:
            try:
                cmd = input("> ").strip()
                if not cmd:
                    continue

                parts = cmd.split()
                command = parts[0].lower()

                if command == 'play':
                    if len(parts) < 2:
                        print("Usage: play <video-path> [delay] [loop] [duration]")
                        print("  delay: seconds before start (default: 2.0)")
                        print("  loop: true/false (default: false)")
                        print("  duration: video length in seconds (for loop sync)")
                        continue
                    video_path = parts[1]
                    delay = float(parts[2]) if len(parts) > 2 else 2.0
                    loop = parts[3].lower() == 'true' if len(parts) > 3 else False
                    duration = float(parts[4]) if len(parts) > 4 else None
                    self.play(video_path, delay, loop, duration)

                elif command == 'stop':
                    self.stop()

                elif command == 'status':
                    if self.playback.is_playing():
                        pos = self.playback.get_position()
                        print(f"Playing: {self.playback.video}")
                        print(f"  Position: {pos:.2f}s")
                        print(f"  Loop: {self.playback.loop}")
                        if self.playback.duration:
                            print(f"  Duration: {self.playback.duration}s")
                    else:
                        print("Not playing")

                elif command == 'sync':
                    if self.playback.is_playing():
                        self.broadcast(self.playback.to_dict())
                        print("Sync broadcast sent")
                    else:
                        print("Nothing playing")

                elif command == 'list':
                    if not self.clients:
                        print("No clients connected")
                    else:
                        print(f"Connected clients ({len(self.clients)}):")
                        for addr, info in self.clients.items():
                            status = info.get('status', 'unknown')
                            print(f"  {info['id']} ({addr}) - {status}")

                elif command in ('quit', 'exit'):
                    self.running = False
                    break

                else:
                    print(f"Unknown command: {command}")

            except KeyboardInterrupt:
                print()
                self.running = False
                break
            except Exception as e:
                print(f"Error: {e}")

        print("Server shutting down...")
        self.tcp_socket.close()
        self.udp_socket.close()


def main():
    parser = argparse.ArgumentParser(description='Sync server for coordinated video playback')
    parser.add_argument('--port', type=int, default=5000,
                        help='TCP port for client connections (default: 5000)')
    parser.add_argument('--broadcast-port', type=int, default=5001,
                        help='UDP port for broadcasts (default: 5001)')
    parser.add_argument('--sync-interval', type=float, default=0,
                        help='Seconds between position sync broadcasts (default: 0 = disabled)')
    args = parser.parse_args()

    server = SyncServer(
        port=args.port,
        broadcast_port=args.broadcast_port,
        sync_interval=args.sync_interval
    )
    server.start()


if __name__ == '__main__':
    main()
