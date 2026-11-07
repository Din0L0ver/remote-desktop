"""Read the H.264 transport without injecting any keyboard or mouse input."""
import argparse
import json
import socket
import struct
import time


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--host", default="127.0.0.1")
    args.add_argument("--port", type=int, default=7777)
    args.add_argument("--duration", type=float, default=8)
    args.add_argument("--ack-delay", type=float, default=0)
    args = args.parse_args()
    frames = total = 0
    with socket.create_connection((args.host, args.port), timeout=5) as connection:
        connection.settimeout(2)
        connection.sendall(b"GET /video HTTP/1.1\r\nHost: localhost\r\n\r\n")
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("Disconnected before HTTP response")
            buffer += chunk
        header, buffer = buffer.split(b"\r\n\r\n", 1)
        assert b"200 OK" in header and b"application/x-splitkeyboard-h264" in header, header
        started = time.monotonic()
        first_frame = None
        while time.monotonic() - started < args.duration:
            while len(buffer) >= 4:
                length = struct.unpack_from(">I", buffer)[0]
                assert 13 <= length <= 8 * 1024 * 1024
                if len(buffer) < length + 4:
                    break
                payload, buffer = buffer[4:4 + length], buffer[4 + length:]
                sequence, sps, pps = struct.unpack_from(">III", payload)
                assert 0 < sps <= 65536 and 0 < pps <= 65536
                offset = 12 + sps + pps
                assert offset < len(payload)
                while offset < len(payload):
                    size = struct.unpack_from(">I", payload, offset)[0]
                    assert size > 0
                    offset += size + 4
                assert offset == len(payload)
                frames += 1
                total += length + 4
                if first_frame is None:
                    first_frame = time.monotonic() - started
                if args.ack_delay:
                    time.sleep(args.ack_delay)
                connection.sendall(json.dumps({"type": "ack", "sequence": sequence}).encode() + b"\n")
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise RuntimeError("Host closed stream")
            buffer += chunk
        elapsed = time.monotonic() - started
    assert frames > 0, "No screen frames received"
    print(json.dumps({"frames": frames, "seconds": round(elapsed, 2),
                      "received_fps": round(frames / elapsed, 2),
                      "mbps": round(total * 8 / elapsed / 1e6, 3),
                      "first_frame_ms": round(first_frame * 1000)}, indent=2))


if __name__ == "__main__":
    main()
