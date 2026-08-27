#!/usr/bin/env python3
"""Static file server for the sideload kit, with HTTP Range support.

Range is the whole point. The laptop this serves travels with him and drops
off the tailnet mid-transfer; `python -m http.server` answers a Range request
with the entire file (200, not 206), so `curl -C -` restarts from zero and a
54 MB download over a DERP relay never finishes. This adds the ~20 lines that
make resume work.
"""
import http.server
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
BIND = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8790


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def send_head(self):
        rng = self.headers.get("Range")
        if not rng:
            return super().send_head()

        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.isfile(path):
            return super().send_head()

        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if not m:
            return super().send_head()

        size = os.path.getsize(path)
        start_s, end_s = m.group(1), m.group(2)
        if start_s:
            start = int(start_s)
            end = int(end_s) if end_s else size - 1
        else:
            # suffix form: bytes=-500 means the last 500 bytes
            if not end_s:
                return super().send_head()
            start, end = max(0, size - int(end_s)), size - 1
        end = min(end, size - 1)

        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None

        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        # copyfile() would send to EOF; cap it at the requested slice.
        self.wfile.write(f.read(end - start + 1))
        f.close()
        return None

    def end_headers(self):
        if "Accept-Ranges" not in self._headers_buffer_names():
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def _headers_buffer_names(self):
        return b"".join(getattr(self, "_headers_buffer", [])).decode("latin-1")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer((BIND, PORT), RangeHandler)
    print(f"serving {ROOT} on {BIND}:{PORT}", flush=True)
    srv.serve_forever()
