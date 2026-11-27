#!/usr/bin/env python3
"""dostavista poller: shift state, near-home orders, map previews, notifications.

Runs as a systemd user unit (modules/nixos/dostavista). It owns every decision the
widget makes; the bar only reads state.json and paints what it says.

    poller.py                 # poll forever
    poller.py --once          # one poll, dump the document, exit
    poller.py --json f.json   # drive from a saved response, no network
    poller.py --line          # print just the bar line (for shell-level tests)

The session id comes from ~/.dv_session (or $DV_SESSION) and never reaches the
logs, state.json, or the bar.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta

import config
import dvsign
import feed
import maprender

SCHEMA = 1


def iso(dt):
    return dt.replace(microsecond=0).isoformat() if dt else None


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- files/env

def read_session():
    env = os.environ.get("DV_SESSION", "").strip()
    if env:
        return env
    try:
        with open(config.SESSION_FILE) as f:
            for line in f:
                if line.strip() and not line.startswith("#"):
                    return line.strip()
    except OSError:
        pass
    return ""


def save_session(session):
    """Adopt a server-rotated session in place so a restart does not lose it."""
    tmp = config.SESSION_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(session + "\n")
    os.replace(tmp, config.SESSION_FILE)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)  # the bar reads this while we write it


def notify_enabled(args):
    return not args.no_notify and not args.once and not args.line


def notify(args, summary, body):
    if not notify_enabled(args):
        log("would notify: %s | %s" % (summary, body.replace("\n", " / ")))
        return
    try:
        subprocess.run(["notify-send", "--app-name=Dostavista", "--urgency=normal",
                        "--expire-time=10000", "--hint", "string:stack_tag:dostavista",
                        summary, body],
                       check=False, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log("notify failed: %s" % e)


# ---------------------------------------------------------------- helpers

def bar_line(state, count, total, word):
    if state == "idle":
        return "◈ –"
    if state == "error":
        return "◈ ⚠ %s" % word if word else "◈ ⚠"
    if count == 0:
        return ""  # hidden: alive, working, genuinely nothing near home
    return "◈ %d · %s ₽" % (count, feed.rub(total))


def preview_path(order_id, pts):
    # every knob that changes the pixels has to be in the digest, or a card
    # rendered at the old PREVIEW_W/RADIUS_M is served forever after you change
    # them (the prune only ever looks at filenames)
    key = [pts, config.PREVIEW_W, config.PREVIEW_H, config.RADIUS_M,
           config.PREVIEW_ZOOM_MAX, config.HOME_LAT, config.HOME_LON]
    digest = hashlib.md5(json.dumps(key).encode()).hexdigest()[:10]
    return os.path.join(config.PREVIEW_DIR, "%s_%s.png" % (order_id, digest))


def render_previews(entries):
    wanted = set()
    for e in entries:
        if not e["points"]:
            continue
        path = preview_path(e["order_id"], e["points"])
        wanted.add(path)
        if not os.path.exists(path) and not maprender.render(
                [tuple(p) for p in e["points"]], path,
                home=(config.HOME_LAT, config.HOME_LON), radius_m=config.RADIUS_M):
            log("preview failed for %s" % e["order_id"])
        e["png"] = path if os.path.exists(path) and maprender.valid_png(path) else None
    try:
        cutoff = time.time() - 6 * 3600
        for name in os.listdir(config.PREVIEW_DIR):
            p = os.path.join(config.PREVIEW_DIR, name)
            if p not in wanted and os.path.getmtime(p) < cutoff:
                os.unlink(p)
    except OSError:
        pass


def order_body(entries):
    if len(entries) == 1:
        return "\n".join([entries[0]["lines"][1], entries[0]["lines"][2]])
    lines = ["%s · %s ₽ · %s" % (e["order_name"], feed.rub(e["money"]), e["matter"] or "—")
             for e in entries[:3]]
    if len(entries) > 3:
        lines.append("…и ещё %d" % (len(entries) - 3))
    return "\n".join(lines)


# ---------------------------------------------------------------- state machine

def observe(args, entries, working, summary, now, seen):
    """Decide what (if anything) to shout about, then advance the seen set.

    An offline→working transition and a cold start (no seen.json) are silent
    baselines: every order in a freshly-started shift is "new" by id and would
    otherwise fire a pile-up on every shift start, which is the main path of the
    day. The transition itself is announced instead.
    """
    ids = {e["order_id"] for e in entries}
    known = {int(k) for k in seen.get("seen", {})}

    if not seen.get("bootstrapped"):
        new, announce = set(), None
    elif working and not seen.get("was_working", True):
        new, announce = set(), ("смена началась",
                                "%d заказов у дома · %s ₽" %
                                (summary["count"], feed.rub(summary["total_rub"])))
    elif working:
        new = ids - known
        announce = None
    else:
        new, announce = set(), None

    if new:
        newest = [e for e in entries if e["order_id"] in new]
        total_new = sum(e["money"] for e in entries if e["order_id"] in new)
        if len(new) == 1:
            e = newest[0]
            notify(args, "%s · %s ₽" % (e["order_name"], feed.rub(e["money"])), order_body(newest))
        else:
            notify(args, "%d новых заказа у дома · %s ₽" % (len(new), feed.rub(total_new)),
                   order_body(newest))
    if announce:
        notify(args, announce[0], announce[1])

    seen["bootstrapped"] = True
    seen["was_working"] = working
    seen["seen"].update({str(i): iso(now) for i in ids})
    cutoff = now - timedelta(seconds=config.SEEN_TTL_S)
    seen["seen"] = {k: v for k, v in seen["seen"].items()
                    if datetime.fromisoformat(v) > cutoff}
    return new


# ---------------------------------------------------------------- one poll

def poll(args, session, now):
    if args.json:
        with open(args.json) as f:
            return json.load(f), None
    status, body, code = dvsign.get(dvsign.LIST_PATH, feed.query(), session)
    if status == 200 and isinstance(body, dict) and body.get("is_successful"):
        echoed = body.get("session")
        if echoed and session and echoed != session:
            log("server rotated the session (was %s), adopting" % dvsign.mask(session))
            save_session(echoed)
        return body, None
    kind, word = dvsign.classify_failure(status, code)
    return None, {"kind": kind, "word": word, "detail": "HTTP %s %s" % (status, code or "")}


def tick(args, runtime, now):
    """One poll -> the document to write. `runtime` is this process's memory."""
    raw, failure = poll(args, runtime["session"], now)
    if raw is None and failure["kind"] == "session":
        runtime["session"] = read_session()  # the file may have been refreshed by hand

    if raw is None:
        runtime["failures"] += 1
        kind, word, detail = failure["kind"], failure["word"], failure["detail"]
        log("poll failed: %s" % detail)
        # a blip keeps the last good numbers on the bar and stays quiet; a real
        # block (dead session, stale key) is definite, so it surfaces at once
        quiet = kind == "network" and runtime["failures"] < config.MAX_CONSECUTIVE_FAILURES
        state = runtime["state"] if quiet else "error"
        if runtime["stale_since"] is None:
            runtime["stale_since"] = now
        if not quiet and runtime["notified_kind"] != kind:
            runtime["notified_kind"] = kind
            hint = {"session": "нужен новый X-DV-Session в %s" % config.SESSION_FILE,
                    "key": "ключ подписи устарел (обнова приложения) — переснять SIGN_KEY"}.get(kind, detail)
            notify(args, "dostavista: %s" % word, hint)
        good = runtime["last_good"]
        return {"schema": SCHEMA, "state": state, "hidden": False,
                "word": None if quiet else word,
                "line": bar_line(state, good["count"], good["total_rub"], None if quiet else word),
                "detail": detail, "stale": True, "stale_since": iso(runtime["stale_since"]),
                "highlight": False, "count": good["count"], "total_rub": good["total_rub"],
                "more": 0, "orders": good["orders"], "working": runtime["working"],
                "deny_reason": None, "failure_kind": kind, "last_poll": iso(now)}

    runtime["failures"] = 0
    runtime["notified_kind"] = None
    if runtime["stale_since"]:
        log("recovered from stale since %s" % iso(runtime["stale_since"]))
        runtime["stale_since"] = None

    deny = raw.get("deny_reason")
    state, word = classify_deny(deny)
    working = state == "ok"
    orders = (raw.get("available_objects") or {}).get("orders") or []
    entries = [feed.entry(o, now) for o in orders if feed.eligible(o, now)]
    entries.sort(key=lambda e: e["money"], reverse=True)  # money is what walking time is traded for
    summary = {"count": len(entries),
               "total_rub": sum(e["money"] for e in entries),
               "more": max(0, len(entries) - config.TOP_N)}

    seen = load_json(config.SEEN_PATH, {"bootstrapped": False, "was_working": working, "seen": {}})
    new = observe(args, entries, working, summary, now, seen)
    save_json(config.SEEN_PATH, seen)

    if working:
        render_previews(entries[:config.TOP_N])

    runtime["state"], runtime["working"] = state, working
    runtime["last_good"] = {"count": summary["count"], "total_rub": summary["total_rub"],
                            "orders": entries[:config.TOP_N]}
    return {
        "schema": SCHEMA,
        "state": state,
        # zero while working is silence, not absence: the bar hides itself, and a
        # dead token still shows up (it takes the error path, which never hides)
        "hidden": state == "ok" and summary["count"] == 0,
        "word": word,
        "line": bar_line(state, summary["count"], summary["total_rub"], word),
        "detail": "%s · %d заказов у дома на %d м · топ %s ₽" % (
            "онлайн" if working else ("офлайн" if state == "idle" else (word or deny)),
            summary["count"], config.RADIUS_M, feed.rub(summary["total_rub"])),
        "stale": False,
        "stale_since": None,
        "highlight": bool(new),
        "highlight_until": iso(now + timedelta(seconds=config.NEW_HIGHLIGHT_S)) if new else None,
        "count": summary["count"],
        "total_rub": summary["total_rub"],
        "more": summary["more"],
        "orders": entries[:config.TOP_N],
        "working": working,
        "deny_reason": deny,
        "failure_kind": None,
        "last_poll": iso(now),
        "server_time": raw.get("server_datetime"),
        "filtered_by_server": raw.get("filtered_orders_count"),
    }


