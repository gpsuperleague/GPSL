#!/usr/bin/env node
/**
 * Download stadium photos from StadiumDB for GPSL clubs.
 *
 * Usage (from repo root):
 *   node scripts/fetch_stadium_images.mjs
 *   node scripts/fetch_stadium_images.mjs --dry-run
 *   node scripts/fetch_stadium_images.mjs --only LIV,FEY,URD
 *
 * Output: images/stadiums/{ShortName}.jpg
 * Mapping cache: data/stadium_stadiumdb.json
 *
 * Respect StadiumDB / photographers — images are credited on source pages.
 * For production, prefer images you have rights to; this is for league UI reference.
 */

import { writeFileSync, readFileSync, mkdirSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { readSupabaseConfig } from "./lib/supabaseFromRepo.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = join(root, "images", "stadiums");
const mapPath = join(root, "data", "stadium_stadiumdb.json");

const NATION_TO_CODE = {
  england: "eng",
  scotland: "sco",
  spain: "esp",
  italy: "ita",
  germany: "ger",
  france: "fra",
  netherlands: "ned",
  holland: "ned",
  portugal: "por",
  belgium: "bel",
  japan: "jpn",
  brazil: "bra",
  argentina: "arg",
  usa: "usa",
  "united states": "usa",
  mexico: "mex",
  turkey: "tur",
  greece: "gre",
  austria: "aut",
  switzerland: "sui",
  denmark: "den",
  sweden: "swe",
  norway: "nor",
  poland: "pol",
  czechia: "cze",
  "czech republic": "cze",
  croatia: "cro",
  serbia: "srb",
  ukraine: "ukr",
  russia: "rus",
  china: "chn",
  "south korea": "kor",
  australia: "aus",
  colombia: "col",
  chile: "chl",
  uruguay: "uru",
  paraguay: "par",
  peru: "per",
  ecuador: "ecu",
  "saudi arabia": "ksa",
  qatar: "qat",
  uae: "uae",
  scotland: "sco",
  wales: "wal",
  ireland: "irl",
  "northern ireland": "nir",
  turkiye: "tur",
  turkey: "tur",
  denmark: "den",
  unitedstates: "usa",
  "united_states": "usa",
};

/** Manual overrides when auto-slug fails (ShortName → stadiumdb page path after /stadiums/) */
const SLUG_OVERRIDES = {
  URD: "jpn/saitama_stadium",
  urawa: "jpn/saitama_stadium",
  LIV: "eng/anfield_road",
  MUN: "eng/old_trafford",
  ARS: "eng/emirates_stadium",
  CHE: "eng/stamford_bridge",
  TOT: "eng/tottenham_hotspur_stadium",
  MCI: "eng/city_of_manchester_stadium",
  AVL: "eng/villa_park",
  FEY: "ned/de_kuip",
  PSV: "ned/philips_stadion",
  AJX: "ned/johan_cruijff_arena",
  BAR: "esp/camp_nou",
  RMA: "esp/estadio_santiago_bernabeu",
  ATM: "esp/estadio_metropolitano",
  VAL: "esp/mestalla",
  SEV: "esp/ramon_sanchez_pizjuan",
  JUV: "ita/allianz_stadium",
  INT: "ita/stadio_giuseppe_meazza",
  MIL: "ita/giuseppe_meazza",
  LAZ: "ita/stadio_olimpico",
  ROM: "ita/stadio_olimpico",
  NAP: "ita/diego_armando_maradona",
  DOR: "ger/westfalenstadion",
  LEV: "ger/bayarena",
  BMU: "ger/allianz_arena",
  PSG: "fra/parc_des_princes",
  LYO: "fra/groupama_stadium",
  MAR: "fra/stade_velodrome",
  LIL: "fra/stade_pierre_mauroy",
  MON: "fra/stade_louis_ii",
  POR: "por/estadio_do_dragao",
  BEN: "por/estadio_da_luz",
  SPO: "por/estadio_jose_alvalade",
  BRU: "bel/stade_royal_lotto_park",
  AND: "bel/stade_royal_lotto_park",
  CEL: "sco/celtic_park",
  RAN: "sco/ibrox_stadium",
  FLA: "bra/maracana",
  COR: "bra/arena_corinthians",
  PAL: "bra/allianz_parque",
  SAN: "bra/vila_belmiro",
  BOC: "arg/la_bombonera",
  RIV: "arg/el_monumental",
  IND: "arg/estadio_libertadores_de_america",
  WOL: "eng/molineux_stadium",
  BET: "esp/estadio_benito_villamarin",
  VIL: "esp/estadio_de_la_ceramica",
  FIO: "ita/stadio_artemio_franchi",
  LAZ: "ita/stadio_olimpico",
  LYO: "fra/groupama_stadium",
  LIL: "fra/decathlon_arena",
  AJX: "ned/johan_cruijff_arena",
  COP: "den/parken",
  BES: "tur/tupras_stadium",
  KAS: "tur/recep_tayyip_erdogan_stadium",
  WHU: "eng/london_stadium",
  NEW: "eng/st_james_park",
  BRE: "eng/gtech_community_stadium",
  NOT: "eng/city_ground",
  LEI: "eng/king_power_stadium",
  EVE: "eng/goodison_park",
  FUL: "eng/craven_cottage",
  BOU: "eng/vitality_stadium",
  CRY: "eng/selhurst_park",
  BHA: "eng/american_express_community_stadium",
};

function slugify(text) {
  return String(text || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

function nationCode(nation) {
  const raw = slugify(nation);
  const spaced = raw.replace(/_/g, " ");
  return NATION_TO_CODE[spaced] || NATION_TO_CODE[raw] || null;
}

async function searchCountryIndex(stadiumName, country) {
  const html = await fetchPageHtml(`https://stadiumdb.com/stadiums/${country}/`);
  if (!html) return null;

  const tokens = slugify(stadiumName)
    .split("_")
    .filter((t) => t.length > 3);
  const re =
    /href="(https:\/\/stadiumdb\.com\/stadiums\/[a-z]{3}\/[^"]+)"[^>]*>([^<]+)<\/a>/gi;
  let best = null;
  let bestScore = 0;
  let m;
  while ((m = re.exec(html))) {
    const label = slugify(m[2]);
    let score = 0;
    for (const t of tokens) {
      if (label.includes(t)) score += t.length;
    }
    if (score > bestScore) {
      bestScore = score;
      best = m[1];
    }
  }
  return bestScore >= 6 ? best : null;
}

function slugCandidates(stadiumName) {
  const base = slugify(stadiumName);
  const out = [base];
  const stripped = base
    .replace(/_stadium$/, "")
    .replace(/_arena$/, "")
    .replace(/_park$/, "")
    .replace(/_ground$/, "");
  if (stripped && stripped !== base) out.push(stripped);
  return [...new Set(out)];
}

async function fetchClubs() {
  const { url, anonKey } = readSupabaseConfig();
  const res = await fetch(
    `${url}/rest/v1/Clubs?select=ShortName,Club,Stadium,Nation&ShortName=neq.FOREIGN&order=ShortName`,
    {
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${anonKey}`,
      },
    }
  );
  if (!res.ok) throw new Error(`Clubs fetch failed: ${res.status}`);
  return res.json();
}

async function pageExists(pageUrl) {
  const res = await fetch(pageUrl, {
    headers: { "User-Agent": "GPSL-StadiumSync/1.0 (personal league project)" },
  });
  if (!res.ok) return false;
  const html = await res.text();
  return !html.includes("404") && html.includes("stadiumdb.com");
}

async function resolvePageUrl(club, cache) {
  const short = club.ShortName;
  if (cache[short]?.pageUrl) return cache[short].pageUrl;
  if (SLUG_OVERRIDES[short]) {
    return `https://stadiumdb.com/stadiums/${SLUG_OVERRIDES[short]}`;
  }

  const country = nationCode(club.Nation);
  if (!country || !club.Stadium) return null;

  const fromIndex = await searchCountryIndex(club.Stadium, country);
  if (fromIndex) return fromIndex;

  for (const slug of slugCandidates(club.Stadium)) {
    const pageUrl = `https://stadiumdb.com/stadiums/${country}/${slug}`;
    if (await pageExists(pageUrl)) return pageUrl;
    await sleep(400);
  }
  return null;
}

function extractImageUrl(html) {
  const urls = [
    ...html.matchAll(
      /https:\/\/stadiumdb\.com\/pictures\/stadiums\/[a-z0-9_/]+\.jpg/gi
    ),
  ].map((m) => m[0]);

  const full = urls.find((u) => !u.endsWith("m.jpg"));
  if (full) return full;

  const thumb = urls.find((u) => u.endsWith("m.jpg"));
  if (thumb) {
    const guess = thumb.replace(/m\.jpg$/i, ".jpg");
    return guess;
  }
  return null;
}

async function fetchPageHtml(pageUrl) {
  const res = await fetch(pageUrl, {
    headers: { "User-Agent": "GPSL-StadiumSync/1.0 (personal league project)" },
  });
  if (!res.ok) return null;
  return res.text();
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function loadCache() {
  if (!existsSync(mapPath)) return {};
  try {
    return JSON.parse(readFileSync(mapPath, "utf8"));
  } catch {
    return {};
  }
}

function saveCache(cache) {
  mkdirSync(join(root, "data"), { recursive: true });
  writeFileSync(mapPath, JSON.stringify(cache, null, 2) + "\n");
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const onlyIdx = args.indexOf("--only");
  const onlySet =
    onlyIdx >= 0 && args[onlyIdx + 1]
      ? new Set(args[onlyIdx + 1].split(",").map((s) => s.trim()))
      : null;

  mkdirSync(outDir, { recursive: true });
  const cache = loadCache();
  const clubs = await fetchClubs();

  let ok = 0;
  let fail = 0;

  for (const club of clubs) {
    if (onlySet && !onlySet.has(club.ShortName)) continue;
    if (!club.Stadium?.trim()) {
      console.warn(`⏭ ${club.ShortName}: no Stadium name in DB`);
      fail++;
      continue;
    }

    const pageUrl = await resolvePageUrl(club, cache);
    if (!pageUrl) {
      console.warn(
        `✗ ${club.ShortName} (${club.Stadium}, ${club.Nation}): no StadiumDB page`
      );
      fail++;
      continue;
    }

    const html = await fetchPageHtml(pageUrl);
    const imageUrl = html ? extractImageUrl(html) : null;
    if (!imageUrl) {
      console.warn(`✗ ${club.ShortName}: no picture on ${pageUrl}`);
      fail++;
      continue;
    }

    cache[club.ShortName] = {
      stadium: club.Stadium,
      nation: club.Nation,
      pageUrl,
      imageUrl,
      fetchedAt: new Date().toISOString(),
    };

    const outPath = join(outDir, `${club.ShortName}.jpg`);
    if (dryRun) {
      console.log(`[dry] ${club.ShortName} → ${imageUrl}`);
      ok++;
      continue;
    }

    const imgRes = await fetch(imageUrl, {
      headers: { "User-Agent": "GPSL-StadiumSync/1.0" },
    });
    if (!imgRes.ok) {
      console.warn(`✗ ${club.ShortName}: download ${imgRes.status}`);
      fail++;
      continue;
    }

    const buf = Buffer.from(await imgRes.arrayBuffer());
    writeFileSync(outPath, buf);
    console.log(`✓ ${club.ShortName} → ${outPath}`);
    ok++;
    await sleep(800);
  }

  saveCache(cache);
  console.log(`\nDone: ${ok} ok, ${fail} skipped/failed. Cache: ${mapPath}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
