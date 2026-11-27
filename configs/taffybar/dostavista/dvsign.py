"""Vendored request signer for the Dostavista courier API.

Copied from dostavista_lsposed/tools/dv_request.py (that copy is left alone as a
forensic tool; this one must not import from /mnt/pc, which is an rclone mount to
another machine and is not always there).

Differences from the source on purpose:
  - gzip is folded in (the source hard-codes Accept-Encoding: identity).
  - no VECTORS: they embed a live session id, and this file is git-tracked.
    "is the signing recipe still correct" is answered by the live error code
    instead (see classify_failure) - cheaper and needs no secret.

    X-DV-Signature = hmac_sha256(
        key  = SIGN_KEY                                 # constant per app build
        data = VERB + host + path + query_no_leading_?
             + SIGN_VERSION + X-Timestamp + X-DV-Session + User-Agent
             + md5_hex(body))

The query string must be the exact percent-encoded bytes put on the wire, or the
server answers 400 invalid_request_data. Build it once and reuse it.
"""
import gzip
import hashlib
import hmac
import json
import time
import urllib.error
import urllib.request

HOST = "robot.dostavista.ru"
SIGN_KEY = b"lKMCy3mlx4UYpuIxhtF5Bz9sDSs7qDXzaPTlibFX4Bnz82DrLAocbutCKfvRb4NR"
SIGN_VERSION = "1.0"
USER_AGENT = "ru-courier-app-main-android/2.131.1.3367"
API = "/api/courier/2.86"
LIST_PATH = API + "/available-mixed-list-compact"


def signature(verb, path, query="", ts=None, session="", body=b""):
    ts = int(time.time()) if ts is None else ts
    msg = (verb.upper() + HOST + path + query + SIGN_VERSION + str(ts) + session
           + USER_AGENT + hashlib.md5(body).hexdigest())
    return hmac.new(SIGN_KEY, msg.encode(), hashlib.sha256).hexdigest()


def headers(verb, path, query="", session="", device_id="", body=b"", ts=None):
    ts = int(time.time()) if ts is None else ts
    return {
        "User-Agent": USER_AGENT,
        "X-DV-Session": session,
        "X-DV-Signature": signature(verb, path, query, ts, session, body),
        "X-DV-Signature-Version": SIGN_VERSION,
        "X-Timestamp": str(ts),
        # optional on the server; sending it means sha256(android_id), which we
        # do not have on this machine, and the signed string changes with it
        "Accept-Encoding": "gzip",
    }


def get(path, query="", session="", device_id="", timeout=40):
    """One signed GET. Returns (status, parsed_or_text, error_code_or_None)."""
    h = headers("GET", path, query, session, device_id)
    url = "https://%s%s%s" % (HOST, path, "?" + query if query else "")
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            if r.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        if e.headers and e.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
        status = e.code
    try:
        body = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return status, raw[:400].decode("utf-8", "replace"), "parse"
    codes = body.get("errors") or []
    return status, body, (codes[0] if codes else None)


def classify_failure(status, error_code):
    """Which kind of broken are we, for the bar's word and the notification.

    invalid_request_data with a query/verb we know is correct means the signing
    string no longer matches the server's - almost always a new app build with a
    new SIGN_KEY, which no amount of re-logging fixes.
    """
    if error_code == "not_logged_in":
        return "session", "сессия"
    if error_code in ("invalid_request_data", "invalid_signature", "invalid_api_method"):
        return "key", "ключ"
    if error_code == "invalid_user_agent":
        return "key", "UA"
    if status in (401, 403):
        return "session", "сессия"
    if status >= 500 or error_code == "parse":
        return "network", "сервер"
    return "network", "сеть"


def mask(session):
    return (session or "")[:6] + "…"
