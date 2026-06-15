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
    });
  }

  return { rows, skipped, headerCount: headers.length };
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
    };
  });
}
