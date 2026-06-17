# Manager portraits

Manager draft auction bid pages show a portrait when you open a manager (`manager_draftauction_manager.html`).

## Image files

Place portraits at:

```
images/managers/{slug}.jpg
```

`{slug}` matches `Managers.slug` in the database (e.g. `maurizio-sarri`, `hansi-flick`).

`.png` is also tried if `.jpg` is missing.

**Important:** add the slug to `data/manager_portraits.json` (or run the sync script below).
The UI only requests images listed there — avoids 404 console noise when files are not deployed yet.

Until images are listed, the UI shows **initials** (e.g. **HF** for Hansi Flick).

## Sync manifest (after adding images)

```bash
node scripts/sync_manager_portraits_manifest.mjs
```

Regenerates `data/manager_portraits.json` from `images/managers/*.{jpg,png}`.
Commit both the images and the updated JSON.

## Fetch from eFootballHub (optional)

From repo root:

```bash
node scripts/fetch_manager_images.mjs --dry-run
node scripts/fetch_manager_images.mjs
node scripts/fetch_manager_images.mjs --only maurizio-sarri,jose-mourinho
node scripts/fetch_manager_images.mjs --force
```

- Reads manager list from `supabase/sql/patches/managers_seed_data.sql`
- Searches [eFootballHub coaches](https://www.efootballhub.net/efootball23/search/coaches) by name
- Saves `images/managers/{slug}.jpg`
- Updates `data/manager_portraits.json` automatically
- Caches resolved coach IDs in `data/manager_efhub_ids.json`

If auto-match fails for a name, add a manual override to `data/manager_efhub_ids.json`:

```json
{
  "m-allegri": "123"
}
```

Then re-run the script for that slug.

## Deploy

Commit `images/managers/*.jpg` and push to GitHub Pages like club badges.
