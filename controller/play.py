#!/usr/bin/env python3
"""
Play command - Trigger synchronized playback from the command line

Can be run from any machine on the network to send commands to all clients
via UDP broadcast.
"""

import argparse
import json
import socket
import time


def broadcast_play(
    video: str,
    delay: float,
    loop: bool,
    duration: float,
    port: int
):
    """Broadcast a play command directly via UDP"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    start_time = time.time() + delay

    message = {
        'type': 'play',
        'video': video,
        'start_at': start_time,
        'loop': loop,
        'duration': duration,
    }

    print(f"Broadcasting play command:")
    print(f"  Video: {video}")
    print(f"  Start at: {start_time} (in {delay:.1f}s)")
    print(f"  Loop: {loop}")
    if duration:
        print(f"  Duration: {duration}s")

    # Broadcast multiple times for reliability
    data = json.dumps(message).encode()
    for _ in range(3):
        sock.sendto(data, ('<broadcast>', port))
        time.sleep(0.01)

    sock.close()
    print("Command sent.")


def broadcast_stop(port: int):
    """Broadcast a stop command directly via UDP"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    message = {'type': 'stop'}
    data = json.dumps(message).encode()

    for _ in range(3):
        sock.sendto(data, ('<broadcast>', port))
        time.sleep(0.01)

    sock.close()
    print("Stop command sent.")


def broadcast_sync(
    video: str,
    start_time: float,
    loop: bool,
    duration: float,
    port: int
):
    """Broadcast a sync command to trigger drift correction"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    message = {
        'type': 'sync',
        'video': video,
        'start_time': start_time,
        'loop': loop,
        'duration': duration,
        'server_time': time.time(),
    }

    data = json.dumps(message).encode()
    sock.sendto(data, ('<broadcast>', port))
    sock.close()
    print("Sync command sent.")


def main():
    parser = argparse.ArgumentParser(
        description='Trigger synchronized video playback',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s /videos/movie.mp4                    # Play with 2s delay
  %(prog)s /videos/movie.mp4 --delay 5          # Play with 5s delay
  %(prog)s /videos/movie.mp4 --loop             # Play in loop
  %(prog)s /videos/movie.mp4 --loop --duration 3600  # 1hr looping video
  %(prog)s --stop                               # Stop playback

For drift correction on long videos, run the server with --sync-interval:
  python3 server.py --sync-interval 10          # Sync every 10 seconds
"""
    )
    parser.add_argument('video', nargs='?', help='Path to video file (on the Pis)')
    parser.add_argument('--delay', '-d', type=float, default=2.0,
                        help='Seconds to wait before starting (default: 2.0)')
    parser.add_argument('--loop', '-l', action='store_true',
                        help='Loop the video')
    parser.add_argument('--duration', type=float, default=None,
                        help='Video duration in seconds (for accurate loop sync)')
    parser.add_argument('--stop', action='store_true',
                        help='Stop playback instead of starting')
    parser.add_argument('--port', '-p', type=int, default=5001,
                        help='UDP broadcast port (default: 5001)')
    args = parser.parse_args()

    if args.stop:
        broadcast_stop(args.port)
    elif args.video:
        broadcast_play(args.video, args.delay, args.loop, args.duration, args.port)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
