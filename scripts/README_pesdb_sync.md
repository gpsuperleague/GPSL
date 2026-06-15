# PESDB scrape → GPDB sync

## What you need (3 separate steps)

| Step | Where | What |
|------|--------|------|
| 1 | **Supabase SQL Editor** | Run `supabase/sql/patches/gpdb_pesdb_sync.sql` |
| 2 | **GitHub** | Push site files (`admin_gpdb_sync.html`, etc.) |
| 3 | **Supabase Edge Functions** | Deploy `gpdb-pesdb-scrape` (see below) |

GitHub alone does **not** deploy the edge function.

---

## Deploy edge function

### Option A — Supabase Dashboard (easiest)

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → your project → **Edge Functions**
2. **Create new function** → name exactly: `gpdb-pesdb-scrape`
3. **Delete** any placeholder code in the editor
4. Copy **all** of `supabase/functions/gpdb-pesdb-scrape/index.ts` from this repo and paste it in
5. **Do not** paste terminal commands (`supabase login`, etc.) into the editor — that causes parse errors
6. Deploy the function
7. Open function **Settings** → turn **OFF** “Enforce JWT verification” (same as `--no-verify-jwt`)

### Option B — Supabase CLI (PowerShell / terminal)

Run these in **PowerShell**, not in the Dashboard code editor:

```powershell
cd "e:\OneDrive\GPSL\Local Github\GPSL"
supabase login
supabase link --project-ref omyyogfumrjoaweuawjn
supabase functions deploy gpdb-pesdb-scrape --no-verify-jwt
```

Install CLI first if needed: https://supabase.com/docs/guides/cli

---

## Use in admin

**Admin → Season Break → Data tools → GPDB PESDB sync**

1. **Detect pages**
2. Set range (test **1–3** first)
3. **Start scrape → staging**
4. **Preview** → **Apply**

Full scrape can take 30–60+ minutes.

---

## Fallback: CSV without edge function

If you skip the edge function:

```bash
pip install selenium webdriver-manager beautifulsoup4 lxml
python scripts/pesdb_scrape.py --output pesdb_full.csv
```

### Recommended workflow (PESDB throttles after ~60 detail pages)

PESDB often allows **~2 list pages** when each player triggers a detail visit (~60 requests), then list pages return empty. Use **two steps**:

**Step 1 — list only** (one request per page; can run hundreds of pages):

```bash
python scripts/pesdb_scrape.py --list-only --start 1 --end 633 --output pesdb_list.csv --page-delay 3
```

Use **headless** (default) for long runs — `--no-headless` is fine for debugging but don’t close the Chrome window. If the browser crashes, resume:

```bash
python scripts/pesdb_scrape.py --list-only --start 1 --end 633 --output pesdb_list.csv --resume --page-delay 3
```

**Step 2 — enrich details** (restarts browser every 40 players with a 90s cooldown):

```bash
python scripts/pesdb_scrape.py --enrich pesdb_list.csv --output pesdb_full.csv --no-headless --delay 2.5
```

Resume enrich in ranges if needed:

```bash
python scripts/pesdb_scrape.py --enrich pesdb_list.csv --output pesdb_full.csv --enrich-start 1 --enrich-end 500 --delay 2.5
python scripts/pesdb_scrape.py --enrich pesdb_full.csv --output pesdb_full.csv --enrich-start 501 --delay 2.5
```

Upload `pesdb_full.csv` in admin. List-only CSV also works (max rating falls back to list rating).

### Chrome stderr: `DEPRECATED_ENDPOINT` / GCM errors

Harmless noise from Chrome’s background services — **not** PESDB blocking you. The script suppresses most of it. If a line still appears, ignore it unless you also see `No players table` or scrape failures.

### If you see “No table on page N”

Page 3+ often fails **after** pages 1–2 because PESDB throttles automated traffic (~60 player-detail requests). Your browser still works; Selenium may get an empty or blocked response.

1. **Resume** the failed chunk after a cooldown:
   ```bash
   python scripts/pesdb_scrape.py --start 3 --end 50 --output pesdb_3-50.csv --no-headless --delay 2.5 --page-delay 15
   ```
2. Check `pesdb_debug_page3.html` in the repo folder (saved on failure).
3. Slow down: `--no-headless`, `--delay 2.5`, `--page-delay 15`, `--list-delay 5`
4. Merge chunk CSVs before admin upload (one header row).

Upload CSV on the same admin page. Preview/apply still work after the SQL patch.

---

## Legacy cards

Players off pesdb.net stay at club, not sellable, renew 1 season at a time.
