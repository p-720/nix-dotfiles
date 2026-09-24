#!/usr/bin/env python3
"""PomoTask rofi backend (rofi script mode). Stdlib only — no nix-shell,
no pip deps, starts in ~50ms.

Auth: the server requires an API key — read from ~/Dropbox/pomotask
(pomo_...), sent as ?key= on the WS and Authorization: Bearer on HTTP.
Set POMOTASK_KEY_FILE / POMOTASK_BASE to override (local testing).

Invocations:
  ROFI_RETV=0           -> print the list (stop entry + active timer habits)
  ROFI_RETV=1 $1        -> a listed entry was selected
  ROFI_RETV=2 $1        -> typed text matched nothing  -> quick task (calendar only)

Non-blocking:
  * the list comes from a local cache when fresh (no network for a visible delay);
    a short capped probe (2.5s) checks for a running timer to offer "stop"
  * accepting an entry spawns a detached child python (the "&") that does the
    network sends; rofi's callback returns immediately

Actions (child mode, env POMOTASK_ROFI_ACTION):
  start   $1 = habit name      -> ws timer:update + calendar start
  quick   $1 = free text       -> ws timer:update (name) + calendar start
  stop              (no arg)   -> ws timer:stop (clients relay calendar/session)

POMOTASK_ROFI_DRY=1  -> print what would be sent instead of sending (debug)
"""
import base64
import json
import os
import socket
import ssl
import sys
import time
import urllib.request
from urllib.parse import urlparse, quote

BASE = os.environ.get("POMOTASK_BASE", "https://ug.kyrgyzstan.kg/pomotask").rstrip("/")
KEY_FILE = os.environ.get("POMOTASK_KEY_FILE", os.path.expanduser("~/Dropbox/pomotask"))
DRY = os.environ.get("POMOTASK_ROFI_DRY") == "1"
CACHE_TTL = 600  # s
NET_TIMEOUT = 2.5
STOP_PREFIX = "\u23f9 "  # ⏹


def load_key():
    try:
        with open(KEY_FILE) as f:
            k = f.read().strip()
            return k if k.startswith("pomo_") else None
    except OSError:
        return None


KEY = load_key()


def _ws_url():
    # BASE may be http(s):// — map to ws(s):// so the handshake lands on
    # 443 with TLS, not port 80 (nginx 301s that to https forever).
    p = urlparse(BASE)
    scheme = "wss" if p.scheme == "https" else "ws"
    url = f"{scheme}://{p.netloc}{p.path}/ws"
    if KEY:
        url += "?key=" + quote(KEY, safe="")
    return url


WS_URL = _ws_url()


# --- minimal one-shot RFC6455 client (stdlib): enough for one send or one reply ---

def _ws_frame_send(sock, data):
    payload = data.encode()
    mask = os.urandom(4)
    header = bytearray([0x81])  # FIN + text
    n = len(payload)
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126)
        header += n.to_bytes(2, "big")
    else:
        header.append(0x80 | 127)
        header += n.to_bytes(8, "big")
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def _ws_frame_recv(sock):
    """Read one text message (handles continuation frames). Returns str or None."""
    msg = b""
    while True:
        b0 = sock.recv(1)
        if not b0:
            return None if not msg else msg.decode(errors="replace")
        fin, opcode = b0[0] & 0x80, b0[0] & 0x0F
        if opcode == 0x8:  # close
            return msg.decode(errors="replace") if msg else None
        b1 = sock.recv(1)[0]
        masked = b1 & 0x80
        length = b1 & 0x7F
        if length == 126:
            length = int.from_bytes(sock.recv(2), "big")
        elif length == 127:
            length = int.from_bytes(sock.recv(8), "big")
        key = sock.recv(4) if masked else b""
        data = b""
        while len(data) < length:
            chunk = sock.recv(length - len(data))
            if not chunk:
                break
            data += chunk
        if masked:
            data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
        if opcode in (0x1, 0x0):  # text / continuation
            msg += data
        if fin:
            return msg.decode(errors="replace")


def _ws_one(url, send_payload=None, want_reply=False, timeout=NET_TIMEOUT):
    p = urlparse(url)
    host = p.hostname
    path = p.path or "/"
    port = p.port or (443 if p.scheme == "wss" else 80)
    if p.query:
        path += "?" + p.query
    key = base64.b64encode(os.urandom(16)).decode()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        s = sock
        if p.scheme == "wss":
            ctx = ssl.create_default_context()
            s = ctx.wrap_socket(sock, server_hostname=host)
        s.settimeout(timeout)
        s.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = s.recv(4096)
            if not chunk:
                raise ConnectionError("ws handshake aborted")
            resp += chunk
        if b" 101 " not in resp.split(b"\r\n")[0]:
            raise ConnectionError("ws handshake rejected: " + resp.split(b"\r\n")[0].decode(errors="replace"))
        if send_payload is not None:
            _ws_frame_send(s, send_payload)
        if want_reply:
            return _ws_frame_recv(s)
        return None


def send_ws(payload, retries=2):
    if DRY:
        print("[dry] ws:", json.dumps(payload))
        return
    for attempt in range(retries):
        try:
            _ws_one(WS_URL, send_payload=json.dumps(payload), timeout=3)
            return
        except Exception as e:
            if attempt + 1 == retries:
                raise
            time.sleep(1)  # the prod nginx intermittently 301s mid-reload


