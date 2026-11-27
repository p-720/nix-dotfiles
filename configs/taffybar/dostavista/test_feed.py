#!/usr/bin/env python3
"""Offline tests for the filter/selection/state-machine layers.

    python3 test_feed.py [path/to/listing.json]

No network, no bar, no tiles. The fixture is a real 417-order response saved on
2026-11-27 and committed in ./fixture; "now" is pinned to it so the deadline
rules are deterministic.
"""
import copy
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config
import feed
import poller

_HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_HERE, "fixture", "dv_list_2026-11-27.json")
NOW = datetime.fromisoformat("2026-11-27T11:10:00+03:00")


def load_orders():
    with open(FIXTURE) as f:
        return json.load(f)["available_objects"]["orders"]


def mk(order_id=1, lat=55.68580, lon=37.5431, deadline="2026-11-27T13:00:00+03:00",
       cash=False, buyout="0.00", denied=False, second=None):
    """A synthetic order with everything passing, mutated by keyword."""
    def point(ll, start="2026-11-27T11:30:00+03:00", finish=deadline):
        lat, lon = ll
        return {"point_id": 1, "address": "Москва, тест ***", "latitude": str(lat),
                "longitude": str(lon), "courier_start_datetime": start,
                "courier_finish_datetime": finish, "is_time_start_hidden": False,
                "meeting_type": "door_to_door", "courier_distance_m": 200,
                "subway_station_name": None, "subway_straight_distance": None}
    pts = [point((lat, lon)), point(second or (55.69000, 37.55000))]
    return {"order_id": order_id, "order_name": "№%d" % order_id, "status": "available",
            "payment_method": "cash" if cash else "balance", "vehicle_type_id": 6,
            "matter": "документы", "list_currency": "339.00", "buyout_amount": buyout,
            "total_weight_label": "До 1 кг", "points": pts, "is_denied": denied,
            "is_fragile_cargo": False, "loaders_count": 0, "version": 0}


class Predicate(unittest.TestCase):
    def test_clean_order_passes(self):
        self.assertTrue(feed.eligible(mk(), NOW))

    def test_cash_dropped(self):
        self.assertFalse(feed.eligible(mk(cash=True), NOW))

    def test_buyout_dropped(self):
        self.assertFalse(feed.eligible(mk(buyout="1500.00"), NOW))

    def test_denied_dropped(self):
        self.assertFalse(feed.eligible(mk(denied=True), NOW))

    def test_past_deadline_dropped(self):
        self.assertFalse(feed.eligible(mk(deadline="2026-11-27T10:00:00+03:00"), NOW))

    def test_deadline_tomorrow_dropped(self):
        # the LSPosed module drops these; dv_widget.py keeps them and prints +1
        self.assertFalse(feed.eligible(mk(deadline="2026-11-28T09:00:00+03:00"), NOW))

    def test_deadline_late_tonight_kept(self):
        self.assertTrue(feed.eligible(mk(deadline="2026-11-27T23:55:00+03:00"), NOW))

    def test_endpoint_out_of_radius_dropped(self):
        far = (55.75000, 37.62000)  # ~8 km out
        self.assertFalse(feed.eligible(mk(second=far), NOW))

    def test_every_point_checked_not_just_ends(self):
        # pickup near home, dropoff near home, a middle stop across the city
        o = mk()
        o["points"].insert(1, {"latitude": "55.80", "longitude": "37.70",
                               "courier_finish_datetime": "2026-11-27T13:00:00+03:00"})
        self.assertFalse(feed.eligible(o, NOW))

    def test_radius_edge_is_inclusive(self):
        # exactly RADIUS_M straight north is on the boundary; a hair past it is out
        north = config.HOME_LAT + config.RADIUS_M / 111195.0
        self.assertTrue(feed.eligible(mk(second=(north - 0.0001, config.HOME_LON)), NOW))
        self.assertFalse(feed.eligible(mk(second=(north + 0.0001, config.HOME_LON)), NOW))


