/**
 * Parse PESDB scrape CSV and compute economics for staging import.
 */
import {
  loadPlayerValueTables,
  computePlayerEconomicsFromScrape,
} from "./player_value_calcs.js";

function splitCsvLine(line) {
  const out = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (ch === "," && !inQuotes) {
      out.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur.trim());
  return out;
}

function normalizeHeader(h) {
  return String(h || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_");
}

const HEADER_ALIASES = {
  player_id: "konami_id",
  konami_id: "konami_id",
  id: "konami_id",
  position: "position",
  player_name: "player_name",
  name: "player_name",
  nationality: "nationality",
  nation: "nationality",
  age: "age",
  rating: "rating",
  max_level_rating: "max_level_rating",
  potential: "max_level_rating",
  playing_style: "playing_style",
  playstyle: "playing_style",
  height: "height_cm",
  height_cm: "height_cm",
  stronger_foot: "stronger_foot",
  weak_foot_usage: "weak_foot_usage",
  weak_foot_accuracy: "weak_foot_accuracy",
};

export async function parsePesdbCsvToStagingRows(csvText) {
  await loadPlayerValueTables();

  const lines = String(csvText || "")
    .replace(/^\uFEFF/, "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);

  if (!lines.length) {
    throw new Error("CSV is empty");
  }

  const headers = splitCsvLine(lines[0]).map(normalizeHeader);
  const colIndex = {};
  headers.forEach((h, i) => {
    const key = HEADER_ALIASES[h] || h;
    if (!colIndex[key]) colIndex[key] = i;
  });

  if (colIndex.konami_id == null) {
    throw new Error("CSV must include a player_id / konami_id column");
  }

  const rows = [];
  const skipped = [];

  for (let li = 1; li < lines.length; li++) {
    const cols = splitCsvLine(lines[li]);
    const kid = cols[colIndex.konami_id];
    if (!kid || kid === "Unknown") {
      skipped.push(li + 1);
      continue;
    }

    const scrape = {
      player_id: kid,
      konami_id: kid,
      player_name: cols[colIndex.player_name] || "",
      position: cols[colIndex.position] || "CF",
      nationality: cols[colIndex.nationality] || "",
      age: Number(cols[colIndex.age]) || 25,
      rating: Number(cols[colIndex.rating]) || 60,
      max_level_rating:
        Number(cols[colIndex.max_level_rating]) ||
        Number(cols[colIndex.rating]) ||
        60,
      playing_style: cols[colIndex.playing_style] || "None",
      height_cm:
        colIndex.height_cm != null && cols[colIndex.height_cm]
          ? Number(cols[colIndex.height_cm])
          : null,
      stronger_foot:
        colIndex.stronger_foot != null ? cols[colIndex.stronger_foot] || null : null,
      weak_foot_usage:
        colIndex.weak_foot_usage != null
          ? cols[colIndex.weak_foot_usage] || null
          : null,
      weak_foot_accuracy:
        colIndex.weak_foot_accuracy != null
          ? cols[colIndex.weak_foot_accuracy] || null
          : null,
    };

    const econ = computePlayerEconomicsFromScrape(scrape);
    rows.push({
      konami_id: kid,
      player_name: scrape.player_name,
      position: econ.Position,
      nationality: scrape.nationality,
      age: econ.Age,
      rating: econ.Rating,
      max_level_rating: econ.Potential,
      playing_style: scrape.playing_style,
      calc_potential: econ.Calc_Potential,
      market_value: econ.market_value,
      maximum_reserve_price: econ.Maximum_Reserve_Price,
      height_cm: Number.isFinite(scrape.height_cm) ? scrape.height_cm : null,
      stronger_foot: scrape.stronger_foot,
      weak_foot_usage: scrape.weak_foot_usage,
      weak_foot_accuracy: scrape.weak_foot_accuracy,
    });
  }

  const deduped = dedupeRowsByKonamiId(rows);
  const dupesRemoved = rows.length - deduped.length;

  return { rows: deduped, skipped, headerCount: headers.length, dupesRemoved };
}

/** Drop duplicate konami_ids in a batch (last row wins). */
export function dedupeRowsByKonamiId(rows) {
  const map = new Map();
  for (const row of rows || []) {
    const kid = String(row.konami_id ?? row.player_id ?? "").trim();
    if (!kid) continue;
    map.set(kid, { ...row, konami_id: kid });
  }
  return [...map.values()];
}

export const PESDB_IMPORT_CHUNK = 150;

export function chunkRows(rows, size = PESDB_IMPORT_CHUNK) {
  const chunks = [];
  for (let i = 0; i < rows.length; i += size) {
    chunks.push(rows.slice(i, i + size));
  }
  return chunks;
}

/** Raw rows from edge scrape or CSV → staging rows with economics. */
export async function enrichRowsWithEconomics(rawRows) {
  await loadPlayerValueTables();
  return (rawRows || []).map((raw) => {
    const scrape = {
      rating: Number(raw.rating),
      max_level_rating: Number(raw.max_level_rating ?? raw.rating),
      age: Number(raw.age),
      position: raw.position ?? "CF",
      playing_style: raw.playing_style ?? "None",
    };
    const econ = computePlayerEconomicsFromScrape(scrape);
    return {
      konami_id: String(raw.konami_id ?? raw.player_id),
      player_name: raw.player_name ?? "",
      position: econ.Position,
      nationality: raw.nationality ?? "",
      age: econ.Age,
      rating: econ.Rating,
      max_level_rating: econ.Potential,
      playing_style: scrape.playing_style,
      calc_potential: econ.Calc_Potential,
      market_value: econ.market_value,
      maximum_reserve_price: econ.Maximum_Reserve_Price,
      height_cm:
        raw.height_cm != null && Number.isFinite(Number(raw.height_cm))
          ? Number(raw.height_cm)
          : raw.Height != null && Number.isFinite(Number(raw.Height))
            ? Number(raw.Height)
            : null,
      stronger_foot: raw.stronger_foot ?? raw.Stronger_Foot ?? null,
      weak_foot_usage: raw.weak_foot_usage ?? raw.Weak_Foot_Usage ?? null,
      weak_foot_accuracy:
        raw.weak_foot_accuracy ?? raw.Weak_Foot_Accuracy ?? null,
    };
  });
}
