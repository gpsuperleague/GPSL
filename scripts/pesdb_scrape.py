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


def get_player_details(driver, player_id: str | None) -> tuple[str, str]:
    if not player_id:
        return "Unknown", "Unknown"
    try:
        url = f"{BASE_URL}?id={player_id}&mode=max_level"
        driver.get(url)
        time.sleep(1.2)
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


def scrape_list_page(driver, page: int, filters: dict, delay: float) -> list[list[str]]:
    url = build_url(page, filters)
    print(f"Page {page}: {url}")
    driver.get(url)
    time.sleep(delay)
    soup = BeautifulSoup(driver.page_source, "lxml")
    table = soup.find("table")
    if not table:
        print(f"  no table on page {page}")
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
        playing_style, max_rating = get_player_details(driver, player_id)
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
        time.sleep(delay)
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
    parser.add_argument("--delay", type=float, default=1.2, help="Seconds between player detail fetches")
    parser.add_argument("--no-headless", action="store_true", help="Show browser window")
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
            data.extend(scrape_list_page(driver, page, {}, args.delay))
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