class Text(unittest.TestCase):
    def test_money_grouping(self):
        self.assertEqual(feed.rub(462), "462")
        self.assertEqual(feed.rub(1430), "1 430")
        self.assertEqual(feed.rub(125400), "125 400")

    def test_entry_has_three_lines_and_points(self):
        e = feed.entry(mk(order_id=178011370), NOW)
        self.assertEqual(len(e["lines"]), 3)
        self.assertIn("№178011370", e["lines"][0])
        self.assertIn("339", e["lines"][0])
        self.assertEqual(len(e["points"]), 2)
        self.assertIsNotNone(e["deadline"])
        self.assertGreater(e["pickup_m"], 0)


class Summary(unittest.TestCase):
    def test_sorted_by_money_and_truncated(self):
        orders = [mk(order_id=i) for i in range(7)]
        for i, o in enumerate(orders):
            o["list_currency"] = "%d.00" % (100 + i * 10)
        s = feed.summarize(orders, NOW)
        self.assertEqual(s["count"], 7)
        self.assertEqual(s["total_rub"], sum(100 + i * 10 for i in range(7)))
        self.assertEqual(len(s["orders"]), config.TOP_N)
        self.assertEqual(s["more"], 7 - config.TOP_N)
        self.assertEqual(s["orders"][0]["money"], 160)
        self.assertEqual(s["orders"][-1]["money"], 120)

    def test_deadlines_are_not_compared_as_text(self):
        # 00:15 tomorrow must lose to 10:57 today; the today-rule drops the former
        far = mk(deadline="2026-11-28T00:15:00+03:00")
        today = mk(deadline="2026-11-27T10:57:00+03:00")
        self.assertFalse(feed.eligible(far, NOW))
        self.assertFalse(feed.eligible(today, NOW))  # already past at 11:10


class Deny(unittest.TestCase):
    def test_none_is_ok(self):
        self.assertEqual(poller.classify_deny(None), ("ok", None))

    def test_not_working_is_idle(self):
        self.assertEqual(poller.classify_deny("courier_is_not_working"), ("idle", None))

    def test_other_codes_are_errors_with_words(self):
        for code in ("courier_is_temporarily_banned", "courier_balance_is_below_minimum",
                     "disabled_in_region", "disabled_by_outdated_location",
                     "courier_on_demand_enabled", "courier_is_foreign_not_from_eaes"):
            state, word = poller.classify_deny(code)
            self.assertEqual(state, "error", code)
            self.assertTrue(word, code)

    def test_unknown_code_still_an_error(self):
        self.assertEqual(poller.classify_deny("something_new")[0], "error")


class Line(unittest.TestCase):
    def test_states(self):
        self.assertEqual(poller.bar_line("idle", 0, 0, None), "◈ –")
        self.assertEqual(poller.bar_line("error", 3, 900, "бан"), "◈ ⚠ бан")
        self.assertEqual(poller.bar_line("ok", 0, 0, None), "")
        self.assertEqual(poller.bar_line("ok", 3, 1430, None), "◈ 3 · 1 430 ₽")


