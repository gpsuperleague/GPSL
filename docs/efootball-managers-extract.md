# eFootball managers — extract from game files (repeatable guide)

Use this when you need the **full coach database** (~700–732 entries) or a **CSV you can filter** for GPSL (e.g. playstyle proficiencies ≤ 87 on each style).

There is **no official Konami export**. This workflow uses your **local PC install** and community tools. Formats change after major patches—re-run when you update the game.

---

## What you are extracting

| Dataset | Count (typical) | Where it lives |
|---------|-----------------|----------------|
| Full coach catalog in live DB | ~732 | `Coach.bin` inside `dt200_console_all.cpk` (and related bins) |
| GP “Standard Manager List” (in-game shop) | Smaller subset | Game UI only; not a separate public file |
| Old PES `EDIT00000000` managers | ~231 | Save file — **not** the full 732 |

**732** = every coach **definition** in the current game database (packs, events, duplicates by ID, etc.), same class of data eFHUB indexes.

---

## Before you start (every time)

1. **Note your game version** (Steam → eFootball → Properties or in-game title screen). Write it in your export filename, e.g. `managers_2026-06-02_v3.5.csv`.
2. **Back up** the install folder (copy, do not move):
   - Default: `C:\Program Files (x86)\Steam\steamapps\common\eFootball\`
   - Or your Steam library path + `\steamapps\common\eFootball\`
3. **Do not** edit files inside the live game folder unless you know how to restore from backup. Prefer **copy** `Coach.bin` or the whole unpacked folder to a working directory like `D:\efootball-export\`.
4. **Legal / use:** For private GPSL tooling only. Do not redistribute Konami’s raw database or ship extracted bins in the GPSL repo.

---

## Downloads — what actually works (read this first)

### Kazemario “PESDatabase” → Ko-fi only

The [Kazemario release post](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) is a **blog mirror**, not the host. The big download button often sends you to **Ko-fi** (tip/support) or an ad layer, **not** a ZIP. That is normal for those sites — it is not your mistake.

**Do not rely on Kazemario as your only download.** Use one of the paths below.

| Tool | Download page (usually real file) | Coach / ~732 CSV? |
|------|-----------------------------------|-------------------|
| **PES 2020 Editor (ejogc327)** | [Author blog V0.12](https://ejogc327.blogspot.com/2022/10/pes-2020-editor-v0-12.html) · [TAUVIC99 mirror](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html) | **Coach → CSV** if bins decode |
| **eFootball Player Data Editor** | [PESNewupdate](https://pesnewupdate.com/efootball-player-data-editor/) (“DOWNLOAD HERE OR HERE”) · [EvoWeb #88692](https://evoweb.uk/threads/88692/) | Players mature; **check thread for coaches** |
| **PESDatabase (Kisni Lucky)** | Kazemario only — hunt creator file | Yes if you ever get the ZIP |
| **eFHUB web** | [Coaches search](https://www.efootballhub.net/efootball23/search/coaches) | Browse/filter, **no bulk CSV** |

**Recommended for GPSL:** **Path A** (unpack + ejogc327) or **Path C** (eFHUB) if you only need GP-tier names, not all 732 rows in a file.

---

## Path A — Recommended: unpack `Coach.bin` → CSV (ejogc327)

Works without Ko-fi. You unpack the game database once, then export coaches to CSV.

**Note:** ejogc327 was built for PES 2020/2021 `Dt*.cpk` layouts. Modern eFootball uses `dt200_console_all.cpk` — you still extract **`Coach.bin`** from there; if the editor errors, check [EvoWeb #88692](https://evoweb.uk/threads/88692/) for a newer eFootball-specific tool.

### A1. Download the editor (not Kazemario)

1. Open **[ejogc327 — PES 2020 Editor V0.12](https://ejogc327.blogspot.com/2022/10/pes-2020-editor-v0-12.html)** (official).
2. If the page has no visible link, use **[TAUVIC99 mirror](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html)** → **Link 1 = Download**.
3. Some versions ask for a **donation** on the author blog for full features; **Coach CSV export** has historically worked without that — if blocked, try an older **V0.11** post on the same blog (MEGA links on older posts).
4. Extract the ZIP to e.g. `D:\Tools\PES2020Editor\`.
5. Windows may flag mod tools — only download if you trust the source; scan the ZIP if unsure.

### A2. Locate the database archive

In your eFootball folder, find:

```
dt200_console_all.cpk
```

Also present (usually **not** needed for classic coach CSV):

```
pc7000_console_win.pak
pc7000_console_win.ucas
pc7000_console_win.utoc
```

### A3. Unpack the CPK

**Option 1 — CRI tools (common)**

1. Install or build [CriTools](https://github.com/sonic853/CriTools) (see repo README for Windows usage).
2. Extract `dt200_console_all.cpk` to a folder, e.g. `D:\efootball-export\cpk-unpacked\`.
3. Search the output for **`Coach.bin`** (File Explorer search).

**Option 2 — Community pack / EvoWeb**

1. Check [EvoWeb eFootball modding](https://evoweb.uk/) or [pesnewupdate](https://pesnewupdate.com/) for a “database extractor” or patch tool that matches **your** game year.
2. Follow that tool’s steps to get `.bin` files; still locate **`Coach.bin`**.

Write down the full path to `Coach.bin` (path inside CPK changes between updates).

### A4. Copy bins to a safe working folder

Example:

```
D:\efootball-export\work\
  Coach.bin
  Team.bin          (if the editor asks for related files)
  ...
