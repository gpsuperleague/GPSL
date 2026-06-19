# Club kits — Colours of Football

## What you need

| Step | Where | What |
|------|--------|------|
| 1 | **Supabase SQL Editor** | Run `supabase/sql/patches/club_kits.sql` |
| 2 | **GitHub** | Push site files (`admin_club_kits.html`, etc.) |
| 3 | **Supabase Edge Functions** | Deploy `club-kits-cof-sync` (see below) |
| 4 | **Supabase Storage** (optional) | Public bucket `club-kits` for downloaded PNGs |

GitHub alone does **not** deploy the edge function.

---

## Deploy edge function (Dashboard — easiest)

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → your project → **Edge Functions**
2. **Create new function** → name exactly: `club-kits-cof-sync`
3. Delete placeholder code
4. Copy **all** of `supabase/functions/club-kits-cof-sync/index.ts` and paste (single self-contained file)
5. **Deploy**
6. Function **Settings** → turn **OFF** “Enforce JWT verification” (same as `gpdb-pesdb-scrape`)

After editing `club_kits_cof.js`, re-bundle before redeploy:

```bash
python scripts/bundle_club_kits_edge.py
```

Then paste the updated `index.ts` again.

### CLI (optional)

```powershell
cd D:\GPSL_Cursor
supabase login
supabase link --project-ref omyyogfumrjoaweuawjn
supabase functions deploy club-kits-cof-sync --no-verify-jwt
```

---

## Admin UI

**Admin → Season Break → Club kits → Download latest kits**

- Reads COF headers (`home kit 2025-2026`, `25-26`, etc.) for the **latest season only**
- **Download latest kits** — optional Storage upload + `club_kits` table
- **Save COF links only** — no Storage bucket required

---

## Without edge function (local)

```bash
python scripts/fetch_club_kits.py
```

Writes `images/clubs_kits/{SHORT}_home.png` etc. Commit to GitHub for static hosting.

---

## Manual COF slug overrides

`COF_CLUB_SLUG_OVERRIDES` / `COF_CLUB_PATH_OVERRIDES` in `club_kits_cof.js`, then re-bundle edge function.
