import re
import urllib.request

UA = "Mozilla/5.0 (compatible; GPSL-KitSync/1.0)"
page_url = "https://www.colours-of-football.com/colours03/eng/liverpool/liverpool_5.html"
html = urllib.request.urlopen(
    urllib.request.Request(page_url, headers={"User-Agent": UA}),
    timeout=30,
).read().decode("utf-8", errors="replace")
print("=== home 2025 headers ===")
for m in re.finditer(r"home\s+kit\s+2025[^\n<]{0,40}", html, re.I):
    print(m.group(0))
print("=== liverpool image files ===")
for m in re.finditer(r'src="([^"]+)"', html, re.I):
    f = m.group(1).split("/")[-1]
    if "liverpool" in f.lower() and f.endswith((".png", ".gif")):
        print(f)
