"""A model pack served from this Mac, for checking the Debug app's downloads without the network.

Makes up a pack (a license, a weights file of --mb megabytes, a small text file) and serves it over HTTP on
127.0.0.1 with Range requests answered, as Hugging Face's CDN does, at --rate megabytes a second, so a
download can be paused, cut off, and resumed. GET /pack.json gives the pack as the app lists packs
(`ModelPack`), with this server as its only mirror. Then, in the Debug app:

    open -g -a ".../OhMyShot Dev.app" 'ohmyshot-dev://debug/modelpack-lab'
    open -g -a ".../OhMyShot Dev.app" 'ohmyshot-dev://debug/modelpack-act?action=download'

Usage: python3 -I Tools/model-packs/lab-server.py [--port 19010] [--mb 24] [--rate 4] [--drop-after BYTES]
    --drop-after closes the first connection for the weights once that many bytes of it went out.
"""

import argparse
import hashlib
import http.server
import json
import random
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=19010)
parser.add_argument("--mb", type=float, default=24)
parser.add_argument("--rate", type=float, default=4, help="megabytes a second; 0 for as fast as it goes")
parser.add_argument("--drop-after", type=int, default=0)
parser.add_argument("--version", default="1")
parser.add_argument("--license-file", help="a real license's text to serve, to see how it reads")
args = parser.parse_args()

LICENSE = """Lab License (for testing OhMyShot's model packs only)

This pack is made up by Tools/model-packs/lab-server.py. Its weights are random bytes.
A real pack carries its model's license here, with any NOTICE and a statement of what was changed:
for example, "Converted from PaddlePaddle's PP-OCRv6 small to Core ML fp16 ML programs."
"""

if args.license_file:
    LICENSE = open(args.license_file, encoding="utf-8").read()

rng = random.Random(7)
files = {
    "LICENSE.txt": LICENSE.encode(),
    "weights/model.bin": rng.randbytes(int(args.mb * 1024 * 1024)),
    "weights/tokens.txt": "\n".join(f"token {i}" for i in range(2000)).encode(),
}
base = f"http://127.0.0.1:{args.port}/files/"
pack = {
    "id": "lab-pack",
    "version": args.version,
    "name": "Lab Text Model",
    "summary": "A pack made up on this Mac for checking downloads; it reads nothing.",
    "license": {"name": "Lab License", "file": "LICENSE.txt", "url": "https://example.com/lab-license"},
    "original": "https://huggingface.co/PaddlePaddle",
    "host": "this Mac (lab)",
    "mirrors": [base],
    "files": [{"path": p, "size": len(d), "sha256": hashlib.sha256(d).hexdigest()} for p, d in files.items()],
}
dropped = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *a):
        print(f"{self.command} {self.path} {self.headers.get('Range', '')} -> " + (format % a), flush=True)

    def do_GET(self):
        if self.path == "/pack.json":
            body = json.dumps(pack, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        name = self.path.removeprefix("/files/")
        data = files.get(name)
        if data is None:
            self.send_error(404)
            return
        start = 0
        header = self.headers.get("Range", "")
        if header.startswith("bytes="):
            start = int(header[6:].split("-")[0] or 0)
            if start >= len(data):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(data)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(data) - start))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        chunk = 64 * 1024
        sent = 0
        try:
            for offset in range(start, len(data), chunk):
                piece = data[offset:offset + chunk]
                self.wfile.write(piece)
                sent += len(piece)
                if args.drop_after and name == "weights/model.bin" and not dropped.is_set() and sent >= args.drop_after:
                    dropped.set()
                    print(f"dropping the connection after {sent} bytes", flush=True)
                    self.close_connection = True
                    self.connection.shutdown(2)
                    return
                if args.rate > 0:
                    time.sleep(len(piece) / (args.rate * 1024 * 1024))
        except (BrokenPipeError, ConnectionResetError):
            print(f"the client went after {sent} bytes", flush=True)


print(f"lab pack {pack['id']} {pack['version']}: {sum(len(d) for d in files.values())} bytes at {base}", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
