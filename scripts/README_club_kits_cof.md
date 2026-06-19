# Club kits — Colours of Football sync

Kit graphics from [colours-of-football.com](https://www.colours-of-football.com/) (credit Mikhail Sipovich / COF).

## Admin UI

**Admin → Club kits → Sync all clubs from COF**

- Looks up each GPSL club on COF by `Clubs.Nation` + `Clubs.Club` name
- Picks the **latest season** home (`_1_`), away (`_2_`), and third (`_3_`) kit PNGs
- Saves full COF image URLs into `club_kits` (shown on **Club Details**)

## Edge function deploy

1. Run `supabase/sql/patches/club_kits.sql` if not already applied
2. In Supabase Dashboard → **Edge Functions** → create `club-kits-cof-sync`
3. Deploy both files from `supabase/functions/club-kits-cof-sync/`:
   - `index.ts`
   - `club_kits_cof.js` (helper module — required)

Optional **Supabase Storage** download:

1. Create public bucket `club-kits`
2. Tick **Download to Supabase Storage** in admin before sync
3. Images are stored as `{SHORT}/home.png` etc. and public URLs are saved to the DB

## Local download into the repo

To commit kit files under `images/clubs_kits/` (GitHub Pages static hosting):

```bash
node scripts/sync_club_kits_from_cof.mjs
```

Requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the environment (or `.env` loaded by you).

## Manual COF slug overrides

If auto-match fails for a club, add an entry to `COF_CLUB_SLUG_OVERRIDES` in `club_kits_cof.js` (COF folder slug under the nation directory, e.g. `a_villa` for Aston Villa).
