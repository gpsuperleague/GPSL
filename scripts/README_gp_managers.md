# Manager data for GPSL

**Full step-by-step guide:** [`docs/efootball-managers-extract.md`](../docs/efootball-managers-extract.md)

## Download tip (Kazemario / PESDatabase)

The [Kazemario PESDatabase post](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) often sends you to **Ko-fi**, not a ZIP. Use the guide’s **Path A** instead:

- **[ejogc327 editor](https://ejogc327.blogspot.com/2022/10/pes-2020-editor-v0-12.html)** or **[TAUVIC99 mirror](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html)** → unpack `Coach.bin` → export CSV  
- Or browse **[eFHUB coaches](https://www.efootballhub.net/efootball23/search/coaches)** (no bulk export)

```bash
node scripts/filter_gp_managers.js      # small community JSON only
```
