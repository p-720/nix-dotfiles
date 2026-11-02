#!/usr/bin/env python3
"""Resolve a Firefox window title to that page's cached favicon.

Prints the path of a PNG (cached under ~/.cache/taffybar/favicons) or nothing.

Firefox keeps page titles in places.sqlite and icon blobs in favicons.sqlite,
both in the profile dir. They are opened read-only+immutable so this works
while Firefox holds its write lock.
"""

import base64
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile

PROFILES_INI = os.path.expanduser("~/.mozilla/firefox/profiles.ini")
FF_ROOT = os.path.expanduser("~/.mozilla/firefox")
CACHE_DIR = os.path.expanduser("~/.cache/taffybar/favicons")

PLACES_EXACT = """
select url, coalesce(last_visit_date, 0) from moz_places
where title = ? and url is not null
order by last_visit_date desc limit 5
"""

# Firefox has no title index; LIKE '%..%' on this table is a full scan, so only
# run it when the exact-title lookup came back empty.
PLACES_PREFIX = """
select url, coalesce(last_visit_date, 0) from moz_places
where title like ? || '%' and url is not null
order by last_visit_date desc limit 5
"""

ICONS_FOR_URL = """
select i.data, i.width, i.icon_url
from moz_pages_w_icons p
join moz_icons_to_pages ip on ip.page_id = p.id
join moz_icons i on i.id = ip.icon_id
where p.page_url = ? and i.data is not null
order by i.width desc
"""

ICONS_FOR_HOST = """
select i.data, i.width, i.icon_url
from moz_pages_w_icons p
join moz_icons_to_pages ip on ip.page_id = p.id
join moz_icons i on i.id = ip.icon_id
where p.page_url like ? and i.data is not null
order by i.width desc
-- bounded: rows are scanned one by one, and this runs for many titles
limit 20
"""

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# 64x64 Firefox flame (2019 logo, rasterized from the Wikimedia SVG), stamped
# into each favicon so the bar can tell a page favicon from the stock
# browser icon. Baked in to keep the helper self-contained. 64px keeps the
# stamp crisp when large favicons upscale it.
FF_LOGO_PNG = base64.b64decode("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")


def normalize_title(title):
    title = title.strip()
    for suffix in (" — Mozilla Firefox", " - Mozilla Firefox"):
        if title.endswith(suffix):
            title = title[: -len(suffix)].strip()
    # PWA windows may prefix the app name before the page title
    return title


def profile_dirs():
    """Every profile that has a places db, default profile first."""
    dirs = []
    try:
        with open(PROFILES_INI, "r", encoding="utf-8", errors="replace") as fh:
            name = None
            path = None
            for line in fh:
                line = line.strip()
                if line.startswith("Name="):
                    name = line.split("=", 1)[1]
                elif line.startswith("Path="):
                    path = line.split("=", 1)[1]
                elif not line and path:
                    full = path if os.path.isabs(path) else os.path.join(FF_ROOT, path)
                    dirs.append((name or "", full))
                    name = path = None
            if path:
                full = path if os.path.isabs(path) else os.path.join(FF_ROOT, path)
                dirs.append((name or "", full))
    except OSError:
        pass

    known = {d for _, d in dirs}
    for entry in sorted(os.listdir(FF_ROOT)) if os.path.isdir(FF_ROOT) else []:
        full = os.path.join(FF_ROOT, entry)
        if full not in known and os.path.exists(os.path.join(full, "places.sqlite")):
            dirs.append((entry, full))

    def is_default(item):
        name, path = item
        return 0 if (name == "default" or "default" in os.path.basename(path)) else 1

    return [p for _, p in sorted(dirs, key=is_default)]


def connect(path):
    return sqlite3.connect(f"file:{path}?immutable=1", uri=True)


def candidate_urls(profile, title):
    places = os.path.join(profile, "places.sqlite")
    if not os.path.exists(places):
        return []
    try:
        db = connect(places)
    except sqlite3.Error:
        return []
    rows = []
    try:
        with db:
            rows = list(db.execute(PLACES_EXACT, (title,)))
            if not rows:
                rows = list(db.execute(PLACES_PREFIX, (title,)))
    except sqlite3.Error:
        return []
    finally:
        db.close()
    rows.sort(key=lambda r: r[1] or 0, reverse=True)
    return [r[0] for r in rows]


def icons_for(profile, url):
    return icon_rows(favicons_path(profile), ICONS_FOR_URL, (url,))


def icons_for_host(profile, pattern):
    return icon_rows(favicons_path(profile), ICONS_FOR_HOST, (pattern,))


def favicons_path(profile):
    return os.path.join(profile, "favicons.sqlite")


def icon_rows(path, query, params):
    if not os.path.exists(path):
        return []
    try:
        db = connect(path)
    except sqlite3.Error:
        return []
    try:
        with db:
            return list(db.execute(query, params))
    except sqlite3.Error:
        return []
    finally:
        db.close()