```

Copy from unpack output—do not work directly in `Program Files\...\eFootball\` unless you accept restore-from-backup risk.

### A5. Export coaches with ejogc327

The editor needs **all** of these in the same folder (copy from unpack if missing):

`Player.bin`, `Coach.bin`, `PlayerAssignment.bin`, `Team.bin`, `Competition.bin`, `CompetitionEntry.bin`, `CompetitionRegulation.bin`, `Stadium.bin`, `Tactics.bin`, `TacticsFormation.bin`, `Ball.bin`, `Boots.bin`, `Gloves.bin`, and `PlayerAppearance.bin` (under `common\character0\model\character\appearance\` in the CPK).

Steps:

1. Run the editor.
2. **Open** your working folder (folder that contains `Coach.bin`, not the single file).
3. Open the **Coach** table.
4. **Export → CSV** (all coaches).
5. Save as `data/managers_raw_YYYY-MM-DD.csv`.

### A6. Verify the export

Open the CSV and check:

- Row count ≈ **700+** (target ~732 for current live DB).
- Columns include at least **name** and/or **ID** (column names depend on the editor).
- If playstyle columns are **missing**, proficiencies may live in other bins—the editor may not decode them yet. Use eFHUB (max 87 per style) to validate GP-tier names, or wait for a tool update.

---

## Path B — Optional: PESDatabase via Kazemario

Only try this if you obtain a real **ZIP** (8 MB, “PESDatabase v0.1.0”), not a Ko-fi page.

1. [Kazemario post](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) — scroll the whole article; some posts hide a second **MediaFire / MEGA** button below ads.
2. Search **EvoWeb** or mod Discord for **“PESDatabase Kisni Lucky”** — creator may post a direct host.
3. If the only button is **Ko-fi**, stop and use **Path A** or **Path C**.

If you do get the ZIP:

1. Extract to `D:\Tools\PESDatabase\`.
2. Point it at your `eFootball` Steam folder.
3. Open coaches → export if the UI allows.

---

## Path C — No unpack: eFHUB browse (GP-tier, no full CSV)

When downloads are blocked or you only need **filterable** manager stats:

1. Open [eFootballHub coaches](https://www.efootballhub.net/efootball23/search/coaches) (use `/efootball26/…` when that path exists for your season).
2. Use filters / Smart Search: set **max 87** on each playstyle (GPSL GP-tier rule).
3. Manually build a spreadsheet, or use the site to verify names from a partial game export.

There is **no official “export all 732”** button on eFHUB.

---

## Path D — No game files: community JSON (small sample only)

**Not** for the full 732 list.

```bash
node scripts/filter_gp_managers.js
node scripts/filter_gp_managers.js 85
```

Uses ~58 managers from [amine250/efootball-managers](https://github.com/amine250/efootball-managers). Good for testing filters, not production GPSL data.

---

## After export — GPSL workflow

### 1. Store the raw export (versioned)

Suggested repo layout (add to `.gitignore` if the file is huge or you do not want Konami-derived data in git):

```
data/
  managers_efootball_2026-06-02.csv    # full export
  managers_gp_tier.csv                 # filtered for GPSL rules
