# Manager data for GPSL

There is **no official API** for managers. The full game database (~700+ coach entries) lives in binary files on disk; the **GP shop** is a smaller subset inside the live game UI.

## Full list (~732 coaches) from game files (PC)

### Where the data lives (Steam)

Typical install:

`Steam\steamapps\common\eFootball\`

Important archives (names from community patches / modding):

| File | Role |
|------|------|
| `dt200_console_all.cpk` | Main database archive (players, teams, **coaches**, etc.) |
| `pc7000_console_win.pak` / `.ucas` / `.utoc` | Newer UE-style game packages (harder to parse) |
| Unpacked `Coach.bin` (and related) | After CPK extract — this is what editors read |

The **732** figure matches what eFHUB / internal DB tools index: **every coach definition in the live database**, not only GP-purchasable managers.

### Practical extraction pipeline (modding community)

1. **Back up** the whole `eFootball` folder first.
2. **Unpack** `dt200_console_all.cpk` with [CRI File System Tools](https://github.com/sonic853/CriTools) or tools referenced on [EvoWeb](https://evoweb.uk/) / [pesnewupdate](https://pesnewupdate.com/).
3. Find **`Coach.bin`** (sometimes under a `common` / database path inside the CPK).
4. Open with a DB editor that understands eFootball bins:
   - [eFootball Player Data Editor (Devil Cold52)](https://pesnewupdate.com/efootball-player-data-editor/) — EvoWeb thread [88692](https://evoweb.uk/threads/88692/) (players first; check thread for coach support updates).
   - [PES 2020 Editor (ejogc327)](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html) — documents **Coach** import/export to **CSV** when you point it at extracted `.bin` files (`Coach.bin`, `Team.bin`, etc.).
   - [PESDatabase v0.1.0](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) — desktop search over **eFootball 2026** DB (easiest if it lists all coaches; check for export).
5. Export **CSV** from the editor, then filter in Excel or a small Node script.

**Caveats:**

- Formats change every yearly update; decoders are community-maintained, not from Konami.
- `EDIT00000000` (old PES save) only holds ~**231** manager slots — **not** the full 732.
- Playstyle proficiencies / link-up / boosters may sit in **additional** bins (tactics / coach ability tables), not only the classic 88-byte PES manager name block — eFHUB has already mapped these; raw CSV export may be names/IDs only unless the editor exposes proficiencies.
- Reverse-engineering local files may conflict with Konami’s terms; use for private league tooling, don’t redistribute Konami’s DB.

### Faster than writing a custom parser

| Option | Gets ~732? |
|--------|------------|
| **PESDatabase** desktop | Likely yes (built for eFootball 2026 DB) |
| **eFHUB app** internal DB | Yes (not export-friendly) |
| **ejogc327 CSV export** | Yes if `Coach.bin` decode matches your game version |
| **Custom scrape of pesdb** | Players yes; managers not on pesdb |

After export, filter GP-tier in code: `node scripts/filter_gp_managers.js` (all five playstyles ≤ 87).

---

# GP-tier managers (playstyle ≤ 87 on each style)

There is **no official downloadable “Standard Manager List”** from Konami. The live GP shop is only inside the game.

## Best places to browse / build a list

| Source | URL | Notes |
|--------|-----|--------|
| **eFHUB app** | App store: eFHUB / eFootballHub | Same data as site; Smart Search → set **max 87** on each playstyle |
| **eFootballHub web** | `https://www.efootballhub.net/efootball23/search/coaches` (or `/efootball26/…` when live) | Table of coaches + 5 playstyle numbers; use site filters |
| **eFootball World** | https://efootball-world.com/manager | ~60 managers, HTML (scrapeable) |
| **Open JSON** | https://github.com/amine250/efootball-managers/blob/main/data/managers.json | 58 managers; run local filter script |
| **F2P articles** | Game8, Operation Sports, Usstream | **Named GP standard managers + prices** (manual) |

## Known GP Standard managers (from community guides, not auto-scraped)

Often cited for **Manager List (GP)**:

- Luis A. Roman (~460k GP) — Pep-style
- Cristo Valbuena (~330k GP) — Simeone-style
- Thomas Tuchel, Simone Inzaghi, Thomas Gurpegui, Bart Chilton, Dino Millesi, M. Allegri, Giovam Ripa, Jarabe Laporta, Maurizio Sarri, Sotirio Tellini, etc.

Prices and roster **change**; verify in-game.

## Local filter (eFHUB rule)

```bash
node scripts/filter_gp_managers.js      # max 87 each playstyle
node scripts/filter_gp_managers.js 85   # stricter
```

This uses community `managers.json`, not the live GP shop.
