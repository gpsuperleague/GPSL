#!/usr/bin/env python3
"""
Download latest home / away / third kit PNGs from colours-of-football.com.

Usage (from repo root):
  python scripts/fetch_club_kits.py
  python scripts/fetch_club_kits.py --dry-run
  python scripts/fetch_club_kits.py --only ARS,LIV,MCI

Output: images/clubs_kits/{ShortName}_home.png (and _away, _third)
Cache: data/club_kits_cof.json

No service role key needed — club list uses the anon key from supabase_client.js.
Kit files use the default paths on Club Details when club_kits DB rows are empty.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "images" / "clubs_kits"
CACHE_PATH = ROOT / "data" / "club_kits_cof.json"
SUPABASE_JS = ROOT / "supabase_client.js"

COF_BASE = "https://www.colours-of-football.com"
COF_COLOURS = f"{COF_BASE}/colours03"
UA = "GPSL-KitSync/1.0 (personal league project)"
COF_MIN_GAP_SEC = 1.4
COF_MAX_RETRIES = 6
_last_fetch_at = 0.0
_html_cache: dict[str, str] = {}


def season_code_to_start_year(code: int) -> int:
    s = str(code).zfill(4)
    yy = int(s[:2])
    return 2000 + yy if yy <= 30 else 1900 + yy


def is_plausible_kit_season_code(code: int) -> bool:
    start = season_code_to_start_year(code)
    return 1990 <= start <= 2040


def season_code_from_year_pair(y1_text: str, y2_text: str) -> int | None:
    raw1 = (y1_text or "").strip()
    raw2 = (y2_text or "").strip()
    try:
        y1 = int(raw1)
        y2 = int(raw2)
    except ValueError:
        return None

    if len(raw1) == 2:
        y1 = 2000 + y1 if y1 <= 30 else 1900 + y1
        y2 = 2000 + y2 if y2 <= 30 else 1900 + y2
    elif len(raw2) == 2:
        y2 = (y1 // 100) * 100 + y2
        if y2 < y1:
            y2 += 100

    if y1 < 1990 or y1 > 2040:
        return None
    if y2 < y1 or y2 > y1 + 1:
        return None

    code = int(str(y1)[-2:] + str(y2)[-2:])
    return code if is_plausible_kit_season_code(code) else None


def polite_pause() -> None:
    global _last_fetch_at
    elapsed = time.monotonic() - _last_fetch_at
    if elapsed < COF_MIN_GAP_SEC:
        time.sleep(COF_MIN_GAP_SEC - elapsed)


def fetch_text(url: str) -> str:
    global _last_fetch_at
    if url in _html_cache:
        return _html_cache[url]

    last_err: Exception | None = None
    for attempt in range(COF_MAX_RETRIES):
        polite_pause()
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html"})
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                _last_fetch_at = time.monotonic()
                if res.status in (429, 503):
                    time.sleep(min(30, 2 ** attempt * 2))
                    continue
                text = res.read().decode("utf-8", errors="replace")
                _html_cache[url] = text
                return text
        except urllib.error.HTTPError as e:
            _last_fetch_at = time.monotonic()
            if e.code in (429, 503) and attempt < COF_MAX_RETRIES - 1:
                time.sleep(min(30, 2 ** attempt * 2))
                continue
            last_err = e
            break
        except Exception as e:
            last_err = e
            if attempt < COF_MAX_RETRIES - 1:
                time.sleep(min(30, 1.5 ** attempt * 1.5))
    raise RuntimeError(f"COF fetch failed: {url}") from last_err


def download_bytes(url: str) -> bytes:
    global _last_fetch_at
    last_err: Exception | None = None
    for attempt in range(COF_MAX_RETRIES):
        polite_pause()
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "image/*"})
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                _last_fetch_at = time.monotonic()
                if res.status in (429, 503):
                    time.sleep(min(30, 2 ** attempt * 2))
                    continue
                return res.read()
        except urllib.error.HTTPError as e:
            _last_fetch_at = time.monotonic()
            if e.code in (429, 503) and attempt < COF_MAX_RETRIES - 1:
                time.sleep(min(30, 2 ** attempt * 2))
                continue
            last_err = e
            break
        except Exception as e:
            last_err = e
            if attempt < COF_MAX_RETRIES - 1:
                time.sleep(min(30, 1.5 ** attempt * 1.5))
    raise RuntimeError(f"Image download failed: {url}") from last_err

COF_NATION_MAP = {
    "england": ("eng", "eng.html"),
    "spain": ("esp", "esp.html"),
    "italy": ("ita", "italy.html"),
    "germany": ("ger", "germany.html"),
    "france": ("fra", "fra.html"),
    "netherlands": ("ned", "ned.html"),
    "portugal": ("por", "por.html"),
    "belgium": ("bel", "belgium.html"),
    "scotland": ("sco", "scotland.html"),
    "turkey": ("tur", "tur.html"),
    "turkiye": ("tur", "tur.html"),
    "brazil": ("bra", "bra.html"),
    "argentina": ("arg", "arg.html"),
    "usa": ("usa", "usa.html"),
    "united states": ("usa", "usa.html"),
    "mexico": ("mex", "mex.html"),
    "japan": ("jap", "jap.html"),
    "korea": ("kor", "kor.html"),
    "south korea": ("kor", "kor.html"),
    "korea republic": ("kor", "kor.html"),
    "denmark": ("den", "den.html"),
    "sweden": ("swe", "swe.html"),
    "norway": ("nor", "nor.html"),
    "austria": ("aut", "aut.html"),
    "switzerland": ("sui", "sui.html"),
    "poland": ("pol", "pol.html"),
    "greece": ("gre", "gre.html"),
    "russia": ("rus", "rus.html"),
    "ukraine": ("ukr", "ukr.html"),
    "croatia": ("cro", "cro.html"),
    "romania": ("rom", "rom.html"),
    "czech republic": ("cze", "cze.html"),
    "czechia": ("cze", "cze.html"),
    "hungary": ("hungary", "hungary.html"),
    "ireland": ("irl", "irl.html"),
    "republic of ireland": ("irl", "irl.html"),
    "wales": ("wales", "wales.html"),
    "serbia": ("serbia", "serbia.html"),
    "chile": ("chile", "chile.html"),
    "colombia": ("col", "col.html"),
    "uruguay": ("uru", "uru.html"),
    "paraguay": ("paraguay", "paraguay.html"),
    "peru": ("peru", "peru.html"),
    "ecuador": ("ecuador", "ecuador.html"),
    "bolivia": ("bolivia", "bolivia.html"),
    "venezuela": ("venezuela", "venezuela.html"),
    "australia": ("aus", "aus.html"),
    "china": ("chn", "chn.html"),
    "saudi arabia": ("sau", "sau.html"),
    "israel": ("israel", "israel.html"),
}

COF_CLUB_SLUG_OVERRIDES: dict[str, str] = {
    "AVL": "a_villa",
    "TOT": "tottenham",
    "WOL": "wolverhampton",
    "MUN": "manutd",
    "MCI": "man_city",
    "NEW": "newcastle",
    "WHU": "westham",
    "BHA": "brighton",
    "BOU": "bournemouth",
    "BRE": "brentford",
    "CRY": "crystal_palace",
    "FUL": "fulham",
    "LEI": "leicester",
    "LUT": "luton",
    "NFO": "nottm_f",
    "SHU": "sheff_utd",
    "IPS": "ipswich",
    "BAR": "barcelona",
    "ATM": "atletico",
    "RMA": "real_madrid",
    "BET": "betis",
    "CEL": "celta",
    "GET": "getafe",
    "GIR": "girona",
    "LPA": "las_palmas",
    "MLL": "mallorca",
    "OSA": "osasuna",
    "RAY": "rayo",
    "RSO": "real_sociedad",
    "SEV": "sevilla",
    "VAL": "valencia",
    "VIL": "villarreal",
    "JUV": "juventus",
    "INT": "inter",
    "MIL": "milan",
    "ATA": "atalanta",
    "BOL": "bologna",
    "CAG": "cagliari",
    "EMP": "empoli",
    "FIO": "fiorentina",
    "GEN": "genoa",
    "LAZ": "lazio",
    "LEC": "lecce",
    "MON": "monza",
    "MOC": "monaco",
    "NAP": "napoli",
    "ROM": "roma",
    "TOR": "torino",
    "UDI": "udinese",
    "VER": "verona",
    "BAY": "bayern",
    "DOR": "dortmund",
    "LEV": "leverkusen",
    "RBL": "leipzig",
    "STU": "stuttgart",
    "PSG": "psg",
    "LYO": "lyon",
    "MAR": "marseille",
    "LIL": "lille",
    "REN": "rennes",
    "AJX": "ajax",
    "FEY": "feyenoord",
    "PSV": "psv",
    "AZA": "az",
    "TWE": "twente",
    "BEN": "benfica",
    "POR": "porto",
    "SPO": "sporting",
    "BRU": "anderlecht",
    "AND": "anderlecht",
    "NAC": "atletico_nacional",
    "BES": "besiktas",
    "GAL": "galatasaray",
    "FEN": "fenerbahce",
    "FLA": "flamengo",
    "PAL": "palmeiras",
    "COR": "corinthians",
    "SAO": "saopaulo",
    "SAN": "santos",
    "BOC": "boca",
}

STRIP_WORDS = re.compile(
    r"\b(fc|afc|cf|sc|ac|sv|sk|united|city|town|rovers|wanderers|hotspur|athletic|club|deportivo|real|balompie|sporting)\b",
    re.I,
)


def read_supabase_config() -> tuple[str, str]:
    text = SUPABASE_JS.read_text(encoding="utf-8")
    m = re.search(r'createClient\(\s*\n?\s*"([^"]+)",\s*\n?\s*"([^"]+)"', text)
    if not m:
        raise RuntimeError("Could not parse supabase_client.js")
    return m.group(1), m.group(2)


def fetch_json(url: str, headers: dict | None = None) -> object:
    req = urllib.request.Request(url, headers=headers or {"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.loads(res.read().decode("utf-8"))


def head_ok(url: str) -> bool:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return 200 <= res.status < 300
    except urllib.error.HTTPError as e:
        return e.code == 200


def safe_print(text: str) -> None:
    enc = getattr(sys.stdout, "encoding", None) or "utf-8"
    sys.stdout.write(text.encode(enc, errors="replace").decode(enc, errors="replace"))
    sys.stdout.flush()


def normalize_nation(nation: str) -> str:
    s = unicodedata.normalize("NFD", nation or "")
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", s.lower().strip())


def normalize_club(name: str) -> str:
    s = (name or "").lower()
    s = STRIP_WORDS.sub(" ", s)
    s = re.sub(r"[^a-z0-9]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def strip_tags(html: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html)).strip()


def parse_index_links(html: str) -> list[dict]:
    links = []
    seen = set()
    for m in re.finditer(
        r'<a[^>]+href="([^"#?]+\/[^"#?]+_1\.html)"[^>]*>([\s\S]*?)<\/a>',
        html,
        re.I,
    ):
        href = m.group(1).lstrip("./")
        if href in seen or href.startswith("http") or ".." in href:
            continue
        seen.add(href)
        inner = m.group(2)
        alt = re.search(r'alt="([^"]+)"', inner, re.I)
        name = strip_tags(alt.group(1) if alt else inner)
        parts = href.split("/")
        if len(parts) < 2 or not name:
            continue
        links.append(
            {
                "name": name,
                "slug": parts[0],
                "page_stem": re.sub(r"_1\.html$", "", parts[1], flags=re.I),
            }
        )
    return links


def match_club_link(links: list[dict], club_name: str) -> dict | None:
    target = normalize_club(club_name)
    if not target:
        return None
    best = None
    best_score = 0
    for link in links:
        name = normalize_club(link["name"])
        if not name:
            continue
        if name == target:
            return link
        score = 0
        if target in name or name in target:
            score = min(len(name), len(target))
        else:
            tt = [t for t in target.split() if len(t) > 2]
            nt = {t for t in name.split() if len(t) > 2}
            overlap = sum(1 for t in tt if t in nt)
            if overlap >= 2:
                score = overlap * 10
            elif overlap == 1 and len(tt) == 1:
                score = 8
        if score > best_score:
            best_score = score
            best = link
    return best if best_score >= 6 else None


def resolve_url(page_url: str, src: str) -> str:
    if src.startswith("http"):
        return src
    if src.startswith("/"):
        return COF_BASE + src
    base = page_url.rsplit("/", 1)[0] + "/"
    return urllib.parse.urljoin(base, src)


def parse_kit_candidates(html: str, page_url: str) -> dict[str, list]:
    buckets: dict[str, list] = {"home": [], "away": [], "third": []}
    for m in re.finditer(r'src="([^"]+\.(?:png|gif))"', html, re.I):
        src = m.group(1)
        file = src.split("/")[-1]
        km = re.search(r"_(\d)_(\d{4})(?:_(\d+))?\.(?:png|gif)$", file, re.I)
        if not km:
            continue
        kit_num = int(km.group(1))
        season = int(km.group(2))
        variant = int(km.group(3) or 0)
        if kit_num < 1 or kit_num > 3:
            continue
        kind = ["home", "away", "third"][kit_num - 1]
        buckets[kind].append(
            {"season": season, "variant": variant, "url": resolve_url(page_url, src)}
        )
    return buckets


def format_season_code(code: int | None) -> str | None:
    if not code:
        return None
    y1 = season_code_to_start_year(code)
    y2 = y1 + 1
    return f"{y1}-{str(y2)[-2:]}"


def find_latest_season_from_html(html: str) -> int | None:
    best_code = 0
    best_start = 0

    def consider(code: int | None) -> None:
        nonlocal best_code, best_start
        if not code or not is_plausible_kit_season_code(code):
            return
        start = season_code_to_start_year(code)
        if start > best_start:
            best_start = start
            best_code = code

    for m in re.finditer(
        r"(?:home|away|third)\s+kit\s+(\d{4})\s*[-–/]\s*(\d{2,4})",
        html,
        re.I,
    ):
        consider(season_code_from_year_pair(m.group(1), m.group(2)))

    for m in re.finditer(
        r"(?:home|away|third)\s+kit\s+(\d{2})\s*[-–/]\s*(\d{2})",
        html,
        re.I,
    ):
        consider(season_code_from_year_pair(m.group(1), m.group(2)))

    return best_code or None


def pick_latest_kits(buckets: dict[str, list], latest_season: int | None = None) -> dict[str, str | None]:
    out: dict[str, str | None] = {"home": None, "away": None, "third": None}
    season_year = season_code_to_start_year(latest_season) if latest_season else None
    for kind, arr in buckets.items():
        if not arr:
            continue
        pool = arr
        if season_year:
            filtered = [x for x in arr if x["season"] == season_year]
            if filtered:
                pool = filtered
        max_season = max(x["season"] for x in pool)
        top = [x for x in pool if x["season"] == max_season]
        top.sort(key=lambda x: (x["variant"], x["url"]))
        out[kind] = top[0]["url"]
    return out


def merge_buckets(a: dict[str, list], b: dict[str, list]) -> dict[str, list]:
    return {
        "home": a["home"] + b["home"],
        "away": a["away"] + b["away"],
        "third": a["third"] + b["third"],
    }


def find_last_page(folder: str, slug: str, stem: str) -> int:
    last = 1
    for page in range(1, 13):
        url = f"{COF_COLOURS}/{folder}/{slug}/{stem}_{page}.html"
        try:
            fetch_text(url)
            last = page
        except RuntimeError:
            break
    return last


def fetch_latest_kits(nation: str, club_name: str, short: str) -> dict:
    key = normalize_nation(nation)
    cfg = COF_NATION_MAP.get(key)
    if not cfg:
        return {"error": f"No COF mapping for nation: {nation}"}

    folder, index = cfg
    index_html = fetch_text(f"{COF_COLOURS}/{folder}/{index}")
    links = parse_index_links(index_html)

    override = COF_CLUB_SLUG_OVERRIDES.get(short)
    link = None
    if override:
        link = next((l for l in links if l["slug"] == override or l["page_stem"] == override), None)
    if not link:
        link = match_club_link(links, club_name)
    if not link:
        return {"error": f"Club not found on COF ({folder}): {club_name}"}

    last = find_last_page(folder, link["slug"], link["page_stem"])
    buckets: dict[str, list] = {"home": [], "away": [], "third": []}
    html_parts: list[str] = []
    for page in range(1, last + 1):
        page_url = f"{COF_COLOURS}/{folder}/{link['slug']}/{link['page_stem']}_{page}.html"
        html = fetch_text(page_url)
        html_parts.append(html)
        buckets = merge_buckets(buckets, parse_kit_candidates(html, page_url))

    latest_season = find_latest_season_from_html("\n".join(html_parts))
    merged = pick_latest_kits(buckets, latest_season)

    return {
        "cof_name": link["name"],
        "slug": link["slug"],
        "season_label": format_season_code(latest_season),
        "kits": merged,
    }


def fetch_clubs() -> list[dict]:
    url, anon = read_supabase_config()
    api = (
        f"{url}/rest/v1/Clubs"
        "?select=ShortName,Club,Nation&ShortName=neq.FOREIGN&order=Club"
    )
    return fetch_json(
        api,
        {"apikey": anon, "Authorization": f"Bearer {anon}"},
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--only", help="Comma-separated ShortNames")
    args = parser.parse_args()

    only = {s.strip().upper() for s in args.only.split(",")} if args.only else None
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cache = {}
    if CACHE_PATH.exists():
        cache = json.loads(CACHE_PATH.read_text(encoding="utf-8"))

    clubs = fetch_clubs()
    ok = fail = 0

    for club in clubs:
        short = club["ShortName"]
        if only and short not in only:
            continue
        print(f"{short} ({club['Club']}) ... ", end="", flush=True)
        try:
            result = fetch_latest_kits(club["Nation"], club["Club"], short)
            if result.get("error"):
                raise RuntimeError(result["error"])

            kits = result["kits"]
            saved = {}
            for kind, src in kits.items():
                if not src:
                    continue
                if args.dry_run:
                    saved[kind] = src
                    continue
                data = download_bytes(src)
                out = OUT_DIR / f"{short}_{kind}.png"
                out.write_bytes(data)
                saved[kind] = str(out.relative_to(ROOT)).replace("\\", "/")

            cache[short] = {
                "club": club["Club"],
                "nation": club["Nation"],
                "cof_name": result.get("cof_name"),
                "slug": result.get("slug"),
                "kits": saved,
                "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            print("ok" if saved else "no kits found")
            ok += 1
            time.sleep(1.5)
        except Exception as e:
            msg = str(e).encode("ascii", errors="replace").decode("ascii")
            safe_print(f"fail - {msg}\n")
            fail += 1

    if not args.dry_run:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CACHE_PATH.write_text(json.dumps(cache, indent=2), encoding="utf-8")

    print(f"\nDone: {ok} ok, {fail} failed")


if __name__ == "__main__":
    main()