def probe_state(timeout=NET_TIMEOUT):
    """Connect once, read the server's timer:sync, close. Returns state dict or None."""
    try:
        raw = _ws_one(WS_URL, want_reply=True, timeout=timeout)
    except Exception:
        try:
            raw = _ws_one(WS_URL, want_reply=True, timeout=timeout)
        except Exception:
            return None
    if raw is None:
        return None
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if msg.get("type") in ("timer:sync", "timer:update"):
        return msg.get("data") or {}
    return None


# --- app API ---

def cache_path():
    d = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(d, "pomotask-rofi-cache.json")


def load_cache():
    try:
        with open(cache_path()) as f:
            return json.load(f)
    except Exception:
        return None


def save_cache(habits, state):
    try:
        with open(cache_path(), "w") as f:
            json.dump({"ts": time.time(), "habits": habits, "state": state}, f)
    except Exception:
        pass


def fetch_timer_habits(timeout=NET_TIMEOUT):
    """Return {description: habit_id} for active (non-archived) timer habits."""
    headers = {"Authorization": "Bearer " + KEY} if KEY else {}
    with urllib.request.urlopen(urllib.request.Request(BASE + "/api/habits", headers=headers), timeout=timeout) as r:
        groups = json.load(r)
    out = {}
    for g in groups:
        for h in g.get("habits", []):
            # any habit type can be timed (duration-only for non-timer types)
            if not h.get("archived_at") and h.get("description"):
                out.setdefault(h["description"], h["id"])
    return out


def post_calendar(habit, event, duration_seconds=None):
    body = {"habit": habit, "event": event}
    if duration_seconds is not None:
        body["durationSeconds"] = duration_seconds
    if DRY:
        print("[dry] calendar:", json.dumps(body))
        return
    headers = {"Content-Type": "application/json"}
    if KEY:
        headers["Authorization"] = "Bearer " + KEY
    req = urllib.request.Request(
        BASE + "/api/calendar?action=timer",
        data=json.dumps(body).encode(),
        headers=headers,
        method="POST",
    )
    urllib.request.urlopen(req, timeout=3).read()


def start(habit_id, name):
    """habit_id: real id (habit) or None (quick task). name: display/title."""
    now_ms = int(time.time() * 1000)
    state = {
        "activeHabitId": habit_id,
        "name": None if habit_id is not None else name,
        "mode": "stopwatch",
        "elapsed": 0,
        "running": True,
        "startTime": now_ms,
        "elapsedBefore": 0,
    }
    try:
        send_ws({"type": "timer:update", "data": state})
    except Exception as e:
        print(f"pomotask: ws start failed: {e}", file=sys.stderr)
    try:
        # Pseudo id -1 for quick tasks (no real habit has id -1); mirrors the app.
        post_calendar({"id": habit_id if habit_id is not None else -1, "description": name}, "start")
    except Exception as e:
        print(f"pomotask: calendar start failed: {e}", file=sys.stderr)


def stop():
    try:
        send_ws({"type": "timer:stop"})
    except Exception as e:
        print(f"pomotask: ws stop failed: {e}", file=sys.stderr)


def spawn_child(action, name=None):
    """Detached child (the &) does the network; this process returns to rofi at once."""
    import subprocess
    env = dict(os.environ, POMOTASK_ROFI_ACTION=action)
    args = [sys.executable, os.path.abspath(__file__)]
    if name:
        args.append(name)
    if DRY:
        # keep it in-process so the dry output is visible (no network)
        if action == "stop":
            stop()
        elif name:
            start(None, name)
        return
    subprocess.Popen(args, env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def running_label(state, habits):
    if not state or not state.get("running"):
        return None
    if state.get("activeHabitId") is not None:
        label = next((d for d, i in habits.items() if i == state.get("activeHabitId")),
                     f"habit #{state.get('activeHabitId')}")
    else:
        label = state.get("name") or "quick task"
    elapsed = state.get("elapsedBefore") or 0
    if state.get("startTime"):
        elapsed += max(0, int(time.time()) - state["startTime"] // 1000)
    return f"{STOP_PREFIX}stop timer — {label} ({elapsed // 60}m {elapsed % 60}s)"


def main():
    # --- child action mode ---
    action = os.environ.get("POMOTASK_ROFI_ACTION")
    if action:
        name = sys.argv[1] if len(sys.argv) > 1 else None
        if action == "stop":
            stop()
        elif action == "start" and name:
            habits = fetch_timer_habits()
            hid = habits.get(name)
            if hid is None:
                hid = next((i for d, i in habits.items() if d.lower() == name.lower()), None)
            start(hid if hid is not None else None, name)
        elif action == "quick" and name:
            start(None, name)
        return

    # --- rofi callback modes ---
    retv = os.environ.get("ROFI_RETV", "0")
    args = sys.argv[1:]

    if retv in ("1", "2") and args:
        text = args[0]
        if text.startswith(STOP_PREFIX):
            spawn_child("stop")
        elif retv == "2":
            spawn_child("quick", text)
        else:
            spawn_child("start", text)
        return

    # --- initial call: build the list ---
    cache = load_cache()
    fresh = bool(cache) and (time.time() - cache.get("ts", 0)) < CACHE_TTL

    habits = cache.get("habits") if fresh else None
    if habits is None:
        try:
            habits = fetch_timer_habits()
        except Exception:
            habits = (cache or {}).get("habits") or {}
            if not habits:
                print("(offline — no cached tasks)")
                return

    # short probe for a running timer -> offers the stop entry
    state = None
    try:
        state = probe_state()
    except Exception:
        pass

    save_cache(habits, state)

    label = running_label(state, habits)
    if label:
        print(label)
    for desc in habits:
        print(desc)


if __name__ == "__main__":
    main()
