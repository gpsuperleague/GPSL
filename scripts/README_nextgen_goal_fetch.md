# Next Gen Youth — Goal NXGN fetch

## What you need

| Step | Where | What |
|------|--------|------|
| 1 | **Supabase SQL Editor** | Run `supabase/sql/patches/nextgen_youth_mv_boost.sql` (and `nextgen_youth_source_url.sql` if you already ran an older boost patch) |
| 2 | **GitHub / site** | Push `admin_nextgen_youth.html` / `.js` |
| 3 | **Supabase Edge Functions** | Deploy `nextgen-goal-fetch` (below) |

GitHub alone does **not** deploy the edge function. The browser cannot load Goal.com directly (CORS), so this function fetches the article server-side.

---

## Deploy edge function

### Option A — Supabase Dashboard (easiest)

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → your GPSL project → **Edge Functions**
2. **Create a new function** → name exactly: `nextgen-goal-fetch`
3. **Delete** any placeholder code in the editor
4. Open `supabase/functions/nextgen-goal-fetch/index.ts` in this repo, copy **all** of it, paste into the Dashboard editor
5. Also create/upload the shared helper if the Dashboard asks for imports: `_shared/gpsl_staff.ts` (same folder pattern as other functions). If paste-only Dashboard deploy fails on the import, use Option B (CLI) instead — CLI bundles `_shared` automatically.
6. **Deploy**
7. Function **Settings** → turn **OFF** “Enforce JWT verification” (same as `--no-verify-jwt`; the function still checks admin auth itself)

### Option B — Supabase CLI (PowerShell)

Run in **PowerShell** from the repo root (not in the Dashboard code editor):

```powershell
cd "d:\GPSL_Cursor"
supabase login
supabase link --project-ref omyyogfumrjoaweuawjn
supabase functions deploy nextgen-goal-fetch --no-verify-jwt
```

Install CLI if needed: https://supabase.com/docs/guides/cli

---

## Use in admin

**Admin → Next Gen Youth**

1. Paste the Goal NXGN list URL (update when Goal publishes a new year)
2. **Save URL** (optional — Fetch also saves)
3. **Fetch list → Konami IDs**
4. For any **Missing** rows, type a name → **Search** → click the GPDB player to attach
5. **Refresh Next Gen list**
