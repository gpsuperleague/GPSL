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

## Path A — Recommended: PESDatabase (fewest manual steps)

Best when you only need to **browse/search/export** the current eFootball DB without unpacking CPK yourself.

### A1. Install eFootball on PC (Steam)

You need a full install so the tool can read the same files the game uses.

### A2. Download PESDatabase

- Release post: [PESDatabase v0.1.0](https://www.kazemario.com/2026/03/release-pesdatabase-v010.html) (or newer if linked from pesnewupdate / EvoWeb).
- Extract the ZIP to a folder outside the game directory (e.g. `D:\Tools\PESDatabase\`).

### A3. Point the tool at your game folder

1. Run PESDatabase.
2. Set the **game path** to your `eFootball` folder (the one that contains `dt200_console_all.cpk`).
3. Let it load / index the database (first run can take a while).

### A4. Export coaches

1. Open the **coaches / managers** section (exact menu label depends on tool version).
2. Confirm the count is in the **~700+** range (not ~58 from small community JSON dumps).
3. If the tool offers **export** (CSV, Excel, copy table):
   - Export all coaches.
   - Save as: `data/managers_efootball_YYYY-MM-DD.csv` (keep outside public web if you prefer; GPSL can use a trimmed GP-tier file only).

### A5. If export is not available

Use PESDatabase to **verify names and IDs**, then use **Path B** for a bulk CSV from `Coach.bin`, or cross-check with eFHUB filters and build your GPSL list manually for GP-tier only.

---

## Path B — Full control: unpack CPK → `Coach.bin` → CSV

Use when PESDatabase does not export, or you need the raw bin for another editor.

### B1. Locate the database archive

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

### B2. Unpack the CPK

**Option 1 — CRI tools (common)**

1. Install or build [CriTools](https://github.com/sonic853/CriTools) (see repo README for Windows usage).
2. Extract `dt200_console_all.cpk` to a folder, e.g. `D:\efootball-export\cpk-unpacked\`.
3. Search the output for **`Coach.bin`** (File Explorer search).

**Option 2 — Community pack / EvoWeb**

1. Check [EvoWeb eFootball modding](https://evoweb.uk/) or [pesnewupdate](https://pesnewupdate.com/) for a “database extractor” or patch tool that matches **your** game year.
2. Follow that tool’s steps to get `.bin` files; still locate **`Coach.bin`**.

Write down the full path to `Coach.bin` (path inside CPK changes between updates).

### B3. Copy bins to a safe working folder

Example:

```
D:\efootball-export\work\
  Coach.bin
  Team.bin          (if the editor asks for related files)
  ...
```

Copy from unpack output—do not work directly in `Program Files\...\eFootball\` unless you accept restore-from-backup risk.

### B4. Open with a database editor

Pick **one** editor that supports your game version:

| Tool | Link | Coach CSV |
|------|------|-----------|
| PES 2020 Editor (ejogc327) | [tauvic99 — PES 2020 Editor](https://www.tauvic99.com/2023/02/pes-2020-editor-v012-ejogc327.html) | Documented Coach import/export when bins are extracted |
| eFootball Player Data Editor | [pesnewupdate](https://pesnewupdate.com/efootball-player-data-editor/) | [EvoWeb thread 88692](https://evoweb.uk/threads/88692/) — confirm coach support for your patch |
| PESDatabase | See Path A | May avoid manual unpack |

**ejogc327-style steps (typical):**

1. Install/run the editor.
2. **File → Open** (or “Load database”) and select your **working folder** containing `Coach.bin`.
3. Open the **Coach** / **Manager** table.
4. **Export → CSV** (all rows).
5. Save as `managers_raw_YYYY-MM-DD.csv`.

### B5. Verify the export

Open the CSV and check:

- Row count ≈ **700+** (target ~732 for current live DB).
- Columns include at least **name** and/or **ID** (column names depend on the editor).
- If playstyle columns are **missing**, proficiencies may live in other bins—the editor may not decode them yet. Use eFHUB (max 87 per style) to validate GP-tier names, or wait for a tool update.

---

## Path C — No game files: community JSON (small sample only)

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
[ ] Path A: PESDatabase load + coach export
    OR
[ ] Path B: Unpack dt200_console_all.cpk → find Coach.bin → ejogc327 CSV
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
<Game>\                           → path for PESDatabase
D:\efootball-export\work\         → recommended copy workspace
GPSL\data\managers_*.csv          → versioned exports for league
```

When in doubt, search EvoWeb for **“eFootball Coach.bin CSV”** + your year; tool names change faster than this doc.
