#!/usr/bin/env python3
"""Resolve a Firefox window title to that page's cached favicon.

Prints the path of a PNG (cached under ~/.cache/taffybar/favicons) or nothing.

Firefox keeps page titles in places.sqlite and icon blobs in favicons.sqlite,
both in the profile dir. They are opened read-only+immutable so this works
while Firefox holds its write lock.
"""

import hashlib
import os
import sqlite3
import subprocess
import sys

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

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


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
    favicons = os.path.join(profile, "favicons.sqlite")
    if not os.path.exists(favicons):
        return []
    try:
        db = connect(favicons)
    except sqlite3.Error:
        return []
    try:
        with db:
            return list(db.execute(ICONS_FOR_URL, (url,)))
    except sqlite3.Error:
        return []
    finally:
        db.close()


def rasterize_svg(blob):
    exe = None
    for candidate in ("magick", "convert"):
        for part in os.environ.get("PATH", "").split(":"):
            path = os.path.join(part, candidate)
            if os.access(path, os.X_OK):
                exe = path
                break
        if exe:
            break
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


def pick_icon(blob):
    """PNG/ICO pass through; SVG is rasterized. Firefox stores SVGs with
    width=65535, so width alone cannot rank them."""
    if blob.startswith(PNG_MAGIC):
        return blob
    head = blob[:256].lstrip().lower()
    if head.startswith(b"<svg") or head.startswith(b"<?xml") or head.startswith(b"<!--"):
        return rasterize_svg(blob)
    if blob[:4] in (b"\x00\x00\x01\x00", b"\x00\x00\x02\x00"):
        return rasterize_svg(blob)
    return None


def main():
    if len(sys.argv) < 2:
        return 1
    title = normalize_title(sys.argv[1])
    if not title:
        return 1

    for profile in profile_dirs():
        for url in candidate_urls(profile, title):
            best = None
            for data, width, icon_url in icons_for(profile, url):
                if not isinstance(data, bytes):
                    continue
                png = pick_icon(data)
                if png and (best is None or (width or 0) > best[0]):
                    best = ((width or 0), png)
            if not best:
                continue
            target = os.path.join(CACHE_DIR, hashlib.sha1(best[1]).hexdigest() + ".png")
            try:
                os.makedirs(CACHE_DIR, exist_ok=True)
                if not os.path.exists(target):
                    tmp = target + ".tmp"
                    with open(tmp, "wb") as fh:
                        fh.write(best[1])
                    os.replace(tmp, target)
            except OSError:
                continue
            print(target)
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
