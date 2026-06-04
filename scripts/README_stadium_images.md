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

## Rights

Photos are © their credited photographers on [StadiumDB](https://stadiumdb.com/). Use for league UI reference; replace with licensed assets if you publish commercially.

## Fixing a missing club

1. Find the page on stadiumdb.com (e.g. England list links use slugs like `anfield_road`, not `anfield`).
2. Add to `SLUG_OVERRIDES` in `scripts/fetch_stadium_images.mjs`:

   ```js
   LIV: "eng/anfield_road",
   ```

3. If the page has pictures but the scraper misses them, add a direct image to `IMAGE_URL_OVERRIDES`:

   ```js
   AJX: "https://stadiumdb.com/pictures/stadiums/ned/arena/arena41.jpg",
   ```

4. Re-run with `--only LIV`.
