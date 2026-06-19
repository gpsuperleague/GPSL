# Club kits — Colours of Football

Kit graphics from [colours-of-football.com](https://www.colours-of-football.com/) (credit Mikhail Sipovich / COF).

## Download latest kits (same as stadiums)

From repo root — **no secrets needed** (reads anon key from `supabase_client.js`):

```bash
python scripts/fetch_club_kits.py
```

Options:

- `--dry-run` — print URLs only
- `--only ARS,LIV,MCI` — subset by `Clubs.ShortName`

Outputs:

- `images/clubs_kits/{ShortName}_home.png` (and `_away`, `_third`)
- `data/club_kits_cof.json` — cached COF URLs + season

**Latest season logic:** scans every COF page for the club, collects all kit images, then picks the **highest season code** per type (`_1_` home, `_2_` away, `_3_` third — e.g. `2526` = 2025–26).

Club Details uses these files automatically via default paths when `club_kits` DB rows are empty.

## Admin COF sync (URLs only)

**Admin → Club kits → Sync all clubs from COF** saves COF image URLs to the database (edge function `club-kits-cof-sync`). Use the Python script above if you want files in the repo.

## Manual COF slug overrides

If auto-match fails, add `ShortName: "cof_folder_slug"` to `COF_CLUB_SLUG_OVERRIDES` in `club_kits_cof.js` and re-run the fetch.