def host_pattern(url):
    # "https://github.com/x?y#z" -> "https://github.com/%"
    parts = url.split("://", 1)
    if len(parts) != 2:
        return None
    scheme, rest = parts
    host = rest.split("/", 1)[0]
    return f"{scheme}://{host}/%" if host else None


def choose_best(rows):
    """Widest usable icon. Rows arrive width-desc, so the first PNG wins;
    an SVG/ICO (stored with width 65535) only wins when no PNG exists. The
    winner is rasterized exactly once - rasterizing every candidate turned a
    20-row host scan into minutes of inkscape invocations."""
    fallback = None
    for data, width, _icon_url in rows:
        if not isinstance(data, bytes):
            continue
        kind = icon_kind(data)
        if kind == "png":
            return ((width or 0), data)
        if kind in ("svg", "ico") and fallback is None:
            fallback = ((width or 0), data)
    if fallback:
        png = rasterize_svg(fallback[1])
        if png:
            return (fallback[0], png)
    return None


def write_cache(png):
    target = os.path.join(CACHE_DIR, hashlib.sha1(png).hexdigest() + ".png")
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if not os.path.exists(target):
            tmp = target + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(png)
            os.replace(tmp, target)
    except OSError:
        return None
    return target


def find_imagemagick():
    for candidate in ("magick", "convert"):
        for part in os.environ.get("PATH", "").split(":"):
            path = os.path.join(part, candidate)
            if os.access(path, os.X_OK):
                return path
    return None


def rasterize_svg(blob):
    exe = find_imagemagick()
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "-background", "none", "-density", "192", "svg:-", "-resize", "64x64", "png:-"],
            input=blob,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    data = out.stdout
    return data if data.startswith(PNG_MAGIC) else None


def icon_kind(blob):
    if blob.startswith(PNG_MAGIC):
        return "png"
    head = blob[:256].lstrip().lower()
    if head.startswith(b"<svg") or head.startswith(b"<?xml") or head.startswith(b"<!--"):
        return "svg"
    if blob[:4] in (b"\x00\x00\x01\x00", b"\x00\x00\x02\x00"):
        return "ico"
    return None


def stamp_ff_logo(favicon):
    """Paste a small FF flame into the favicon's bottom-left corner so the
    bar can tell a page favicon from the stock browser icon."""
    if not favicon.startswith(PNG_MAGIC):
        return favicon
    exe = find_imagemagick()
    if not exe:
        return favicon
    # IHDR sits at a fixed offset; width alone is enough to scale the stamp.
    # Constant 50% of the source: the bar normalizes every icon to 18px, so
    # only a constant ratio keeps the flame the same size on screen no matter
    # how big the site's stored favicon is. 128px caps the upscale of the
    # 64px logo for >256px favicons (rare) instead of blurring it.
    w = int.from_bytes(favicon[16:20], "big")
    logo_size = min(128, w // 2)
    with tempfile.TemporaryDirectory() as td:
        fav = os.path.join(td, "fav.png")
        logo = os.path.join(td, "logo.png")
        out = os.path.join(td, "out.png")
        try:
            with open(fav, "wb") as fh:
                fh.write(favicon)
            with open(logo, "wb") as fh:
                fh.write(FF_LOGO_PNG)
            # the 2px transparent border keeps the flame off the corner edge
            subprocess.run(
                [
                    exe, fav,
                    "(", logo, "-resize", f"{logo_size}x{logo_size}",
                    "-bordercolor", "none", "-border", "2", ")",
                    # -strip drops the tIME chunk, or the png bytes (and the
                    # cache hash) would differ on every run
                    "-gravity", "SouthWest", "-composite", "-strip", out,
                ],
                capture_output=True,
                timeout=5,
                check=True,
            )
            with open(out, "rb") as fh:
                data = fh.read()
        except (OSError, subprocess.SubprocessError) as e:
            # taffybar discards the helper's stderr, but a loud note here keeps
            # a broken composite from silently shipping plain favicons again.
            print(f"ff-favicon: logo stamp failed: {e}", file=sys.stderr)
            return favicon
    return data if data.startswith(PNG_MAGIC) else favicon


def main():
    if len(sys.argv) < 2:
        return 1
    title = normalize_title(sys.argv[1])
    if not title:
        return 1

    for profile in profile_dirs():
        urls = candidate_urls(profile, title)
        for url in urls:
            best = choose_best(icons_for(profile, url))
            if best:
                target = write_cache(stamp_ff_logo(best[1]))
                if target:
                    print(target)
                    return 0
        # favicons.sqlite is a pruned cache: the exact page_url row of an
        # older page is gone, so fall back to any recent page on the same
        # host, which still carries the site-wide favicon
        for url in urls:
            pattern = host_pattern(url)
            if pattern:
                best = choose_best(icons_for_host(profile, pattern))
                if best:
                    target = write_cache(stamp_ff_logo(best[1]))
                    if target:
                        print(target)
                        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
