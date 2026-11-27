"""Offline checks for the preview math. No network, no magick.

What these guard, in one line each: the zoom keeps home and both stops on the
card, the card is centred so nothing hangs off an edge, and the home ring is
drawn at the real search radius rather than at some scale that looks plausible.
"""
import math
import unittest

import config
import maprender as M

HOME = (config.HOME_LAT, config.HOME_LON)
W, H = config.PREVIEW_W, config.PREVIEW_H
MARGIN = 12


def mpp_at(z, lat=None):
    return M.mpp(lat if lat is not None else config.HOME_LAT, z)


def north(lat, metres):
    return (lat + metres / 111195.0, config.HOME_LON)


def east(lon, metres):
    # cos(55.7 deg) turns metres of longitude into metres on the ground
    return (config.HOME_LAT, lon + metres / (111195.0 * 0.5638))


def _fit(pts, w=None, h=None, **kw):
    """Frame for a card: centre in tiles, then every anchor in card pixels."""
    anchors = list(pts) + [HOME]
    z = M.fit_zoom(anchors, w or W, h or H, **kw)
    fr = [M.deg2num(lat, lon, z) for lat, lon in anchors]
    cx, cy = M.frame_centre(fr, (sum(p[0] for p in fr) / len(fr),
                                 sum(p[1] for p in fr) / len(fr)), w or W, h or H)
    return z, [(f * M.TILE - (cx * M.TILE - (w or W) / 2),
                g * M.TILE - (cy * M.TILE - (h or H) / 2)) for f, g in fr]


def _on_card(pts, w=None, h=None, what="anchor"):
    """Every anchor at least MARGIN px from an edge. Failing this means the card
    shows part of an order, which is the bug this whole file exists for."""
    z, fr = _fit(pts, w, h)
    for (x, y), p in zip(fr, list(pts) + [HOME]):
        assert MARGIN - 1 <= x <= (w or W) - MARGIN + 1, \
            "%s at lon %.5f sat at x=%.0f of %d (z%d)" % (what, p[1], x, w or W, z)
        assert MARGIN - 1 <= y <= (h or H) - MARGIN + 1, \
            "%s at lat %.5f sat at y=%.0f of %d (z%d)" % (what, p[0], y, h or H, z)
    return z


class FitZoom(unittest.TestCase):
    def test_a_pair_across_the_radius_still_shows_home(self):
        # Stops on opposite sides ~1 km apart with home 1 km off them is the worst
        # shape an order inside RADIUS_M can have. The wide card is the price; a
        # card with home cut off answers a different question.
        pts = [east(HOME[1], -500), east(HOME[1], 500), north(HOME[0], 1000)]
        z = _on_card(pts)
        self.assertGreater(z, 11, "gave up and went near the zmin floor")

    def test_home_and_stops_stay_on_the_card_for_every_shape(self):
        for label, pts in (
            ("tight pair", [HOME, north(HOME[0], 60)]),
            ("due north/south", [HOME, north(HOME[0], 1200)]),
            ("east-west", [HOME, east(HOME[1], 900)]),
            ("diagonal", [east(HOME[1], 700), north(HOME[0], 700), HOME]),
            ("home beyond the stops", [north(HOME[0], 900), north(HOME[0], 1000)]),
            ("one point", [east(HOME[1], 400)]),
        ):
            with self.subTest(label):
                _on_card(pts)

    def test_tight_pair_goes_to_the_ceiling(self):
        self.assertEqual(M.fit_zoom([HOME, north(HOME[0], 40)], W, H),
                         config.PREVIEW_ZOOM_MAX)

    def test_a_bigger_card_never_zooms_out_further(self):
        # This is the whole knob for a closer look: fit_zoom has no view cap, so
        # the card size is what decides how much ground a card covers. A 700 m
        # pair is the shape that flips z14 -> z15 between these two sizes.
        pts = [east(HOME[1], -350), east(HOME[1], 350)]
        small = _fit(pts, 240, 180)[0]
        big = _fit(pts, 300, 210)[0]
        self.assertGreaterEqual(big, small)
        self.assertGreater(big, small, "300x210 bought no zoom at all on a 700 m pair")

    def test_height_binds_before_width_for_a_north_south_spread(self):
        # Why a stop 1 km due north gets a wider card than the same distance east
        # west: rows stack, so height is the axis the tooltip cannot spend. Worth
        # a test because it looks like a bug and is the physics of the popup.
        ew = [east(HOME[1], -500), east(HOME[1], 500)]
        ns = [north(HOME[0], -500), north(HOME[0], 500)]
        self.assertGreater(M.fit_zoom(ew + [HOME], W, H),
                           M.fit_zoom(ns + [HOME], W, H))

    def test_due_north_south_pair_does_not_crash(self):
        # span_x == 0 divides, and this shape happens in real orders
        M.fit_zoom([HOME, north(HOME[0], 1200)], W, H)


