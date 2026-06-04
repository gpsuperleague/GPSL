# Manager data for GPSL

**Full step-by-step guide (repeatable):** [`docs/efootball-managers-extract.md`](../docs/efootball-managers-extract.md)

There is **no official API** for managers. The full game database (~700+ coach entries) lives in binary files on disk; the **GP shop** is a smaller subset inside the live game UI.

## Quick summary

1. **PC Steam install** → `Steam\steamapps\common\eFootball\`
2. **Easiest:** [PESDatabase](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) pointed at game folder → export coaches (~732).
3. **Manual:** Unpack `dt200_console_all.cpk` → `Coach.bin` → [ejogc327](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html) or Devil Cold52 editor → CSV.
4. **Filter GP-tier:** all five playstyles ≤ 87 — `node scripts/filter_gp_managers.js` (only works on small community JSON until you wire your CSV).

See the doc for backup steps, repeat checklist, troubleshooting, and GPSL `data/` filenames.

---

## Best places to browse (without extracting files)

| Source | URL | Notes |
|--------|-----|--------|
| **eFHUB app** | App store: eFHUB / eFootballHub | Smart Search → max **87** on each playstyle |
| **eFootballHub web** | `https://www.efootballhub.net/efootball23/search/coaches` | Table + filters |
| **eFootball World** | https://efootball-world.com/manager | ~60 managers |
| **Open JSON** | https://github.com/amine250/efootball-managers | ~58 managers |

## Local filter (community JSON only)

```bash
node scripts/filter_gp_managers.js
node scripts/filter_gp_managers.js 85
```
