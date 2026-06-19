# Club kits — Colours of Football

## Admin (recommended)

**Admin → Club kits → Download latest kits (all clubs)**

- Reads COF page headers (`home kit 2025-2026`, `25-26`, etc.) to find the **latest season**
- Downloads only kits matching that season (not older ones)
- Saves to public Supabase Storage bucket `club-kits` + `club_kits` table

Deploy edge function `club-kits-cof-sync` with both files in `supabase/functions/club-kits-cof-sync/`.

Create a **public** storage bucket named `club-kits` in Supabase Dashboard.

## Local download into repo (GitHub Pages)

```bash
python scripts/fetch_club_kits.py
```

Writes `images/clubs_kits/{SHORT}_home.png` etc. Uses the same latest-season header logic.

## Manual slug overrides

`COF_CLUB_SLUG_OVERRIDES` / `COF_CLUB_PATH_OVERRIDES` in `club_kits_cof.js`.
