from pathlib import Path
import re

html = Path("all_listings.html").read_text(encoding="utf-8")
js = Path("all_listings.js").read_text(encoding="utf-8")
draft_html = Path("draftauction.html").read_text(encoding="utf-8")
draft_js = Path("draft_auction_filters.js").read_text(encoding="utf-8")

print("all_listings html ids:", re.findall(r'id="listings[^"]*"', html)[:10])
print("all_listings js listings*:", sorted(set(re.findall(r'listings[A-Za-z]+', js)))[:20])
print("html panel class:", re.findall(r'class="(multi-filter-[a-z]+)"', html)[:10])
print("js panel query:", re.findall(r'querySelector\("\.(multi-filter-[a-z]+)"\)', js)[:10])
print("draft html panel:", re.findall(r'class="(multi-filter-[a-z]+)"', draft_html)[:10])
print("draft js panel:", re.findall(r'querySelector\("\.(multi-filter-[a-z]+)"\)', draft_js)[:10])
