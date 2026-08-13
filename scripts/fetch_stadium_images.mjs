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
 *
 * Shared overrides/helpers: stadium_stadiumdb.js (also used by club-stadiums-sync edge).
 */

import { writeFileSync, readFileSync, mkdirSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { readSupabaseConfig } from "./lib/supabaseFromRepo.mjs";
import {
  SLUG_OVERRIDES,
  fetchStadiumImage,
} from "../stadium_stadiumdb.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = join(root, "images", "stadiums");
const mapPath = join(root, "data", "stadium_stadiumdb.json");

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

    const fetched = await fetchStadiumImage(club, {
      fetchImpl: fetch,
      cache,
      skipBytes: dryRun,
    });

    if (fetched.error) {
      console.warn(
        `✗ ${club.ShortName} (${club.Stadium}, ${club.Nation}): ${fetched.error}`
      );
      fail++;
      continue;
    }

    let pageUrl = fetched.pageUrl;
    if (!pageUrl && SLUG_OVERRIDES[club.ShortName]) {
      pageUrl = `https://stadiumdb.com/stadiums/${SLUG_OVERRIDES[club.ShortName]}`;
    }

    cache[club.ShortName] = {
      stadium: club.Stadium,
      nation: club.Nation,
      pageUrl,
      imageUrl: fetched.imageUrl,
      fetchedAt: new Date().toISOString(),
    };

    const outPath = join(outDir, `${club.ShortName}.jpg`);
    if (dryRun) {
      console.log(`[dry] ${club.ShortName} → ${fetched.imageUrl}`);
      ok++;
      continue;
    }

    if (!fetched.bytes) {
      console.warn(`✗ ${club.ShortName}: no image bytes`);
      fail++;
      continue;
    }

    writeFileSync(outPath, Buffer.from(fetched.bytes));
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
