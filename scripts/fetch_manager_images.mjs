#!/usr/bin/env node
/**
 * Download manager portraits for GPSL MGDB / manager draft auction.
 *
 * Usage (from repo root):
 *   node scripts/fetch_manager_images.mjs
 *   node scripts/fetch_manager_images.mjs --dry-run
 *   node scripts/fetch_manager_images.mjs --only maurizio-sarri,thomas-tuchel
 *
 * Output: images/managers/{slug}.jpg
 * Source: eFootballHub coach search + coach page (best-effort name match).
 *
 * Respect third-party sites — for league UI reference only.
 */

import { writeFileSync, readFileSync, mkdirSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const seedPath = join(root, "supabase", "sql", "patches", "managers_seed_data.sql");
const outDir = join(root, "images", "managers");
const mapPath = join(root, "data", "manager_efhub_ids.json");

const HUB_BASE = "https://www.efootballhub.net";
const HUB_VERSION = "efootball23";
const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 GPSL-fetch";

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const onlyIdx = args.indexOf("--only");
const onlySlugs =
  onlyIdx >= 0 && args[onlyIdx + 1]
    ? new Set(
        args[onlyIdx + 1]
          .split(",")
          .map((s) => s.trim().toLowerCase())
          .filter(Boolean)
      )
    : null;

function parseManagersFromSeed() {
  const sql = readFileSync(seedPath, "utf8");
  const re =
    /\('([^']+)',\s*'([^']*)',\s*'([^']*)'/g;
  const rows = [];
  let m;
  while ((m = re.exec(sql))) {
    rows.push({ slug: m[1], name: m[2], nation: m[3] });
  }
  return rows;
}

function loadIdOverrides() {
  if (!existsSync(mapPath)) return {};
  try {
    return JSON.parse(readFileSync(mapPath, "utf8"));
  } catch {
    return {};
  }
}

function saveIdOverrides(map) {
  writeFileSync(mapPath, JSON.stringify(map, null, 2) + "\n", "utf8");
}

function normalizeName(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[.\u00b7]/g, " ")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

async function fetchText(url) {
  const res = await fetch(url, {
    headers: { "User-Agent": UA, Accept: "text/html,application/json" },
    redirect: "follow",
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.text();
}

async function fetchBinary(url) {
  const res = await fetch(url, {
    headers: { "User-Agent": UA, Accept: "image/*" },
    redirect: "follow",
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length < 500) throw new Error(`Image too small (${buf.length} bytes)`);
  return buf;
}

function extractCoachIdFromSearch(html, targetName) {
  const normTarget = normalizeName(targetName);
  const cardRe =
    /<a[^>]+href="\/(?:efootball\d+|pes21)\/coach\/(\d+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let best = null;
  let m;
  while ((m = cardRe.exec(html))) {
    const id = m[1];
    const text = m[2].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    const norm = normalizeName(text);
    if (!norm) continue;
    if (norm === normTarget || norm.includes(normTarget) || normTarget.includes(norm)) {
      return id;
    }
    if (!best) best = { id, text };
  }
  return best?.id || null;
}

function extractImageFromCoachPage(html) {
  const og = html.match(
    /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i
  );
  if (og?.[1]) return og[1];

  const img =
    html.match(/<img[^>]+src=["']([^"']*coach[^"']*)["']/i) ||
    html.match(/<img[^>]+src=["']([^"']*manager[^"']*)["']/i);
  if (img?.[1]) {
    const src = img[1];
    if (src.startsWith("http")) return src;
    if (src.startsWith("//")) return `https:${src}`;
    if (src.startsWith("/")) return `${HUB_BASE}${src}`;
    return `${HUB_BASE}/${src}`;
  }
  return null;
}

async function resolveCoachId(manager, overrides) {
  if (overrides[manager.slug]) return String(overrides[manager.slug]);

  const q = encodeURIComponent(manager.name.replace(/\./g, " ").trim());
  const searchUrl = `${HUB_BASE}/${HUB_VERSION}/search/coaches?q=${q}`;
  const html = await fetchText(searchUrl);
  const id = extractCoachIdFromSearch(html, manager.name);
  if (!id) throw new Error(`No coach match on eFootballHub for "${manager.name}"`);
  return id;
}

async function resolveImageUrl(coachId) {
  const pageUrl = `${HUB_BASE}/${HUB_VERSION}/coach/${coachId}`;
  const html = await fetchText(pageUrl);
  const fromPage = extractImageFromCoachPage(html);
  if (fromPage) return fromPage;

  const guesses = [
    `${HUB_BASE}/images/coach/${coachId}.png`,
    `${HUB_BASE}/images/coaches/${coachId}.png`,
    `${HUB_BASE}/images/faces/coach/${coachId}.png`,
  ];
  for (const url of guesses) {
    try {
      await fetchBinary(url);
      return url;
    } catch {
      /* try next */
    }
  }
  throw new Error(`No image URL for coach ${coachId}`);
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const managers = parseManagersFromSeed();
  const overrides = loadIdOverrides();
  const filtered = onlySlugs
    ? managers.filter((m) => onlySlugs.has(m.slug))
    : managers;

  console.log(`Managers: ${filtered.length} (dry-run: ${dryRun})`);

  let ok = 0;
  let skip = 0;
  let fail = 0;

  for (const mgr of filtered) {
    const outPath = join(outDir, `${mgr.slug}.jpg`);
    if (existsSync(outPath) && !args.includes("--force")) {
      console.log(`SKIP ${mgr.slug} (already exists)`);
      skip++;
      continue;
    }

    try {
      const coachId = await resolveCoachId(mgr, overrides);
      overrides[mgr.slug] = coachId;
      const imageUrl = await resolveImageUrl(coachId);
      console.log(`${mgr.slug} → coach ${coachId} → ${imageUrl}`);

      if (!dryRun) {
        const buf = await fetchBinary(imageUrl);
        writeFileSync(outPath, buf);
        ok++;
      } else {
        ok++;
      }

      await new Promise((r) => setTimeout(r, 800));
    } catch (err) {
      console.warn(`FAIL ${mgr.slug} (${mgr.name}): ${err.message}`);
      fail++;
    }
  }

  if (!dryRun) saveIdOverrides(overrides);

  if (!dryRun && ok > 0) {
    execSync("node scripts/sync_manager_portraits_manifest.mjs", {
      cwd: root,
      stdio: "inherit",
    });
  }

  console.log(`Done. saved=${ok} skipped=${skip} failed=${fail}`);
  if (fail) process.exitCode = 1;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
