"""Small map preview: the walk between an order's points on a raster basemap.

stdlib + ImageMagick only (no pip, no browser, no map library). 180x120 px, 2-4
tiles per image, 0.2-1.5 s cold and instant from the tile cache.

Three things that will silently produce garbage if you don't guard them:
  - some tile hosts answer 200 with a valid PNG that is the same placeholder for
    every coordinate (openstreetmap.org without a Referer, carto always), so a
    "status == 200" check is not a check;
  - tile bodies arrive truncated under concurrent fetch and `magick` only warns
    (and still writes an image), so every tile is validated for the IEND chunk;
  - a host may not use the XYZ grid at all, so the numbers we compute can be
    perfectly correct and still fetch the wrong part of the city. Every source
    here has one tile checked against a known address (Ленинский пр. 77к1).
"""
import concurrent.futures as cf
import json
import math
import os
import shutil
import subprocess
import urllib.request

import config

TILE = 256
USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0")

SOURCES = {
    # the only source here that keeps Cyrillic street names AND the German
    # transliteration under them; verified tile-for-tile against the home address
    "osm.de": "https://tile.openstreetmap.de/{z}/{x}/{y}.png",
    # maps.wikimedia.org 403s us ("restricted to Wikimedia and affiliated sites")
    # and openstreetmap.org serves a fixed block tile without a Referer, so the
    # honest fallbacks are these two; opentopomap is topographic and reads badly
    # for a city walk, which is why it is last
    "osmfr": "https://a.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png",
    "opentopomap": "https://a.tile.opentopomap.org/{z}/{x}/{y}.png",
    # openstreetmap.org deliberately not listed: without a Referer it answers 200
    # with one fixed block PNG for every coordinate, so it fails quietly
}


