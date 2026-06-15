# PESDB scrape → GPDB sync

## Primary: in-GPSL admin scrape

1. Run SQL patch: `supabase/sql/patches/gpdb_pesdb_sync.sql`
2. **Deploy edge function** `gpdb-pesdb-scrape` in Supabase (Dashboard → Edge Functions, or CLI below)
3. Open **Admin → Season Break → Data tools → GPDB PESDB sync**
4. **Detect pages** → set range → **Start scrape → staging**
5. **Preview** → **Apply**

```bash
# From repo root (Supabase CLI logged in)
supabase functions deploy gpdb-pesdb-scrape --no-verify-jwt
```

The admin page calls the edge function page-by-page. Each page:
- Fetches the pesdb.net list HTML
- Fetches each player’s `?id=…&mode=max_level` page for max rating + playing style
- Computes economics in the browser
- Appends to `gpdb_pesdb_staging`

No Selenium required — pesdb.net serves server-rendered HTML.

**Tip:** Test with pages **1–3** first. A full scrape (~100+ pages) can take 30–60+ minutes; leave the tab open.

## Fallback: local Python scrape

If the edge function is unavailable or you prefer offline scraping:

```bash
pip install selenium webdriver-manager beautifulsoup4 lxml
python scripts/pesdb_scrape.py --output pesdb_full.csv
```

Upload the CSV on the same admin page (**Upload CSV → staging**).

## Deploy edge function

Function path: `supabase/functions/gpdb-pesdb-scrape/`

Requires env vars (set automatically in Supabase): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`.

Admin auth: caller must pass JWT; function checks `is_gpsl_admin()` RPC.

## What apply does

See main workflow in admin page. Legacy cards (`pesdb_unavailable`) stay at club, not sellable, 1-season renewals.