```

### 2. Filter GP-tier (eFHUB rule: max 87 each playstyle)

If your CSV has five playstyle columns matching eFHUB names, filter in Excel:

- Keep rows where **Possession, Quick Counter, Long Ball Counter, Out Wide, Long Ball** are all **≤ 87**.

Or adapt `scripts/filter_gp_managers.js` to read your local CSV instead of the GitHub JSON.

### 3. Optional columns for GPSL

| Column | Source |
|--------|--------|
| `name` | CSV / game |
| `coach_id` | CSV / game |
| `gp_price` | In-game Standard Manager List only — manual or community articles |
| `possession`, `quick_counter`, … | CSV if editor exposes them; else eFHUB |
| `game_version` | Your note from “Before you start” |
| `exported_at` | Date |

### 4. GP shop list (separate pass)

The **Standard Manager List** prices are not always in `Coach.bin`. Options:

- Export from in-game Manager List (screenshots → spreadsheet), or  
- Community lists (Game8, Operation Sports, etc.) — verify in-game after each GP rotation.

---

## Repeat checklist (next season / after patch)

Copy this block into your notes each time:

```
[ ] Record game version: _______________
[ ] Backup eFootball folder
[ ] Download editor: ejogc327 (tauvic99 mirror if author page has no link)
    — Skip Kazemario unless you have a real ZIP, not Ko-fi
[ ] Unpack dt200_console_all.cpk → find Coach.bin → copy full bin set → ejogc327 CSV
    OR
[ ] Path C only: eFHUB filters → manual spreadsheet for GP-tier
[ ] Row count ~700+? Actual: _______
[ ] Save: data/managers_efootball_YYYY-MM-DD.csv
[ ] Filter playstyle ≤87 → managers_gp_tier.csv
[ ] Spot-check 5 names against eFHUB / in-game GP list
[ ] Update GPSL import only if league rules require new file
```

---

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| Kazemario download → Ko-fi only | Expected; use **Path A** (ejogc327) or **Path C** (eFHUB) |
| Editor crashes or empty Coach table | Game updated; get newer editor build from EvoWeb/pesnewupdate |
| Cannot find `Coach.bin` | Re-unpack latest `dt200_console_all.cpk`; search entire unpack tree |
| CSV has ~200 rows | Wrong bin or old PES EDIT workflow — not full live DB |
| CSV has names but no playstyles | Use eFHUB for proficiency filter; or find updated editor |
| Steam install on another drive | Point tools at that library’s `...\steamapps\common\eFootball\` |
| Only have console / mobile | No local `Coach.bin`; use eFHUB web/app or ask someone with PC install to export |

---

## Related GPSL files

| File | Purpose |
|------|---------|
| `scripts/filter_gp_managers.js` | Filter community JSON (≤87 per style) |
| `scripts/README_gp_managers.md` | Short pointer + GP-tier notes |
| This doc | Full repeatable extraction guide |

---

## Quick reference — file locations (Steam, Windows)

```
<Game>\dt200_console_all.cpk     → unpack → Coach.bin
<Game>\                           → path for PESDatabase (if you have the ZIP)
D:\Tools\PES2020Editor\           → ejogc327 install
D:\efootball-export\work\         → recommended copy workspace
GPSL\data\managers_*.csv          → versioned exports for league
```

When in doubt, search EvoWeb for **“eFootball Coach.bin CSV”** + your year; tool names change faster than this doc.
