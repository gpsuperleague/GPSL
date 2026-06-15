#!/usr/bin/env python3
"""
PESDB eFootball player scraper for GPSL GPDB sync.

Outputs CSV compatible with admin_gpdb_sync.html upload:
  player_id, Position, player_name, nationality, age, rating, max_level_rating, playing_style

Requirements:
  pip install selenium webdriver-manager beautifulsoup4 lxml requests

Usage:
  python scripts/pesdb_scrape.py
  python scripts/pesdb_scrape.py --start 1 --end 50 --output pesdb_full.csv

  # Recommended when PESDB throttles after ~2 list pages of details:
  python scripts/pesdb_scrape.py --list-only --start 1 --end 633 --output pesdb_list.csv
  # (writes to scrape_output/pesdb_list.csv — not committed to git)
  python scripts/pesdb_scrape.py --enrich pesdb_list.csv --output pesdb_full.csv
  # Fast HTTP enrich (default): ~1–2h for ~19k players with --workers 8
  # Slow browser fallback: --browser --delay 2.5
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

try:
    import requests
except ImportError:
    requests = None  # type: ignore[assignment]

SCRAPE_OUTPUT_DIR = Path("scrape_output")

from bs4 import BeautifulSoup
from selenium import webdriver
from selenium.common.exceptions import WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait
from webdriver_manager.chrome import ChromeDriverManager

BASE_URL = "https://pesdb.net/efootball/"
PLAYING_STYLES = [
    "Goal Poacher", "Dummy Runner", "Fox in the Box", "Prolific Winger",
    "Classic No. 10", "Hole Player", "Box-to-Box", "Anchor Man",
    "The Destroyer", "Extra Frontman", "Offensive Full-back",
    "Defensive Full-back", "Target Man", "Creative Playmaker",
    "Build Up", "Offensive Goalkeeper", "Defensive Goalkeeper",
    "Roaming Flank", "Cross Specialist", "Orchestrator", "Full-back Finisher",
    "Deep-Lying Forward",
]
CSV_HEADER = [
    "player_id", "Position", "player_name", "nationality", "age",
    "rating", "max_level_rating", "playing_style",
]

RATE_LIMIT_MARKERS = (
    "429",
    "too many requests",
    "rate limit",
    "access denied",
    "captcha",
    "cloudflare",
    "please wait",
    "blocked",
)

HTTP_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

_http_thread_local = threading.local()


class ThrottleState:
    """Shared pause when PESDB returns 429 — all workers wait together."""

    def __init__(self):
        self._lock = threading.Lock()
        self._pause_until = 0.0
        self._last_warn = 0.0

    def wait_if_paused(self) -> None:
        with self._lock:
            wait = self._pause_until - time.monotonic()
        if wait > 0:
            time.sleep(wait)

    def on_429(self, attempt: int) -> None:
        pause = min(600.0, 30.0 * attempt)
        with self._lock:
            self._pause_until = max(self._pause_until, time.monotonic() + pause)
            should_warn = time.monotonic() - self._last_warn > 20.0
            if should_warn:
                self._last_warn = time.monotonic()
                msg = (
                    f"⏸ PESDB rate limit (HTTP 429) — pausing {pause:.0f}s "
                    f"(try fewer workers / higher --delay if this repeats)"
                )
            else:
                msg = ""
        if msg:
            print(msg, flush=True)
        time.sleep(pause)


def find_players_table(soup: BeautifulSoup):
    """PESDB player list uses <table class="players"> — not the first <table> on the page."""
    table = soup.select_one("table.players")
    if table:
        return table
    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        player_links = table.find_all("a", href=re.compile(r"\?id="))
        if len(rows) >= 5 and len(player_links) >= 3:
            return table
    return None


def diagnose_page_html(html: str, page: int) -> str:
    lower = html.lower()
    for marker in RATE_LIMIT_MARKERS:
        if marker in lower:
            return f"possible rate limit / block ({marker!r})"
    if "players found" in lower:
        return "page mentions player count but players table missing — try slower delays or --no-headless"
    title_m = re.search(r"<title[^>]*>([^<]+)</title>", html, re.I)
    title = title_m.group(1).strip() if title_m else "unknown title"
    return f"title={title!r}, html_len={len(html)}"


def save_debug_html(page: int, html: str) -> Path:
    SCRAPE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    path = SCRAPE_OUTPUT_DIR / f"pesdb_debug_page{page}.html"
    path.write_text(html, encoding="utf-8")
    return path


def resolve_output_path(raw: str, start: int, end: int) -> Path:
    if raw:
        p = Path(raw)
        if not p.is_absolute() and p.parent == Path("."):
            SCRAPE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
            return SCRAPE_OUTPUT_DIR / p.name
        return p
    SCRAPE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    return SCRAPE_OUTPUT_DIR / f"pesdb_scrape_pages{start}-{end or start}.csv"


def progress_path_for(output: Path) -> Path:
    return output.with_suffix(output.suffix + ".progress")


def read_last_completed_page(output: Path) -> int:
    prog = progress_path_for(output)
    if not prog.is_file():
        return 0
    text = prog.read_text(encoding="utf-8").strip()
    m = re.search(r"last_page=(\d+)", text)
    return int(m.group(1)) if m else 0


def write_last_completed_page(output: Path, page: int) -> None:
    progress_path_for(output).write_text(f"last_page={page}\n", encoding="utf-8")


def safe_quit_driver(driver) -> None:
    if driver is None:
        return
    try:
        driver.quit()
    except Exception:
        pass


class DriverSession:
    def __init__(self, headless: bool):
        self.headless = headless
        self.driver = make_driver(headless)

    def restart(self, reason: str = "") -> webdriver.Chrome:
        if reason:
            print(f"🔄 Restarting Chrome ({reason})…")
        safe_quit_driver(self.driver)
        time.sleep(2.0)
        self.driver = make_driver(self.headless)
        return self.driver

    def close(self) -> None:
        safe_quit_driver(self.driver)
        self.driver = None


def is_driver_window_error(exc: BaseException) -> bool:
    msg = str(exc).lower()
    return (
        "no such window" in msg
        or "web view not found" in msg
        or "invalid session id" in msg
        or "session deleted" in msg
        or "disconnected" in msg
        or "not connected to devtools" in msg
    )


def wait_for_players_table(driver, timeout: float) -> bool:
    try:
        WebDriverWait(driver, timeout).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "table.players"))
        )
        return True
    except Exception:
        return False


def build_url(page: int, filters: dict) -> str:
    params = [f"{k}={v}" for k, v in filters.items()]
    if page > 1:
        params.append(f"page={page}")
    if not params:
        return BASE_URL
    return BASE_URL + "?" + "&".join(params)


def extract_player_id(href: str | None) -> str | None:
    if href and "?id=" in href:
        return href.split("?id=")[1].split("&")[0]
    return None


def parse_max_rating(page_text: str, soup: BeautifulSoup) -> str:
    overall_pattern = re.search(r"Overall Rating:\s*\(\+\d+\)\s*(\d+)", page_text)
    if overall_pattern:
        return overall_pattern.group(1)

    overall_matches = re.findall(
        r"Overall Rating[:\s]*(?:\(\+\d+\))?\s*(\d+)", page_text
    )
    if overall_matches:
        nums = [int(x) for x in overall_matches if x.isdigit()]
        if nums:
            return str(max(nums))

    for table in soup.find_all("table"):
        for row in table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            for i, cell in enumerate(cells):
                if "overall rating" in cell.get_text(strip=True).lower() and i + 1 < len(cells):
                    rating_text = cells[i + 1].get_text(strip=True)
                    m = re.search(r"\(\+\d+\)\s*(\d+)", rating_text)
                    if m:
                        return m.group(1)
                    nums = re.findall(r"\d+", rating_text)
                    if nums:
                        return nums[-1]
    return "Unknown"


def parse_playing_style(page_text: str, soup: BeautifulSoup, page_html: str = "") -> str:
    html = page_html or str(soup)

    # PESDB max-level layout: <tr><th>Playing Style</th></tr><tr><td>Goal Poacher</td></tr>
    m = re.search(
        r"<tr>\s*<th>\s*Playing Style\s*</th>\s*</tr>\s*<tr>\s*<td>([^<]+)</td>",
        html,
        re.I,
    )
    if m:
        candidate = m.group(1).strip()
        for style in PLAYING_STYLES:
            if style.lower() == candidate.lower():
                return style

    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        for i, row in enumerate(rows):
            headers = row.find_all("th")
            if len(headers) != 1:
                continue
            if "playing style" not in headers[0].get_text(strip=True).lower():
                continue

            row_tds = row.find_all("td")
            if row_tds:
                candidate = row_tds[0].get_text(strip=True)
                for style in PLAYING_STYLES:
                    if style.lower() == candidate.lower():
                        return style

            if i + 1 < len(rows):
                next_row = rows[i + 1]
                if next_row.find("th"):
                    continue
                next_tds = next_row.find_all("td")
                if len(next_tds) == 1:
                    candidate = next_tds[0].get_text(strip=True)
                    for style in PLAYING_STYLES:
                        if style.lower() == candidate.lower():
                            return style

    for style in PLAYING_STYLES:
        if re.search(rf"<td>\s*{re.escape(style)}\s*</td>", html, re.I):
            return style

    for style in PLAYING_STYLES:
        if f"Playing Style: {style}" in page_text or f"playing style: {style}" in page_text.lower():
            return style
    return "None"


def get_player_details(
    session: DriverSession,
    player_id: str | None,
    delay: float,
    retries: int = 4,
) -> tuple[str, str]:
    if not player_id:
        return "Unknown", "Unknown"

    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            driver = session.driver
            url = f"{BASE_URL}?id={player_id}&mode=max_level"
            driver.get(url)
            time.sleep(delay)
            page_html = driver.page_source
            soup = BeautifulSoup(page_html, "lxml")
            page_text = soup.get_text()
            style = parse_playing_style(page_text, soup, page_html)
            max_rating = parse_max_rating(page_text, soup)
            return style, max_rating
        except WebDriverException as exc:
            last_error = exc
            if is_driver_window_error(exc) and attempt < retries:
                print(f"     browser lost — restarting ({attempt}/{retries})…")
                session.restart("enrich/detail session crashed")
                time.sleep(max(2.0, delay))
                continue
            print(f"     warn: player {player_id}: {exc}", file=sys.stderr)
            break
        except Exception as exc:
            last_error = exc
            if attempt < retries:
                print(f"     retry {player_id} ({attempt}/{retries}): {exc}")
                session.restart("detail fetch failed")
                time.sleep(max(2.0, delay))
                continue
            print(f"     warn: player {player_id}: {exc}", file=sys.stderr)
            break

    if last_error:
        print(f"     failed: player {player_id}", file=sys.stderr)
    return "None", "Unknown"


def estimate_total_pages(driver, filters: dict) -> int:
    driver.get(build_url(1, filters))
    time.sleep(2.5)
    soup = BeautifulSoup(driver.page_source, "lxml")
    text = soup.get_text()
    m = re.search(r"\((\d+) players found\)", text)
    if m:
        total = int(m.group(1))
        pages = (total // 30) + 1
        print(f"Found {total} players (~{pages} pages)")
        return pages
    links = soup.find_all("a", href=re.compile(r"page=\d+"))
    nums = []
    for link in links:
        href = link.get("href") or ""
        pm = re.search(r"page=(\d+)", href)
        if pm:
            nums.append(int(pm.group(1)))
    return max(nums) if nums else 100


def scrape_list_page(
    session: DriverSession,
    page: int,
    filters: dict,
    list_delay: float,
    detail_delay: float,
    page_retries: int,
    retry_wait: float,
    list_only: bool = False,
) -> list[list[str]]:
    url = build_url(page, filters)
    print(f"📄 Scraping page {page}")
    print(f"🔗 URL: {url}")

    html = ""
    soup = None
    table = None
    driver = session.driver

    for attempt in range(1, page_retries + 1):
        try:
            driver.get(url)
            loaded = wait_for_players_table(driver, list_delay + 2.0)
            if not loaded:
                time.sleep(max(1.0, list_delay))
            html = driver.page_source
        except WebDriverException as exc:
            if is_driver_window_error(exc) and attempt < page_retries:
                driver = session.restart("browser window closed or crashed")
                wait_s = max(5.0, retry_wait * 0.5)
                print(f"   retrying page {page} in {wait_s:.0f}s…")
                time.sleep(wait_s)
                continue
            raise

        soup = BeautifulSoup(html, "lxml")
        table = find_players_table(soup)
        if table:
            break

        diag = diagnose_page_html(html, page)
        wait_s = retry_wait * attempt
        print(f"⚠️ No players table on page {page} (attempt {attempt}/{page_retries}) — {diag}")
        if attempt < page_retries:
            print(f"   waiting {wait_s:.0f}s before retry (PESDB may be throttling your IP)…")
            time.sleep(wait_s)
            if "rate limit" in diag or "blocked" in diag or "429" in diag:
                driver = session.restart("possible PESDB throttle")

    if not table:
        debug_path = save_debug_html(page, html)
        print(
            f"❌ Giving up on page {page}. Saved HTML → {debug_path.resolve()}\n"
            "   Tips: rerun with --no-headless, increase --list-delay / --page-delay,\n"
            "   wait 30–60 min, or resume with --start {page} after pages 1–{prev} finished."
            .format(page=page, prev=page - 1),
            file=sys.stderr,
        )
        return []

    tbody = table.find("tbody")
    rows = tbody.find_all("tr") if tbody else table.find_all("tr")[1:]
    out: list[list[str]] = []

    for row in rows:
        cols = row.find_all("td")
        if len(cols) < 8:
            continue
        position = cols[0].get_text(strip=True)
        name_cell = cols[1]
        player_name = name_cell.get_text(strip=True)
        link = name_cell.find("a")
        player_id = extract_player_id(link.get("href") if link else None)
        nationality = cols[3].get_text(strip=True)
        age = cols[6].get_text(strip=True)
        rating = cols[7].get_text(strip=True)

        print(f"   {player_name} ({player_id})")
        if list_only:
            playing_style, max_rating = "None", rating
        else:
            try:
                playing_style, max_rating = get_player_details(
                    session, player_id, detail_delay
                )
            except WebDriverException as exc:
                if is_driver_window_error(exc):
                    session.restart("browser window closed during player detail")
                    playing_style, max_rating = get_player_details(
                        session, player_id, detail_delay
                    )
                else:
                    raise
            time.sleep(detail_delay)
        out.append([
            player_id or "",
            position,
            player_name,
            nationality,
            age,
            rating,
            max_rating,
            playing_style,
        ])
    return out


def read_csv_rows(path: Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        rows = list(reader)
    if not rows:
        return CSV_HEADER[:], []
    return rows[0], rows[1:]


def write_csv_rows(path: Path, header: list[str], data: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(data)


def col_index(header: list[str]) -> dict[str, int]:
    norm = {h.strip().lower(): i for i, h in enumerate(header)}
    idx = {}
    for key, aliases in {
        "player_id": ("player_id", "konami_id", "id"),
        "max_level_rating": ("max_level_rating", "potential"),
        "playing_style": ("playing_style", "playstyle"),
    }.items():
        for alias in aliases:
            if alias in norm:
                idx[key] = norm[alias]
                break
    return idx


class RateLimiter:
    """Global minimum interval between HTTP requests (shared across worker threads)."""

    def __init__(self, min_interval: float):
        self._min_interval = max(0.0, min_interval)
        self._lock = threading.Lock()
        self._last = 0.0

    def wait(self) -> None:
        if self._min_interval <= 0:
            return
        with self._lock:
            now = time.monotonic()
            wait = self._min_interval - (now - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()


def get_http_session():
    if requests is None:
        raise RuntimeError("requests is required for HTTP enrich: pip install requests")
    session = getattr(_http_thread_local, "session", None)
    if session is None:
        session = requests.Session()
        session.headers.update(HTTP_HEADERS)
        _http_thread_local.session = session
    return session


def parse_player_detail_html(html: str) -> tuple[str, str]:
    soup = BeautifulSoup(html, "lxml")
    page_text = soup.get_text()
    style = parse_playing_style(page_text, soup, html)
    max_rating = parse_max_rating(page_text, soup)
    return style, max_rating


def html_looks_blocked(html: str) -> bool:
    lower = html.lower()
    if len(html) < 500:
        return True
    for marker in RATE_LIMIT_MARKERS:
        if marker in lower:
            return True
    return False


def fetch_player_detail_http(
    player_id: str,
    rate_limiter: RateLimiter,
    throttle: ThrottleState | None = None,
    retries: int = 5,
) -> tuple[str, str]:
    if not player_id:
        return "Unknown", "Unknown"

    url = f"{BASE_URL}?id={player_id}&mode=max_level"
    session = get_http_session()
    throttle = throttle or ThrottleState()
    for attempt in range(1, retries + 1):
        throttle.wait_if_paused()
        rate_limiter.wait()
        try:
            resp = session.get(url, timeout=30)
        except requests.RequestException as exc:
            if attempt < retries:
                time.sleep(min(30.0, 2.0 * attempt))
                continue
            print(f"     warn: player {player_id}: {exc}", file=sys.stderr, flush=True)
            return "None", "Unknown"

        if resp.status_code == 429:
            throttle.on_429(attempt)
            continue
        if resp.status_code == 404:
            return "None", "Unknown"
        if resp.status_code >= 500:
            time.sleep(min(30.0, 2.0 * attempt))
            continue
        if resp.status_code != 200:
            time.sleep(min(15.0, 1.5 * attempt))
            continue
        if html_looks_blocked(resp.text):
            throttle.on_429(attempt)
            continue

        return parse_player_detail_html(resp.text)

    return "None", "Unknown"


def probe_pesdb_http(player_id: str) -> int:
    if requests is None:
        return 0
    try:
        resp = requests.get(
            f"{BASE_URL}?id={player_id}&mode=max_level",
            headers=HTTP_HEADERS,
            timeout=30,
        )
        return resp.status_code
    except requests.RequestException:
        return 0


def resolve_delay(args, mode: str) -> float:
    if args.delay is not None:
        return args.delay
    if mode == "enrich_http":
        return 1.0
    if mode == "enrich_browser":
        return 2.5
    return 1.5


def prepare_enrich_job(args):
    in_path = Path(args.enrich)
    if not in_path.is_file():
        print(f"File not found: {in_path}", file=sys.stderr)
        return None

    out_path = Path(args.output) if args.output else in_path
    if args.resume and out_path.is_file():
        header, data = read_csv_rows(out_path)
        print(f"Resume: loaded {len(data)} rows from {out_path.name}")
    else:
        header, data = read_csv_rows(in_path)
    idx = col_index(header)
    if "player_id" not in idx:
        print("CSV must include player_id / konami_id column", file=sys.stderr)
        return None

    max_i = idx.get("max_level_rating")
    style_i = idx.get("playing_style")
    if max_i is None:
        header = header + ["max_level_rating"]
        max_i = len(header) - 1
        data = [row + [""] for row in data]
    if style_i is None:
        header = header + ["playing_style"]
        style_i = len(header) - 1
    data = [row + [""] * (len(header) - len(row)) for row in data]

    targets = [i for i, row in enumerate(data) if needs_enrichment(row, idx)]
    if args.enrich_start > 0:
        targets = [i for i in targets if i >= args.enrich_start - 1]
    if args.enrich_end > 0:
        targets = [i for i in targets if i < args.enrich_end]

    return {
        "in_path": in_path,
        "out_path": out_path,
        "header": header,
        "data": data,
        "idx": idx,
        "max_i": max_i,
        "style_i": style_i,
        "targets": targets,
    }


def needs_enrichment(row: list[str], idx: dict[str, int]) -> bool:
    max_i = idx.get("max_level_rating")
    style_i = idx.get("playing_style")
    max_val = row[max_i].strip() if max_i is not None and max_i < len(row) else ""
    style_val = row[style_i].strip() if style_i is not None and style_i < len(row) else ""
    if not max_val or max_val.lower() == "unknown":
        return True
    if not style_val or style_val.lower() in ("none", "unknown"):
        return True
    return False


def enrich_csv_http(args) -> int:
    if requests is None:
        print("HTTP enrich requires: pip install requests", file=sys.stderr)
        return 1

    job = prepare_enrich_job(args)
    if job is None:
        return 1

    in_path = job["in_path"]
    out_path = job["out_path"]
    header = job["header"]
    data = job["data"]
    idx = job["idx"]
    max_i = job["max_i"]
    style_i = job["style_i"]
    targets = job["targets"]

    if not targets:
        print("No rows need enrichment in the selected range.")
        write_csv_rows(out_path, header, data)
        print(f"Saved → {out_path.resolve()}")
        return 0

    delay = resolve_delay(args, "enrich_http")
    workers = max(1, args.workers)
    rate_limiter = RateLimiter(delay)
    throttle = ThrottleState()
    est_per_sec = workers / max(delay, 0.05)
    est_hours = len(targets) / est_per_sec / 3600

    probe_id = data[targets[0]][idx["player_id"]].strip()
    if probe_id:
        probe_status = probe_pesdb_http(probe_id)
        if probe_status == 429:
            print(
                "⚠️ PESDB is rate-limiting your IP right now (HTTP 429).\n"
                "   Stop (Ctrl+C), wait 30–60 minutes, then rerun with:\n"
                "   python scripts/pesdb_scrape.py --enrich pesdb_list.csv "
                "--output pesdb_full.csv --resume --workers 2 --delay 2\n"
                "   Continuing anyway — you should see pause messages below…",
                flush=True,
            )
        elif probe_status == 200:
            print(f"  probe OK (player {probe_id})", flush=True)
        elif probe_status:
            print(f"  probe returned HTTP {probe_status} for player {probe_id}", flush=True)

    print(
        f"Enriching {len(targets)} players (HTTP, {workers} workers, "
        f"{delay:.2f}s min interval) → ~{est_hours:.1f}h",
        flush=True,
    )
    print(f"  {in_path.name} → {out_path.name}", flush=True)

    lock = threading.Lock()
    enriched = 0
    failed = 0
    completed = 0
    started = time.monotonic()

    def enrich_row(row_i: int) -> tuple[int, str, str, str]:
        row = data[row_i]
        player_id = row[idx["player_id"]].strip()
        if not player_id:
            return row_i, player_id, "None", "Unknown"
        style, max_rating = fetch_player_detail_http(
            player_id, rate_limiter, throttle
        )
        return row_i, player_id, style, max_rating

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(enrich_row, row_i) for row_i in targets]
        for fut in as_completed(futures):
            row_i, player_id, playing_style, max_rating = fut.result()
            with lock:
                completed += 1
                if max_rating == "Unknown":
                    failed += 1
                else:
                    row = data[row_i]
                    while len(row) < len(header):
                        row.append("")
                    row[max_i] = max_rating
                    row[style_i] = playing_style
                    data[row_i] = row
                    enriched += 1

                should_save = (
                    completed == 1
                    or completed % args.checkpoint == 0
                    or completed == len(targets)
                )
                should_log = (
                    completed == 1
                    or completed % 10 == 0
                    or completed == len(targets)
                )
                if should_save:
                    write_csv_rows(out_path, header, data)
                if should_log:
                    elapsed = time.monotonic() - started
                    rate = completed / elapsed if elapsed > 0 else 0
                    print(
                        f"  {completed}/{len(targets)} "
                        f"({enriched} ok, {failed} failed, {rate:.2f}/s)",
                        flush=True,
                    )

    write_csv_rows(out_path, header, data)
    elapsed = time.monotonic() - started
    print(
        f"Enriched {enriched} players ({failed} failed) in {elapsed / 60:.1f} min "
        f"→ {out_path.resolve()}"
    )
    if failed:
        print("Retry failed rows:")
        print(
            f"  python scripts/pesdb_scrape.py --enrich {in_path.name} "
            f"--output {out_path.name} --resume"
        )
    return 0


def enrich_csv_browser(args) -> int:
    job = prepare_enrich_job(args)
    if job is None:
        return 1

    in_path = job["in_path"]
    out_path = job["out_path"]
    header = job["header"]
    data = job["data"]
    idx = job["idx"]
    max_i = job["max_i"]
    style_i = job["style_i"]
    targets = job["targets"]

    if not targets:
        print("No rows need enrichment in the selected range.")
        write_csv_rows(out_path, header, data)
        print(f"Saved → {out_path.resolve()}")
        return 0

    delay = resolve_delay(args, "enrich_browser")
    print(f"Enriching {len(targets)} players (browser) from {in_path.name} → {out_path.name}")
    if args.no_headless:
        print("Tip: omit --no-headless for long enrich runs (Chrome window often closes/crashes).")

    session = DriverSession(headless=not args.no_headless)
    enriched = 0
    failed = 0
    try:
        for n, row_i in enumerate(targets, start=1):
            row = data[row_i]
            while len(row) < len(header):
                row.append("")
            player_id = row[idx["player_id"]].strip()
            if not player_id:
                continue

            if enriched > 0 and enriched % args.session_size == 0:
                print(f"⏸ Session limit ({args.session_size}) — cooling down {args.cooldown:.0f}s…")
                session.restart("scheduled session refresh")
                time.sleep(args.cooldown)

            print(f"  [{n}/{len(targets)}] {player_id}")
            playing_style, max_rating = get_player_details(session, player_id, delay)
            if max_rating == "Unknown":
                failed += 1
                print("     left unchanged — rerun with --resume to retry failed rows")
                time.sleep(delay)
                continue

            row[max_i] = max_rating
            row[style_i] = playing_style
            data[row_i] = row
            enriched += 1

            if enriched % args.checkpoint == 0:
                write_csv_rows(out_path, header, data)
                print(f"   checkpoint saved ({enriched} enriched, {failed} failed this run)")

            time.sleep(delay)
    finally:
        session.close()

    write_csv_rows(out_path, header, data)
    print(f"Enriched {enriched} players ({failed} failed) → {out_path.resolve()}")
    if failed:
        print("Retry failed rows:")
        print(
            f"  python scripts/pesdb_scrape.py --enrich {in_path.name} "
            f"--output {out_path.name} --resume --browser --delay {delay}"
        )
    return 0


def enrich_csv(args) -> int:
    if args.browser:
        return enrich_csv_browser(args)
    return enrich_csv_http(args)


def make_driver(headless: bool) -> webdriver.Chrome:
    options = Options()
    if headless:
        options.add_argument("--headless=new")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1920,1080")
    options.add_argument("--disable-blink-features=AutomationControlled")
    # Quiet Chrome stderr noise (e.g. GCM DEPRECATED_ENDPOINT) — not scrape errors.
    options.add_argument("--log-level=3")
    options.add_argument("--disable-background-networking")
    options.add_argument("--disable-sync")
    options.add_argument("--disable-default-apps")
    options.add_experimental_option("excludeSwitches", ["enable-automation", "enable-logging"])
    options.add_experimental_option("useAutomationExtension", False)
    options.add_argument(
        "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
    service = ChromeService(
        ChromeDriverManager().install(),
        log_output=subprocess.DEVNULL,
    )
    driver = webdriver.Chrome(service=service, options=options)
    driver.execute_script(
        "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
    )
    return driver


def main() -> int:
    parser = argparse.ArgumentParser(description="Scrape pesdb.net for GPSL GPDB sync")
    parser.add_argument("--start", type=int, default=1, help="First page (default 1)")
    parser.add_argument("--end", type=int, default=0, help="Last page (0 = auto-detect)")
    parser.add_argument("--output", type=str, default="", help="Output CSV path")
    parser.add_argument(
        "--delay",
        type=float,
        default=None,
        help="Seconds between requests (enrich HTTP default 1.0; browser 2.5; list detail 1.5)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help="Parallel HTTP workers for --enrich (default 3; use 2 if you see 429s)",
    )
    parser.add_argument(
        "--browser",
        action="store_true",
        help="Use Selenium for --enrich instead of fast HTTP (slow; use if HTTP is blocked)",
    )
    parser.add_argument("--list-delay", type=float, default=3.0, help="Seconds to wait for list page load")
    parser.add_argument("--page-delay", type=float, default=8.0, help="Pause between list pages")
    parser.add_argument("--page-retries", type=int, default=4, help="Retries when list page has no players table")
    parser.add_argument("--retry-wait", type=float, default=30.0, help="Base seconds between page retries")
    parser.add_argument(
        "--list-only",
        action="store_true",
        help="List pages only (no per-player detail visits) — avoids the ~2-page throttle",
    )
    parser.add_argument(
        "--enrich",
        type=str,
        default="",
        help="Enrich an existing list-only CSV with max_level_rating + playing_style",
    )
    parser.add_argument(
        "--enrich-start",
        type=int,
        default=0,
        help="1-based data row to start enriching (0 = from first row)",
    )
    parser.add_argument(
        "--enrich-end",
        type=int,
        default=0,
        help="1-based data row to stop before (0 = through end)",
    )
    parser.add_argument(
        "--session-size",
        type=int,
        default=25,
        help="Detail fetches per browser session before cooldown (enrich mode)",
    )
    parser.add_argument(
        "--cooldown",
        type=float,
        default=90.0,
        help="Seconds between browser sessions (enrich mode)",
    )
    parser.add_argument(
        "--checkpoint",
        type=int,
        default=25,
        help="Save output every N enriched players (enrich mode)",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Continue from last saved page (.progress file next to --output)",
    )
    parser.add_argument("--no-headless", action="store_true", help="Show browser window (often avoids blocks)")
    args = parser.parse_args()

    if args.enrich:
        return enrich_csv(args)

    detail_delay = resolve_delay(args, "list")
    session = DriverSession(headless=not args.no_headless)
    data: list[list[str]] = []

    try:
        end_page = args.end or estimate_total_pages(session.driver, {})
        if args.end == 0:
            end_page = max(end_page, args.start)
        start_page = max(1, args.start)
        out_path = resolve_output_path(args.output, start_page, end_page)

        if args.resume and out_path.is_file():
            _, data = read_csv_rows(out_path)
            last_done = read_last_completed_page(out_path)
            if last_done >= start_page:
                start_page = last_done + 1
            print(f"Resume: {len(data)} players on disk, continuing from page {start_page}")

        if start_page > end_page:
            print("start page > end page", file=sys.stderr)
            return 1

        print(f"Output: {out_path.resolve()}")
        print(f"Scraping pages {start_page}–{end_page}" + (" (list only)" if args.list_only else ""))
        if args.no_headless:
            print("Tip: keep the Chrome window open, or omit --no-headless for headless mode.")

        for page in range(start_page, end_page + 1):
            if page > start_page:
                print(f"⏸ Pausing {args.page_delay:.0f}s before next list page…")
                time.sleep(args.page_delay)
            page_rows = scrape_list_page(
                session,
                page,
                {},
                args.list_delay,
                detail_delay,
                args.page_retries,
                args.retry_wait,
                list_only=args.list_only,
            )
            data.extend(page_rows)
            write_csv_rows(out_path, CSV_HEADER, data)
            write_last_completed_page(out_path, page)
            print(f"💾 Checkpoint: page {page} saved ({len(data)} players total)")
    finally:
        session.close()

    print(f"Saved {len(data)} players → {out_path.resolve()}")
    if args.list_only:
        print("Note: --list-only leaves playing_style as None and max_level_rating as list rating.")
        print("Run enrich for playstyles + true max ratings:")
        print(f"  python scripts/pesdb_scrape.py --enrich {out_path.name} --output pesdb_full.csv --resume")
    else:
        print("Upload this file in Admin → Season Break → Data tools → GPDB PESDB sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
