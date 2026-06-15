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
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import time
from pathlib import Path

from bs4 import BeautifulSoup
from selenium import webdriver
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
    path = Path(f"pesdb_debug_page{page}.html")
    path.write_text(html, encoding="utf-8")
    return path


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


def parse_playing_style(page_text: str, soup: BeautifulSoup) -> str:
    for table in soup.find_all("table"):
        for row in table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            for i, cell in enumerate(cells):
                if "playing style" in cell.get_text(strip=True).lower() and i + 1 < len(cells):
                    style_text = cells[i + 1].get_text(strip=True)
                    for style in PLAYING_STYLES:
                        if style == style_text:
                            return style
    for style in PLAYING_STYLES:
        if f"Playing Style: {style}" in page_text or f"playing style: {style}" in page_text:
            return style
    return "None"


def get_player_details(driver, player_id: str | None, delay: float) -> tuple[str, str]:
    if not player_id:
        return "Unknown", "Unknown"
    try:
        url = f"{BASE_URL}?id={player_id}&mode=max_level"
        driver.get(url)
        time.sleep(delay)
        soup = BeautifulSoup(driver.page_source, "lxml")
        page_text = soup.get_text()
        return parse_playing_style(page_text, soup), parse_max_rating(page_text, soup)
    except Exception as exc:
        print(f"     warn: player {player_id}: {exc}", file=sys.stderr)
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
    driver,
    page: int,
    filters: dict,
    list_delay: float,
    detail_delay: float,
    page_retries: int,
    retry_wait: float,
) -> list[list[str]]:
    url = build_url(page, filters)
    print(f"📄 Scraping page {page}")
    print(f"🔗 URL: {url}")

    html = ""
    soup = None
    table = None

    for attempt in range(1, page_retries + 1):
        driver.get(url)
        loaded = wait_for_players_table(driver, list_delay + 2.0)
        if not loaded:
            time.sleep(max(1.0, list_delay))
        html = driver.page_source
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
        playing_style, max_rating = get_player_details(driver, player_id, detail_delay)
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
        time.sleep(detail_delay)
    return out


def make_driver(headless: bool) -> webdriver.Chrome:
    options = Options()
    if headless:
        options.add_argument("--headless=new")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1920,1080")
    options.add_argument("--disable-blink-features=AutomationControlled")
    options.add_experimental_option("excludeSwitches", ["enable-automation"])
    options.add_experimental_option("useAutomationExtension", False)
    options.add_argument(
        "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
    driver = webdriver.Chrome(
        service=ChromeService(ChromeDriverManager().install()),
        options=options,
    )
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
    parser.add_argument("--no-headless", action="store_true", help="Show browser window (often avoids blocks)")
    args = parser.parse_args()

    driver = make_driver(headless=not args.no_headless)
    data: list[list[str]] = []

    try:
        end_page = args.end or estimate_total_pages(driver, {})
        if args.end == 0:
            end_page = max(end_page, args.start)
        start_page = max(1, args.start)
        if start_page > end_page:
            print("start page > end page", file=sys.stderr)
            return 1

        print(f"Scraping pages {start_page}–{end_page}")
        for page in range(start_page, end_page + 1):
            if page > start_page:
                print(f"⏸ Pausing {args.page_delay:.0f}s before next list page…")
                time.sleep(args.page_delay)
            data.extend(
                scrape_list_page(
                    driver,
                    page,
                    {},
                    args.list_delay,
                    args.delay,
                    args.page_retries,
                    args.retry_wait,
                )
            )
    finally:
        driver.quit()

    out_path = Path(args.output) if args.output else Path(
        f"pesdb_scrape_pages{args.start}-{end_page or args.start}.csv"
    )
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(CSV_HEADER)
        writer.writerows(data)

    print(f"Saved {len(data)} players → {out_path.resolve()}")
    print("Upload this file in Admin → Season Break → Data tools → GPDB PESDB sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
