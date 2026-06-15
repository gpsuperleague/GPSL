#!/usr/bin/env python3
"""
PESDB eFootball player scraper for GPSL GPDB sync.

Outputs CSV compatible with admin_gpdb_sync.html upload:
  player_id, Position, player_name, nationality, age, rating, max_level_rating, playing_style

Requirements:
  pip install selenium webdriver-manager beautifulsoup4 lxml

Usage:
  python scripts/pesdb_scrape.py
  python scripts/pesdb_scrape.py --start 1 --end 50 --output pesdb_full.csv

  # Recommended when PESDB throttles after ~2 list pages of details:
  python scripts/pesdb_scrape.py --list-only --start 1 --end 633 --output pesdb_list.csv
  # (writes to scrape_output/pesdb_list.csv — not committed to git)
  python scripts/pesdb_scrape.py --enrich pesdb_list.csv --output pesdb_full.csv --delay 2.5
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
import time
from pathlib import Path

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


def enrich_csv(args) -> int:
    in_path = Path(args.enrich)
    if not in_path.is_file():
        print(f"File not found: {in_path}", file=sys.stderr)
        return 1

    out_path = Path(args.output) if args.output else in_path
    if args.resume and out_path.is_file():
        header, data = read_csv_rows(out_path)
        print(f"Resume: loaded {len(data)} rows from {out_path.name}")
    else:
        header, data = read_csv_rows(in_path)
    idx = col_index(header)
    if "player_id" not in idx:
        print("CSV must include player_id / konami_id column", file=sys.stderr)
        return 1

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

    targets = [
        i for i, row in enumerate(data) if needs_enrichment(row, idx)
    ]
    if args.enrich_start > 0:
        targets = [i for i in targets if i >= args.enrich_start - 1]
    if args.enrich_end > 0:
        targets = [i for i in targets if i < args.enrich_end]

    if not targets:
        print("No rows need enrichment in the selected range.")
        write_csv_rows(out_path, header, data)
        print(f"Saved → {out_path.resolve()}")
        return 0

    print(f"Enriching {len(targets)} players from {in_path.name} → {out_path.name}")
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
            playing_style, max_rating = get_player_details(session, player_id, args.delay)
            if max_rating == "Unknown":
                failed += 1
                print(f"     left unchanged — rerun with --resume to retry failed rows")
                time.sleep(args.delay)
                continue

            row[max_i] = max_rating
            row[style_i] = playing_style
            data[row_i] = row
            enriched += 1

            if enriched % args.checkpoint == 0:
                write_csv_rows(out_path, header, data)
                print(f"   checkpoint saved ({enriched} enriched, {failed} failed this run)")

            time.sleep(args.delay)
    finally:
        session.close()

    write_csv_rows(out_path, header, data)
    print(f"Enriched {enriched} players ({failed} failed) → {out_path.resolve()}")
    if failed:
        print("Retry failed rows:")
        print(
            f"  python scripts/pesdb_scrape.py --enrich {in_path.name} "
            f"--output {out_path.name} --resume --delay {args.delay}"
        )
    return 0


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
    parser.add_argument("--delay", type=float, default=1.5, help="Seconds between player detail fetches")
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
                args.delay,
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
        print(f"  python scripts/pesdb_scrape.py --enrich {out_path.name} --output pesdb_full.csv --delay 2.5")
    else:
        print("Upload this file in Admin → Season Break → Data tools → GPDB PESDB sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