class StateMachine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dvseen-")
        self._seen_path = config.SEEN_PATH
        config.SEEN_PATH = os.path.join(self.tmp, "seen.json")
        self.args = SimpleNamespace(no_notify=True, once=True, line=False)
        self.notices = []
        self.seen = {"bootstrapped": False, "was_working": True, "seen": {}}
        poller.notify = lambda a, s, b: self.notices.append((s, b))

    def tearDown(self):
        config.SEEN_PATH = self._seen_path
        import importlib
        importlib.reload(poller)

    def entries(self, ids):
        return [feed.entry(mk(order_id=i), NOW) for i in ids]

    def summary(self, ids):
        return {"count": len(ids), "total_rub": 0, "more": 0}

    def run_observe(self, ids, working):
        # one dict held across calls: observe mutates what it is given and the
        # poller is what persists it, so the test must not reload it each time
        return poller.observe(self.args, self.entries(ids), working,
                              self.summary(ids), NOW, self.seen)

    def test_cold_start_is_silent(self):
        self.assertEqual(self.run_observe([1, 2, 3], True), set())
        self.assertEqual(self.notices, [])

    def test_second_poll_new_id_notifies(self):
        self.run_observe([1, 2], True)
        self.run_observe([1, 2], True)
        self.assertEqual(self.notices, [])
        self.run_observe([1, 2, 3], True)
        self.assertEqual(len(self.notices), 1)
        self.assertIn("№3", self.notices[0][0])

    def test_order_leaving_and_returning_does_not_realert(self):
        self.run_observe([1, 2], True)
        self.run_observe([1], True)          # 2 leaves the feed
        self.run_observe([1, 2], True)       # ...and comes back
        self.assertEqual(self.notices, [])

    def test_shift_start_is_one_announcement_not_a_pileup(self):
        seen = {"bootstrapped": True, "was_working": False, "seen": {}}
        new = poller.observe(self.args, self.entries([1, 2, 3, 4, 5]), True,
                             self.summary([1, 2, 3, 4, 5]), NOW, seen)
        self.assertEqual(new, set())
        self.assertEqual(len(self.notices), 1)
        self.assertIn("смена началась", self.notices[0][0])

    def test_offline_does_not_notify(self):
        seen = {"bootstrapped": True, "was_working": True, "seen": {"1": poller.iso(NOW)}}
        new = poller.observe(self.args, self.entries([2]), False, self.summary([2]),
                             NOW, seen)
        self.assertEqual(new, set())
        self.assertEqual(self.notices, [])

    def test_seen_entries_expire(self):
        old = NOW - timedelta(seconds=config.SEEN_TTL_S + 60)
        seen = {"bootstrapped": True, "was_working": True,
                "seen": {"1": poller.iso(old), "2": poller.iso(NOW)}}
        poller.observe(self.args, self.entries([2]), True, self.summary([2]), NOW, seen)
        self.assertNotIn("1", seen["seen"])
        self.assertIn("2", seen["seen"])


class Coalesce(unittest.TestCase):
    def test_burst_makes_one_notification(self):
        notices = []
        args = SimpleNamespace(no_notify=True, once=True, line=False)
        orig = poller.notify
        poller.notify = lambda a, s, b: notices.append((s, b))
        try:
            with tempfile.TemporaryDirectory() as td:
                path = os.path.join(td, "seen.json")
                old, config.SEEN_PATH = config.SEEN_PATH, path
                seen = {"bootstrapped": True, "was_working": True, "seen": {}}
                es = [feed.entry(mk(order_id=i), NOW) for i in range(1, 6)]
                poller.observe(args, es, True, {"count": 5, "total_rub": 0, "more": 0}, NOW, seen)
                self.assertEqual(len(notices), 1)
                self.assertIn("5 новых", notices[0][0])
                body = notices[0][1].splitlines()
                self.assertEqual(len(body), 4)  # three listed + the "and N more" line
                self.assertIn("ещё 2", body[-1])
                config.SEEN_PATH = old
        finally:
            poller.notify = orig


class Fixture(unittest.TestCase):
    """Sanity against the real 417-order capture, not correctness of counts."""

    def setUp(self):
        self.orders = load_orders()

    def test_parse_all(self):
        self.assertEqual(len(self.orders), 417)
        for o in self.orders[:50]:
            self.assertTrue(feed.points(o))

    def test_funnel(self):
        now = datetime.fromisoformat("2026-11-27T11:10:00+03:00")
        drop = {"cash": 0, "buyout": 0, "denied": 0, "deadline": 0, "radius": 0}
        kept = []
        for o in self.orders:
            if o.get("payment_method") == "cash":
                drop["cash"] += 1
            if float(o.get("buyout_amount") or 0) != 0:
                drop["buyout"] += 1
            if o.get("is_denied"):
                drop["denied"] += 1
            dl = feed.deadline(o)
            if dl is None or dl <= now or dl.date() != now.date():
                drop["deadline"] += 1
            if any(feed.dist_home_m(p) > config.RADIUS_M for p in feed.points(o)):
                drop["radius"] += 1
            if feed.eligible(o, now):
                kept.append(o)
        print("fixture funnel: %s | eligible at %d m/all-points: %d" % (drop, config.RADIUS_M, len(kept)))
        self.assertGreater(len(self.orders), 400)

    def test_entry_shape_on_real_data(self):
        now = datetime.fromisoformat("2026-11-27T11:10:00+03:00")
        for o in self.orders[:200]:
            if feed.eligible(o, now):
                e = feed.entry(o, now)
                self.assertEqual(len(e["lines"]), 3)
                self.assertTrue(all(isinstance(x, str) for x in e["lines"]))
                break


