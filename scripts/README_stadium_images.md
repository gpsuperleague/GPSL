# Stadium photos (StadiumDB)

## Fetch images

From repo root:

```bash
node scripts/fetch_stadium_images.mjs
```

Options:

- `--dry-run` — print URLs only, no download
- `--only LIV,FEY,URD` — subset by `Clubs.ShortName`

Outputs:

- `images/stadiums/{ShortName}.jpg`
- `data/stadium_stadiumdb.json` — cached page + image URLs

## UI

`stadium.html` shows the image at ~35% opacity over the venue panel.

## Admin UI (edge function)

Nav: **Admin → Season Break → Club Management → Download Club Stadiums**
(`admin_club_stadiums.html`).

This calls Supabase Edge Function `club-stadiums-sync`, which fetches from StadiumDB and commits `images/stadiums/{SHORT}.jpg` to GitHub (same `GITHUB_TOKEN` pattern as club kits).

### Deploy

1. Re-bundle if you edited helpers/handler: `python scripts/bundle_club_stadiums_edge.py`
2. Supabase Dashboard → **Edge Functions** → create/update `club-stadiums-sync`
3. Paste all of `supabase/functions/club-stadiums-sync/index.ts`
4. Turn **OFF** “Enforce JWT verification” (admin check still runs inside the function)
5. Secrets: `GITHUB_TOKEN` (Contents: Read and write on `gpsuperleague/GPSL`) — reuse the kits secret

Shared lookup logic lives in `stadium_stadiumdb.js` (bundled into the edge `index.ts`).

## Rights

Photos are © their credited photographers on [StadiumDB](https://stadiumdb.com/). Use for league UI reference; replace with licensed assets if you publish commercially.

## Fixing a missing club

If the club’s **Nation** has no StadiumDB country code in `NATION_TO_CODE` (e.g. Morocco → `mar`), add that first or the admin tool will always report “no StadiumDB page”.

1. Find the page on stadiumdb.com (e.g. England list links use slugs like `anfield_road`, not `anfield`).
2. Add to `SLUG_OVERRIDES` in `stadium_stadiumdb.js` (and re-bundle the edge function):

   ```js
   LIV: "eng/anfield_road",
   ```

3. If the page has pictures but the scraper misses them, add a direct image to `IMAGE_URL_OVERRIDES` in the same file:

   ```js
   AJX: "https://stadiumdb.com/pictures/stadiums/ned/arena/arena41.jpg",
   ```

4. Re-run locally with `--only LIV`, or use **Download selected club** on the admin page.
