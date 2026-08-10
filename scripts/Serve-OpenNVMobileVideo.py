from __future__ import annotations

import argparse
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class VideoHandler(BaseHTTPRequestHandler):
    video_path: Path
    download_name = "OpenNV-Mobile.mp4"

    def do_HEAD(self) -> None:
        self._serve(send_body=False)

    def do_GET(self) -> None:
        self._serve(send_body=True)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._common_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Range")
        self.end_headers()

    def _common_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "public, max-age=3600")

    def _serve(self, send_body: bool) -> None:
        if self.path.split("?", 1)[0] not in ("/", "/download", "/OpenNV-Mobile.mp4"):
            self.send_error(404)
            return

        size = self.video_path.stat().st_size
        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
            if not match:
                self.send_error(416)
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = int(last) if last else end
            elif last:
                length = int(last)
                start = max(0, size - length)
            if start >= size or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            end = min(end, size - 1)
            status = 206

        length = end - start + 1
        self.send_response(status)
        self._common_headers()
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Disposition", f'attachment; filename="{self.download_name}"')
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not send_body:
            return

        with self.video_path.open("rb") as source:
            source.seek(start)
            remaining = length
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    video = args.video.resolve(strict=True)
    VideoHandler.video_path = video
    server = ThreadingHTTPServer((args.bind, args.port), VideoHandler)
    print(f"Serving {video} on {args.bind}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
