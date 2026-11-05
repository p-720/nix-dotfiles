#!/usr/bin/env python3
"""Forward /v1/* to the Strata engine's own API server, skipping the host gateway's request-body cap.

Why this exists: apps/host/server/index.mjs reads /v1/messages with readBody(req, 12*1024*1024) and
answers 500 "Request body too large" above it, so a turn carrying more than ~9 MB of base64 pictures
fails before the engine sees it. serve/server.py accepts 256 MiB (CHUNKED_BODY_MAX). The cap is not
configurable upstream: the literal is written at each call site and readBody takes the limit as a plain
argument.

Why a proxy instead of pointing clients at 18500 directly: that port is bound to 127.0.0.1 and its API
key is regenerated on every model load (native-control.mjs randomBytes(32) into a fresh instance
config), so a client's copy of it goes stale. Both are re-read here on every request.

Clients authenticate with the same key they already use for Strata's share port, read from
~/.strata/data/state.json (serving.apiKey). Without that file this proxy serves nothing.
"""
from __future__ import annotations

import glob
import http.client
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("STRATA_PROXY_BIND", "127.0.0.1")
PORT = int(os.environ.get("STRATA_PROXY_PORT", "18600"))
MAX_BODY = int(os.environ.get("STRATA_MAX_BODY_MIB", "512")) << 20
DATA = os.path.expanduser(os.environ.get("STRATA_DATA_DIR", "~/.strata/data"))
INSTANCE_GLOB = os.path.join(DATA, "native-instances", "*.json")
STATE_FILE = os.path.join(DATA, "state.json")

key_cache = {"mtime": None, "value": None}
key_lock = threading.Lock()


def host_api_key():
    """The key Strata's own share port uses, so clients keep one credential. Re-read when the file
    changes: the app rewrites it when the person regenerates it in the UI."""
    with key_lock:
        try:
            mtime = os.stat(STATE_FILE).st_mtime
        except OSError:
            return None
        if key_cache["mtime"] != mtime:
            try:
                key_cache["value"] = json.load(open(STATE_FILE)).get("serving", {}).get("apiKey")
                key_cache["mtime"] = mtime
            except (OSError, ValueError):
                return None
        return key_cache["value"]


def engine_target():
    """(host, port, api_key) of the running engine: the newest instance config, because Strata writes a
    new one with a new random key on every model load."""
    files = glob.glob(INSTANCE_GLOB)
    if not files:
        raise RuntimeError("no Strata instance config: load the model in Strata first")
    cfg = json.load(open(max(files, key=os.path.getmtime)))
    return cfg.get("host", "127.0.0.1"), int(cfg["port"]), cfg["api_key"]


def authorized(headers) -> bool:
    want = host_api_key()
    if not want:
        return False
    got = headers.get("authorization") or headers.get("x-api-key") or ""
    return got == f"Bearer {want}" or got == want


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), fmt % args))

    def do_GET(self):
        self.proxy(b"")

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        if length > MAX_BODY:
            self.reply(413, {"error": {"type": "invalid_request_error",
                                       "message": f"body over {MAX_BODY >> 20} MiB"}})
            return
        self.proxy(self.rfile.read(length))

    def proxy(self, body: bytes):
        if not self.path.startswith("/v1"):
            self.reply(404, {"error": {"type": "not_found_error", "message": "this proxy serves /v1 only"}})
            return
        if not authorized(self.headers):
            self.reply(401, {"error": {"type": "authentication_error", "message": "missing or wrong API key"}})
            return
        try:
            host, port, key = engine_target()
        except Exception as e:
            self.reply(503, {"error": {"type": "server_error", "message": str(e)}})
            return

        conn = http.client.HTTPConnection(host, port, timeout=None)
        try:
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in ("host", "content-length", "connection", "authorization")}
            headers["host"] = f"{host}:{port}"
            headers["authorization"] = f"Bearer {key}"
            headers["content-length"] = str(len(body))
            conn.request(self.command, self.path, body=body, headers=headers)
            up = conn.getresponse()
            self.send_response(up.status)
            for k, v in up.getheaders():
                if k.lower() in ("transfer-encoding", "connection", "content-length"):
                    continue
                self.send_header(k, v)
            if up.length is not None and up.length >= 0:
                self.send_header("Content-Length", str(up.length))
            else:
                # The engine answers HTTP/1.0 with no length for a streamed turn. Re-framing it as
                # "body ends when the connection closes" is the only honest option: a Content-Length of
                # None fetches fine in urllib but makes node's undici fail the whole request.
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            # HTTP/1.0 upstream: up.length is the whole body or None for a stream. Flush per chunk
            # either way, or a streamed answer sits in this buffer and the client sees nothing.
            if up.length is not None and up.length >= 0:
                left = up.length
                while left > 0:
                    chunk = up.read(min(1 << 16, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    left -= len(chunk)
            else:
                while True:
                    chunk = up.read(1 << 16)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                        # the client hung up mid-turn; the engine cancels on its own
        except Exception as e:
            try:
                self.reply(502, {"error": {"type": "server_error", "message": f"proxy to {host}:{port}: {e}"}})
            except Exception:
                pass
        finally:
            conn.close()

    def reply(self, status: int, payload: dict):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    print(f"strata proxy http://{BIND}:{PORT}/v1 -> engine (bypasses the gateway's 12 MiB body cap; "
          f"{MAX_BODY >> 20} MiB allowed)", flush=True)
    srv.serve_forever()
