import re
import urllib.request

UA = "Mozilla/5.0 (compatible; GPSL-KitSync/1.0)"
BASE = "https://www.colours-of-football.com/colours03/eng"

index = urllib.request.urlopen(
    urllib.request.Request(f"{BASE}/eng.html", headers={"User-Agent": UA}),
    timeout=30,
).read().decode("utf-8", errors="replace")

for m in re.finditer(
    r'<a[^>]+href="([^"#?]+/[^"#?]+_\d+\.html)"[^>]*>([\s\S]*?)</a>',
    index,
    re.I,
):
    href = m.group(1)
    inner = m.group(2)
    if "liver" not in inner.lower() and "liver" not in href.lower():
        continue
    alt = re.search(r'alt="([^"]+)"', inner, re.I)
    name = re.sub(r"<[^>]+>", " ", alt.group(1) if alt else inner)
    print("INDEX", href, name.strip())

for page in range(1, 6):
    page_url = f"{BASE}/liverpool/liverpool_{page}.html"
    try:
        html = urllib.request.urlopen(
            urllib.request.Request(page_url, headers={"User-Agent": UA}),
            timeout=30,
        ).read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"page {page}: {e}")
        break
    print(f"\n=== PAGE {page} ===")
    hdrs = []
    for m in re.finditer(
        r"(?:home|away|third)\s+kit\s+(\d{4})\s*[-–/]\s*(\d{2,4})",
        html,
        re.I,
    ):
        hdrs.append(m.group(0))
    for m in re.finditer(
        r"(?:home|away|third)\s+kit\s+(\d{2})\s*[-–/]\s*(\d{2})",
        html,
        re.I,
    ):
        hdrs.append(m.group(0))
    print("headers tail:", hdrs[-6:] if hdrs else "none")
    files = []
    for m in re.finditer(r'src="([^"]+\.(?:png|gif))"', html, re.I):
        f = m.group(1).split("/")[-1]
        if "liverpool" in f.lower() and f not in ("liverpool.gif",):
            files.append(f)
    print("kit files tail:", files[-8:] if files else "none")

