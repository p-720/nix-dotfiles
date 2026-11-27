"""Knobs for the dostavista widget. Edit freely: nothing here is compiled, the
poller re-reads it on restart and the taffybar side reads no config at all."""
import os

# Ленинский пр. 77к1 — Yandex's own point for the building, 3 m from the
# constants the LSPosed module filters server-side with. Typed DMS for the same
# spot is 55°41'08.4"N 37°32'34.9"E (~17 m off, noise at a 2 km radius); both
# kept here because every distance the bar prints is measured from this point.
HOME_LAT = 55.685782
HOME_LON = 37.543201

# applied to first AND last point server-side, then to every point locally
RADIUS_M = 1000

POLL_WORKING_S = 30
POLL_IDLE_S = 300
POLL_ERROR_S = 300
NEW_HIGHLIGHT_S = 300
MAX_CONSECUTIVE_FAILURES = 3
SEEN_TTL_S = 12 * 3600

TOP_N = 5
# The card image sizes itself to these, and the tooltip lays two per row
# (dvCardsPerRow in taffybar.hs), so width is paid for twice - this makes the
# tooltip about 1260 px across, and 5 slots means 3 rows of 308 px. Width is the
# only zoom knob left, because maprender.fit_zoom caps nothing and keeps home in
# the fit. At this size a card holds a horizontal spread to 1120 m and a vertical
# one to 824 m before it drops from z15 to z14 - height binds first, since the
# rows stack and the screen does not, so a stop 1 km straight north of home still
# gets the wide card. That card is where the whole 1 km ring becomes visible, so
# it reads as a scale reference rather than as emptiness. Home never gets cut off
# at any size; that is what fit_zoom guarantees.
PREVIEW_W = 440
PREVIEW_H = 308
PREVIEW_ZOOM_MAX = 17

# osm.de is a licensed mirror (FOSSGIS) that keeps Cyrillic names, so the chain
# is honest all the way down. Rejected, so it isn't re-litigated:
#   yandex core-renderer-tiles - richest labels, but its grid is not the XYZ
#     grid: measured ~29 tiles north of the same tile number at z15, and that is
#     not a whole number of tiles, so no constant offset fixes it. It also starts
#     answering 200 with blank 2-colour tiles once you probe it a few dozen times.
#   openstreetmap.org - one fixed block tile for every coordinate without a Referer
#   osmfr - romanises every label ("Leninginskii prospekt")
BASEMAP_SOURCES = ["osm.de", "osmfr", "opentopomap"]
TILE_CACHE_MAX_MB = 200

SESSION_FILE = os.path.expanduser("~/.dv_session")

_cache_root = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "dostavista")
CACHE_DIR = _cache_root
PREVIEW_DIR = os.path.join(_cache_root, "previews")
TILE_CACHE_DIR = os.path.join(_cache_root, "tiles")
STATE_PATH = os.path.join(_cache_root, "state.json")
SEEN_PATH = os.path.join(_cache_root, "seen.json")

# deny_reason is a 7-valued enum, not a boolean: matching "any non-null" reads
# "you are banned" as "you are offline" and the widget goes quiet on a block.
IDLE_DENY = "courier_is_not_working"
DENY_WORDS = {
    "courier_is_temporarily_banned": "бан",
    "courier_temporarily_banned": "бан",
    "courier_balance_is_below_minimum": "баланс",
    "courier_on_demand_enabled": "он-деманд",
    "disabled_in_region": "регион",
    "disabled_by_outdated_location": "локация",
    "courier_disabled_by_outdated_location": "локация",
    "courier_is_foreign_not_from_eaes": "EAES",
}
