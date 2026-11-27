"""Order-feed parsing, the "near home" predicate, and the tooltip text.

Everything here is pure so it can be driven from a saved response without the
network (see test_feed.py). The poller owns I/O and state.
"""
import os
from datetime import datetime, timedelta, timezone
from math import asin, cos, radians, sin, sqrt

import config

MOSCOW_OFFSET = 3  # Moscow has had no DST since 2014, so an offset is exact.
                   # zoneinfo is tried first and only used if the tzdata is there.


def now_moscow():
    try:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo("Europe/Moscow"))
    except Exception:
        return datetime.now(timezone(timedelta(hours=MOSCOW_OFFSET)))


def hav(lat1, lon1, lat2, lon2):
    dlat, dlon = radians(lat2 - lat1), radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 2 * 6371000 * asin(sqrt(a))


def points(order):
    return order.get("points") or []


def point_ll(p):
    # the feed sends coordinates as strings
    return float(p["latitude"]), float(p["longitude"])


def dist_home_m(p):
    lat, lon = point_ll(p)
    return hav(config.HOME_LAT, config.HOME_LON, lat, lon)


def money(order):
    try:
        return float(order.get("list_currency") or 0)
    except ValueError:
        return 0.0


def deadline(order):
    """Drop-off deadline: the last point's courier_finish_datetime.

    Parsed with its own +03:00 offset, so no tz math and no string comparison -
    comparing the "HH:MM" text lets 00:15 tomorrow beat 10:57 today.
    """
    p = points(order)[-1:]
    if not p:
        return None
    s = p[0].get("courier_finish_datetime")
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


PAYMENT_LABELS = {
    "balance": "на балансе",
    "bank_card": "картой",
    "cash": "наличные",
    "payment_system": "пс",
}


def clip(s, n):
    s = (s or "").strip().replace("\n", " ")
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def hhmm(dt):
    return dt.strftime("%H:%M") if dt else "—"


def eligible(order, now):
    """The near-home grab: both ends within RADIUS_M, and takeable right now.

    Module parity for the exclusions (buyout, cash, deadline must be later
    today) - the LSPosed module drops exactly these three. No vehicle-type
    filter: the module has none either.
    """
    if order.get("is_denied"):
        return False
    try:
        if float(order.get("buyout_amount") or 0) != 0:
            return False
    except ValueError:
        return False
    if order.get("payment_method") == "cash":
        return False
    pts = points(order)
    if not pts:
        return False
    dl = deadline(order)
    if dl is None or dl <= now:
        return False
    # module rule: an order due tomorrow is not tonight's business, even though
    # it is "in the future" - dv_widget.py keeps these and prints ⏱…+1
    if dl.date() != now.date():
        return False
    # every point, not just first and last: the server can only pin the first
    # and last point, so a middle stop across the city must be caught here
    return all(dist_home_m(p) <= config.RADIUS_M for p in pts)


def entry(order, now):
    pts = points(order)
    first, last = pts[0], pts[-1]
    dl = deadline(order)
    start = None
    if not first.get("is_time_start_hidden"):
        try:
            start = datetime.fromisoformat(first["courier_start_datetime"])
        except (ValueError, KeyError):
            start = None
    d_pick = round(dist_home_m(first))
    d_drop = round(dist_home_m(last))
    weight = clip(first.get("total_weight_label") or order.get("total_weight_label") or "", 12)
    pay = PAYMENT_LABELS.get(order.get("payment_method"), order.get("payment_method") or "—")
    lines = [
        "%s · %s ₽" % (order.get("order_name") or "№%s" % order.get("order_id"),
                       rub(money(order))),
        "%s · %s%s" % (pay, ("~%s · " % weight) if weight else "",
                       clip(order.get("matter") or "", 30)),
        "%s→%s · %d→%d м от дома" % (hhmm(start), hhmm(dl), d_pick, d_drop),
    ]
    return {
        "order_id": order.get("order_id"),
        "order_name": order.get("order_name") or "",
        "money": int(round(money(order))),
        "deadline": hhmm(dl),
        "matter": clip(order.get("matter") or "", 60),
        "lines": lines,
        "points": [list(point_ll(p)) for p in pts],
        "pickup_m": d_pick,
        "drop_m": d_drop,
        "png": None,  # filled by the poller once the preview is rendered
    }


def summarize(orders, now):
    sel = [o for o in orders if eligible(o, now)]
    sel.sort(key=money, reverse=True)  # money is the thing walking time is traded for
    shown = [entry(o, now) for o in sel[:config.TOP_N]]
    return {
        "count": len(sel),
        "total_rub": int(round(sum(money(o) for o in sel))),
        "orders": shown,
        "more": max(0, len(sel) - config.TOP_N),
        "nearest_pickup_m": min((e["pickup_m"] for e in shown), default=None),
        "soonest": min((e["deadline"] for e in shown if e["deadline"] != "—"), default=None),
    }


def query():
    """The listing query. Signed and sent byte-for-byte as built here."""
    fmt = "%.7f"
    return ("request_reason=auto_by_ui"
            "&first_point_latitude=%s&first_point_longitude=%s&first_point_max_radius_meters=%d"
            "&last_point_latitude=%s&last_point_longitude=%s&last_point_max_radius_meters=%d"
            % (fmt % config.HOME_LAT, fmt % config.HOME_LON, config.RADIUS_M,
               fmt % config.HOME_LAT, fmt % config.HOME_LON, config.RADIUS_M))


def rub(x):
    """462 → '462', 1430 → '1 430'."""
    s = format(int(round(x)), "d")[::-1]
    return " ".join(s[i:i + 3] for i in range(0, len(s), 3))[::-1]