class BarContract(unittest.TestCase):
    """The document the bar parses.

    taffybar.hs decodes this with aeson's *strict* instance: a missing or
    mistyped required key does not degrade, it throws, and the widget silently
    keeps its last picture. These are the keys it demands, so they are pinned here.
    """

    REQUIRED = {"state": str, "hidden": bool, "line": str, "stale": bool,
                "highlight": bool, "more": int, "orders": list}

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dvdoc-")
        self._seen, self._state = config.SEEN_PATH, config.STATE_PATH
        config.SEEN_PATH = os.path.join(self.tmp, "seen.json")
        config.STATE_PATH = os.path.join(self.tmp, "state.json")
        self.args = SimpleNamespace(no_notify=True, once=True, line=False,
                                    json=FIXTURE if os.path.exists(FIXTURE) else None)
        poller.notify = lambda a, s, b: None
        poller.render_previews = lambda entries: None  # no tiles in a test
        self.runtime = {"session": None, "failures": 0, "notified_kind": None,
                        "stale_since": None, "state": "ok", "working": None,
                        "last_good": {"count": 0, "total_rub": 0, "orders": []}}

    def tearDown(self):
        config.SEEN_PATH, config.STATE_PATH = self._seen, self._state
        import importlib
        importlib.reload(poller)

    def check(self, doc):
        for key, typ in self.REQUIRED.items():
            self.assertIn(key, doc, "bar needs %r" % key)
            self.assertIsInstance(doc[key], typ, "%r has the wrong type" % key)
        self.assertIn(doc["state"], ("ok", "idle", "error"))
        self.assertFalse(doc["hidden"] and not doc["line"].strip(),
                        "hidden with a blank line is fine, shown with one is not")
        self.assertLessEqual(len(doc["orders"]), config.TOP_N)
        for o in doc["orders"]:
            self.assertEqual(len(o["lines"]), 3)
            self.assertTrue(all(isinstance(x, str) for x in o["lines"]))
            self.assertTrue(o["png"] is None or isinstance(o["png"], str))

    @unittest.skipUnless(os.path.exists(FIXTURE), "fixture missing")
    def test_healthy_doc(self):
        self.check(poller.tick(self.args, self.runtime, NOW))

    def test_stale_doc_keeps_the_same_shape(self):
        # the bar must not need a second parser for a degraded poll: a quiet
        # network blip still carries orders, and a hard block carries zero
        self.runtime["last_good"] = {
            "count": 2, "total_rub": 1800,
            "orders": [feed.entry(mk(order_id=i), NOW) for i in (1, 2)]}
        self.runtime["failures"] = config.MAX_CONSECUTIVE_FAILURES
        poller.poll = lambda a, s, n: (None, {"kind": "key", "word": "ключ",
                                              "detail": "HTTP 403 stale_key"})
        doc = poller.tick(self.args, self.runtime, NOW)
        self.assertTrue(doc["stale"])
        self.check(doc)
        self.assertEqual(len(doc["orders"]), 2)

    def test_deny_reason_carries_a_word(self):
        # the bar prints the word in the line, so a blocked state without one
        # would render as a bare icon and leave the reason unsaid
        for reason, expected in (("courier_is_temporarily_banned", "бан"),
                                 ("courier_balance_is_below_minimum", "баланс")):
            raw = {"deny_reason": reason, "available_objects": {"orders": []},
                   "server_datetime": None, "filtered_orders_count": 0}
            poller.poll = lambda a, s, n, raw=raw: (raw, None)
            doc = poller.tick(self.args, self.runtime, NOW)
            self.assertEqual(doc["state"], "error", reason)
            self.assertIn(expected, doc["word"] or "")
            self.assertIn(expected, doc["line"])
            self.check(doc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