def deg2num(lat, lon, z):
    n = 2.0 ** z
    return ((lon + 180.0) / 360.0 * n,
            (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)


def mpp(lat, z):
    """Metres per pixel at this latitude/zoom; Mercator is conformal, so this is
    the same in both axes and a ground circle stays a circle in the image."""
    return 40075016.686 * math.cos(math.radians(lat)) / (TILE * 2 ** z)


def fit_zoom(pts, w, h, margin=12, zmin=9, zmax=None):
    """Highest zoom where every point in `pts` still fits with margin.

    `pts` must include home: it is the anchor the widget is measured against, so
    it is not something the view may trade away for a tighter crop. Mercator
    scales with 2^z, so the fit is closed-form.

    There is deliberately no cap on how far this zooms out. A spread order does
    get a wide card - that is what "everything you need is on the card" costs -
    and what buys the zoom back is PREVIEW_W/H, not clipping.
    """
    zmax = zmax or config.PREVIEW_ZOOM_MAX
    return int(max(zmin, math.floor(min(float(zmax), _fit_cont(pts, w, h, margin)))))


def _fit_cont(pts, w, h, margin):
    """Continuous zoom at which every point still fits with margin. inf when they
    all sit on top of each other, which asks for no room at all."""
    xs = [(lon + 180.0) / 360.0 for _, lon in pts]
    ys = [(1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0
          for lat, _ in pts]
    span_x, span_y = max(xs) - min(xs), max(ys) - min(ys)
    if span_x < 1e-12 and span_y < 1e-12:
        return float("inf")
    room_x = (w - 2 * margin) / TILE if span_x > 0 else float("inf")
    room_y = (h - 2 * margin) / TILE if span_y > 0 else float("inf")
    # a pair due north/south of home has span_x == 0, which must read as
    # "width is not what limits me" rather than crashing the poll
    scale = min(room_x / span_x if span_x > 0 else float("inf"),
                room_y / span_y if span_y > 0 else float("inf"))
    return math.log2(scale)


PNG_TAIL = b"IEND\xaeB`\x82"  # the last 8 bytes of any complete PNG


def valid_png(path):
    try:
        with open(path, "rb") as f:
            f.seek(-8, os.SEEK_END)
            return f.read(8) == PNG_TAIL
    except OSError:
        return False


def tile_path(source, z, x, y):
    return os.path.join(config.TILE_CACHE_DIR, "%s_%d_%d_%d.png" % (source, z, x, y))


def fetch_tile(source, z, x, y):
    """Returns a local path for the tile, or None. Cache hit is validated too."""
    path = tile_path(source, z, x, y)
    if os.path.exists(path):
        if valid_png(path):
            return path
        os.unlink(path)  # a truncated tile left here poisons every later render
    req = urllib.request.Request(SOURCES[source].format(z=z, x=x, y=y),
                                 headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            raw = r.read()
    except Exception:
        return None
    if not raw.endswith(PNG_TAIL):
        return None
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(raw)
    os.replace(tmp, path)
    return path


def evict_tiles():
    try:
        files = [(os.path.getmtime(os.path.join(config.TILE_CACHE_DIR, n)),
                  os.path.join(config.TILE_CACHE_DIR, n))
                 for n in os.listdir(config.TILE_CACHE_DIR)]
    except OSError:
        return
    total = sum(os.path.getsize(p) for _, p in files)
    budget = config.TILE_CACHE_MAX_MB * 1024 * 1024
    for _, p in sorted(files):
        if total <= budget:
            break
        try:
            total -= os.path.getsize(p)
            os.unlink(p)
        except OSError:
            pass


def _chevron(home_px, w, h, inset=9):
    """A triangle on the frame edge that points at home, for when home itself is
    off the card. Only reachable now when even the zmin floor cannot hold home -
    fit_zoom otherwise keeps home on the card by construction. The card's own text
    already carries "N м от дома", so this is only ever a direction cue.
    """
    hx, hy = home_px
    ex = min(max(hx, inset), w - inset)
    ey = min(max(hy, inset), h - inset)
    dx, dy = hx - ex, hy - ey
    n = math.hypot(dx, dy)
    if n < 1:
        return None
    ux, uy = dx / n, dy / n
    vx, vy = -uy, ux
    pts = [(ex + ux * 6, ey + uy * 6),
           (ex - ux * 2 + vx * 4.5, ey - uy * 2 + vy * 4.5),
           (ex - ux * 2 - vx * 4.5, ey - uy * 2 - vy * 4.5)]
    return [tuple(int(round(v)) for v in p) for p in pts]


def _draw_cmd(pts_px, home_px, square_px, radius_px, chevron=None):
    d = []
    if home_px and pts_px:
        # The leader goes first and under everything: at z14, where a stop near
        # the far side of the radius pushes home into a corner, a detached square
        # reads as decoration. Dotted grey, never the route's orange, so it cannot
        # be mistaken for the walk.
        d.append("fill none stroke '#868e96' stroke-width 1 stroke-dasharray 1,3 "
                 "polyline %d,%d %d,%d" % (home_px[0], home_px[1],
                                           pts_px[0][0], pts_px[0][1]))
    if home_px and radius_px:
        cx, cy = home_px  # may sit outside the frame; magick clips the ring, and
        # the arc still points at the way home lies
        d.append("fill none stroke '#5c7cfa' stroke-width 1 stroke-dasharray 4,3 "
                 "circle %d,%d %d,%d" % (cx, cy, cx, cy + radius_px))
    # MVG keeps the graphics state between primitives, so every command has to
    # restate the dash pattern or the ring's 4,3 dashes leak into the route line
    # and scallop the marker discs.
    if len(pts_px) > 1:
        d.append("fill none stroke '#e8590c' stroke-width 2 stroke-dasharray none "
                 "stroke-linejoin round stroke-linecap round polyline "
                 + " ".join("%d,%d" % p for p in pts_px))
    for i, (x, y) in enumerate(pts_px):
        # halo r 5, dot r 3: the halo is what reads as "the dot", so it is the one
        # that has to come down when the card is asked for smaller markers
        d.append("fill '#ffffff' stroke '#111111' stroke-width 1 stroke-dasharray none "
                 "circle %d,%d %d,%d" % (x, y, x, y - 5))
        if i == 0:
            colour = "#2f9e44"  # pickup
        elif i == len(pts_px) - 1:
            colour = "#e03131"  # dropoff
        else:
            colour = "#f08c00"  # intermediate stop
        d.append("stroke none fill %s circle %d,%d %d,%d" % (colour, x, y, x, y - 3))
    if square_px:
        hx, hy = square_px
        # 1 px bigger than the stop dots: home has no colour of its own to tell it
        # apart from a pickup, and the frame is 180 px tall
        d.append("fill '#343a40' stroke '#ffffff' stroke-width 1 stroke-dasharray none "
                 "rectangle %d,%d %d,%d" % (hx - 3, hy - 3, hx + 3, hy + 3))
    if chevron:
        ax, ay = chevron[0]
        d.append("fill '#343a40' stroke '#ffffff' stroke-width 1 stroke-dasharray none "
                 "polygon %d,%d %d,%d %d,%d" % (ax, ay, chevron[1][0], chevron[1][1],
                                                 chevron[2][0], chevron[2][1]))
    return "; ".join(d)


def frame_centre(fr_pts, want, w, h, margin=12):
    """Centre of the crop, in tiles: as close to `want` as it can get without an
    anchor - a stop or home - falling out of the frame.

    At the zoom fit_zoom picks this is only a rounding guard: that zoom already
    leaves room for every anchor. It earns its keep when a caller hands in its own
    zoom, where the mean of the anchors would otherwise drop one off the edge.
    """
    def axis(vals, want_v, size):
        mg, side = margin / TILE, size / TILE
        lo, hi = min(vals), max(vals)
        if hi - lo + 2 * mg >= side:
            return (lo + hi) / 2.0  # these anchors already fill this axis
        return min(max(want_v, hi + mg - side / 2.0), lo + side / 2.0 - mg)
    return (axis([p[0] for p in fr_pts], want[0], w),
            axis([p[1] for p in fr_pts], want[1], h))


def render(pts, out, home=None, radius_m=None, w=None, h=None):
    """pts: [(lat, lon)] in walking order. Returns True when out is a good PNG."""
    w, h = w or config.PREVIEW_W, h or config.PREVIEW_H
    if not pts:
        return False
    os.makedirs(config.PREVIEW_DIR, exist_ok=True)
    os.makedirs(config.TILE_CACHE_DIR, exist_ok=True)

    # Home belongs to the fit, not to the decoration. The card answers "how far
    # from home is this walk", so a crop that hides home answers a different
    # question; a spread order just gets the wider card that costs, and
    # PREVIEW_W/H is the knob for a tighter view.
    anchors = list(pts) + ([tuple(home)] if home else [])
    z = fit_zoom(anchors, w, h)
    fr = [deg2num(lat, lon, z) for lat, lon in anchors]
    want = (sum(p[0] for p in fr) / len(fr), sum(p[1] for p in fr) / len(fr))
    cx, cy = frame_centre(fr, want, w, h)

    gx = int(round(cx * TILE - w / 2))
    gy = int(round(cy * TILE - h / 2))
    min_x, max_x = math.floor(gx / TILE), math.floor((gx + w - 1) / TILE)
    min_y, max_y = math.floor(gy / TILE), math.floor((gy + h - 1) / TILE)
    cols, rows = max_x - min_x + 1, max_y - min_y + 1

    tmp = os.path.join(config.PREVIEW_DIR, ".tiles-%d" % os.getpid())
    os.makedirs(tmp, exist_ok=True)
    try:
        for source in config.BASEMAP_SOURCES:
            if source not in SOURCES:
                continue  # a typo in config must not take the previews down
            jobs = [(min_x + c, min_y + r) for r in range(rows) for c in range(cols)]
            with cf.ThreadPoolExecutor(max_workers=min(4, len(jobs))) as ex:
                paths = list(ex.map(lambda j: fetch_tile(source, z, j[0], j[1]), jobs))
            if not all(paths):
                continue
            grid = os.path.join(tmp, "grid.png")
            if subprocess.run(["magick", "montage", "-tile", "%dx%d" % (cols, rows),
                               "-geometry", "+0+0", "-background", "none"]
                              + list(paths) + [grid],
                              check=False, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode != 0:
                continue
            crop_x, crop_y = gx - min_x * TILE, gy - min_y * TILE
            px = [(int(round(f * TILE - gx)), int(round(g * TILE - gy))) for f, g in fr]
            order_px = px[:len(pts)]
            home_px = px[len(pts)] if home else None
            radius_px = int(round((radius_m or config.RADIUS_M) / mpp(pts[0][0], z))) if home else 0
            square_px = home_px if home_px and 0 <= home_px[0] < w and 0 <= home_px[1] < h else None
            chevron = _chevron(home_px, w, h) if home_px and square_px is None else None
            cmd = ["magick", grid, "-crop", "%dx%d+%d+%d" % (w, h, crop_x, crop_y),
                   "+repage", "-draw",
                   _draw_cmd(order_px, home_px, square_px, radius_px, chevron),
                   # the zoom stamp is a separate -annotate, not a draw primitive:
                   # `annotate` inside -draw needs font/gravity state that -draw
                   # does not carry the way the option form does
                   "-gravity", "southwest", "-background", "none", "-fill", "#adb5bd",
                   "-pointsize", "7", "-annotate", "+3+2", "z%d" % z, out]
            if subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0 and valid_png(out):
                evict_tiles()
                return True
            # magick writes a truncated file and only warns, so a "failed" attempt
            # can leave a plausible-looking PNG behind; the bar must never get it
            if os.path.exists(out) and not valid_png(out):
                os.unlink(out)
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    import sys
    pts = [tuple(float(v) for v in a.split(",")) for a in sys.argv[1:3]]
    out = sys.argv[3] if len(sys.argv) > 3 else "/tmp/dv_preview.png"
    print(json.dumps({"ok": render(pts, out, home=(config.HOME_LAT, config.HOME_LON)),
                      "out": out}))
