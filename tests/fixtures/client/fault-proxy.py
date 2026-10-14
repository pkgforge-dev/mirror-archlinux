"""A registry proxy that breaks requests on purpose, for the client suite.

    python3 -I fault-proxy.py MODE UPSTREAM

MODE is one of:
    cut   a blob GET with no Range header gets its headers, with the full
          Content-Length, and half of its body; then the connection closes.
          A GET with a Range header is passed through. So every blob arrives
          only when the client resumes it.
    503   every request is answered 503, with no Retry-After.
    flip  the first GET of each blob gets its whole body with the last byte
          changed, so its size is right and its sha256 is wrong. Every later
          GET of that blob is passed through.
    stall the first GET with no Range header of each blob over 1 MiB gets its
          headers, with the full Content-Length, and 64 KiB of its body; then
          nothing for 40 s, and the connection closes. Every other GET is
          passed through.
    norange
          not a proxy: a plain http server for the files under UPSTREAM, a
          directory. Each GET gets the whole file with 200, whatever its Range
          header says. The first GET of each file over 1 MiB gets its
          headers, with the full Content-Length, and 64 KiB of its body; then
          nothing for 35 s, and the connection closes.

UPSTREAM is the registry, host:port, or the directory for norange. The proxy
listens on 127.0.0.1 on a port the system picks, and prints "PORT <n>" first.
Then each request is one line: "<method> <path> range=<Range header or ->".

Standard library only.
"""

import http.client
import http.server
import os
import sys
import threading
import time

MODE = sys.argv[1]
UPSTREAM = sys.argv[2]
PASS_HEADERS = ("accept", "authorization", "range", "user-agent")
SEEN = set()
SEEN_LOCK = threading.Lock()


def first_time(path):
    """True the first time the proxy sees PATH."""
    with SEEN_LOCK:
        if path in SEEN:
            return False
        SEEN.add(path)
        return True


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, code, headers, body):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def serve_file(self):
        """MODE norange: the file under UPSTREAM, whole, whatever Range says."""
        rel = os.path.normpath("/" + self.path.split("?", 1)[0]).lstrip("/")
        full = os.path.join(UPSTREAM, rel)
        if not rel or not os.path.isfile(full):
            self.answer(404, [("Content-Length", "0")], b"")
            return
        with open(full, "rb") as f:
            body = f.read()
        keep = [("Content-Type", "application/octet-stream"), ("Content-Length", str(len(body)))]
        if len(body) > 1048576 and first_time(self.path):
            self.send_response(200)
            for name, value in keep:
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body[:65536])
            self.wfile.flush()
            print("  stalled after 65536 of %d bytes" % len(body), flush=True)
            time.sleep(35)
            self.close_connection = True
            return
        self.answer(200, keep, body)

    def handle_one(self):
        rng = self.headers.get("Range")
        print("%s %s range=%s" % (self.command, self.path, rng or "-"), flush=True)
        if MODE == "norange":
            self.serve_file()
            return
        if MODE == "503":
            self.answer(503, [("Content-Length", "0")], b"")
            return
        conn = http.client.HTTPConnection(UPSTREAM, timeout=30)
        sent = {k: v for k, v in self.headers.items() if k.lower() in PASS_HEADERS}
        conn.request(self.command, self.path, headers=sent)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        keep = [(k, v) for k, v in resp.getheaders()
                if k.lower() not in ("connection", "transfer-encoding", "content-length")]
        keep.append(("Content-Length", str(len(body))))
        blob = "/blobs/" in self.path and rng is None and resp.status == 200 and len(body) > 1
        if MODE == "flip" and blob and first_time(self.path):
            body = body[:-1] + bytes([body[-1] ^ 0xFF])
            print("  last byte changed", flush=True)
            self.answer(resp.status, keep, body)
            return
        if MODE == "cut" and blob:
            self.send_response(resp.status)
            for name, value in keep:
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body[: len(body) // 2])
            self.wfile.flush()
            self.close_connection = True
            print("  cut after %d of %d bytes" % (len(body) // 2, len(body)), flush=True)
            return
        if MODE == "stall" and blob and len(body) > 1048576 and first_time(self.path):
            self.send_response(resp.status)
            for name, value in keep:
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body[:65536])
            self.wfile.flush()
            print("  stalled after 65536 of %d bytes" % len(body), flush=True)
            time.sleep(40)
            self.close_connection = True
            return
        self.answer(resp.status, keep, body)

    def do_GET(self):
        self.handle_one()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
print("PORT %d" % server.server_address[1], flush=True)
server.serve_forever()