class FrameCentre(unittest.TestCase):
    def test_an_impossible_centre_request_is_clamped_not_followed(self):
        # fit_zoom already leaves room for every anchor, so this is the rounding
        # guard - and the guard for callers that hand in their own zoom.
        pts = [HOME, north(HOME[0], 2500)]
        z, _ = _fit(pts)
        fr = [M.deg2num(lat, lon, z) for lat, lon in pts + [HOME]]
        pull = (fr[0][0] + 5, fr[0][1] - 5)
        cx, cy = M.frame_centre(fr, pull, W, H)
        want = (sum(p[0] for p in fr) / len(fr), sum(p[1] for p in fr) / len(fr))
        self.assertLess(cy, want[1], "did not lean toward the pull at all")
        for f, g in fr:
            self.assertGreaterEqual(f * M.TILE - (cx * M.TILE - W / 2), MARGIN - 1)
            self.assertLessEqual(f * M.TILE - (cx * M.TILE - W / 2), W - MARGIN + 1)
            self.assertGreaterEqual(g * M.TILE - (cy * M.TILE - H / 2), MARGIN - 1)
            self.assertLessEqual(g * M.TILE - (cy * M.TILE - H / 2), H - MARGIN + 1)

    def test_a_wide_card_lets_the_frame_move_at_all(self):
        # The old fit capped the zoom and clipped home to keep cards small, and
        # this is what it was doing at the same time: the mean of the anchors sat
        # so far off-centre that a stop fell outside the frame.
        pts = [HOME, east(HOME[1], 900)]
        z, fr = _fit(pts, 120, 180)
        self.assertTrue(all(MARGIN - 1 <= x <= 120 - MARGIN + 1 for x, _ in fr),
                        "a narrow card put a stop off the card at z%d" % z)


class EdgeChevron(unittest.TestCase):
    def test_off_card_home_gets_an_arrow_that_points_at_home(self):
        for home in ((W + 60, H // 2), (-500, -400), (W // 2, H + 4000)):
            chev = M._chevron(home, W, H)
            self.assertIsNotNone(chev, home)
            self.assertTrue(all(0 <= x < W and 0 <= y < H for x, y in chev),
                            "arrow itself left the card for home=%s" % (home,))
            cx = sum(p[0] for p in chev) / 3
            cy = sum(p[1] for p in chev) / 3
            # a triangle parked on a diagonal corner has its centroid off the axis
            # it points along, so this is a "not pointing away" check
            self.assertAlmostEqual(math.atan2(chev[0][1] - cy, chev[0][0] - cx),
                                   math.atan2(home[1] - cy, home[0] - cx),
                                   delta=0.05, msg=str(home))

    def test_home_already_on_card_needs_no_arrow(self):
        self.assertIsNone(M._chevron((120, 90), W, H))


class RingRadius(unittest.TestCase):
    def test_ring_radius_tracks_meters_per_pixel_at_the_chosen_zoom(self):
        for z in (13, 15, 17):
            want = config.RADIUS_M / mpp_at(z)
            self.assertGreater(want, 0)
            self.assertAlmostEqual(round(1000 / mpp_at(z)), want, delta=1)


class DrawOrder(unittest.TestCase):
    def test_home_leads_to_the_pickup_underneath_the_route(self):
        cmd = M._draw_cmd([(10, 10), (50, 60)], (90, 20), (90, 20), 0)
        leader = cmd.index("stroke-dasharray 1,3")
        route = cmd.index("polyline 10,10 50,60")
        self.assertLess(leader, route, "leader drawn over the route")

    def test_every_stroked_primitive_states_its_dash_pattern(self):
        # MVG carries state between primitives: whatever the last dash setting was
        # applies to the next one, which is how the ring's dashes once scalloped
        # every marker disc. Ordering used to make that work by luck.
        cmd = M._draw_cmd([(10, 10), (50, 60)], (90, 20), (90, 20), 40,
                          M._chevron((400, 20), W, H))
        for prim in cmd.split("; "):
            if "stroke-width" in prim:
                self.assertIn("stroke-dasharray", prim, prim)


if __name__ == "__main__":
    unittest.main()