def classify_deny(reason):
    """(state, word). deny_reason is a 7-valued enum, so "any non-null" is wrong:
    only courier_is_not_working means "offline", everything else is a block."""
    if reason is None:
        return "ok", None
    if reason == config.IDLE_DENY:
        return "idle", None
    return "error", config.DENY_WORDS.get(reason, (reason or "?")[:12])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--line", action="store_true", help="print just the bar line")
    ap.add_argument("--json", help="saved listing response instead of the API")
    ap.add_argument("--now", help="override 'now' (ISO with offset) for fixtures")
    ap.add_argument("--no-notify", action="store_true")
    args = ap.parse_args()

    runtime = {"session": read_session(), "failures": 0, "notified_kind": None,
               "stale_since": None, "state": "ok", "working": None,
               "last_good": {"count": 0, "total_rub": 0, "orders": []}}
    if not runtime["session"] and not args.json:
        log("no session: put the X-DV-Session id in %s (chmod 600)" % config.SESSION_FILE)

    while True:
        now = datetime.fromisoformat(args.now) if args.now else feed.now_moscow()
        started = time.time()
        doc = tick(args, runtime, now)
        save_json(config.STATE_PATH, doc)
        log("%s %s" % (doc["state"], doc["line"] or "(hidden)"))
        if args.line:
            print(doc["line"])
        elif args.once:
            print(json.dumps(doc, ensure_ascii=False, indent=2))
        if args.once or args.line:
            return 0
        delay = (config.POLL_ERROR_S if doc["failure_kind"]
                 else config.POLL_IDLE_S if not doc["working"]
                 else config.POLL_WORKING_S)
        time.sleep(max(1, delay - (time.time() - started)))


if __name__ == "__main__":
    sys.exit(main())
