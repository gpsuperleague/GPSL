// GPSL club-kits-cof-sync — single file for Supabase Dashboard deploy
// Re-bundle: python scripts/bundle_club_kits_edge.py

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/** Colours-of-Football.com kit lookup — shared by edge function + local sync script */

const COF_BASE = "https://www.colours-of-football.com";
const COF_COLOURS = `${COF_BASE}/colours03`;

/** GPSL Clubs.Nation (normalized) → COF folder + index page */
const COF_NATION_MAP = {
  england: { folder: "eng", index: "eng.html" },
  spain: { folder: "esp", index: "esp.html" },
  italy: { folder: "ita", index: "italy.html" },
  germany: { folder: "ger", index: "germany.html" },
  france: { folder: "fra", index: "fra.html" },
  netherlands: { folder: "ned", index: "ned.html" },
  portugal: { folder: "por", index: "por.html" },
  belgium: { folder: "bel", index: "belgium.html" },
  scotland: { folder: "sco", index: "scotland.html" },
  turkey: { folder: "tur", index: "tur.html" },
  turkiye: { folder: "tur", index: "tur.html" },
  brazil: { folder: "bra", index: "bra.html" },
  argentina: { folder: "arg", index: "arg.html" },
  usa: { folder: "usa", index: "usa.html" },
  "united states": { folder: "usa", index: "usa.html" },
  mexico: { folder: "mex", index: "mex.html" },
  japan: { folder: "jap", index: "jap.html" },
  korea: { folder: "kor", index: "kor.html" },
  "south korea": { folder: "kor", index: "kor.html" },
  "korea republic": { folder: "kor", index: "kor.html" },
  denmark: { folder: "den", index: "den.html" },
  sweden: { folder: "swe", index: "swe.html" },
  norway: { folder: "nor", index: "nor.html" },
  austria: { folder: "aut", index: "aut.html" },
  switzerland: { folder: "sui", index: "sui.html" },
  poland: { folder: "pol", index: "pol.html" },
  greece: { folder: "gre", index: "gre.html" },
  russia: { folder: "rus", index: "rus.html" },
  ukraine: { folder: "ukr", index: "ukr.html" },
  croatia: { folder: "cro", index: "cro.html" },
  romania: { folder: "rom", index: "rom.html" },
  "czech republic": { folder: "cze", index: "cze.html" },
  czechia: { folder: "cze", index: "cze.html" },
  hungary: { folder: "hungary", index: "hungary.html" },
  ireland: { folder: "irl", index: "irl.html" },
  "republic of ireland": { folder: "irl", index: "irl.html" },
  wales: { folder: "wales", index: "wales.html" },
  serbia: { folder: "serbia", index: "serbia.html" },
  chile: { folder: "chile", index: "chile.html" },
  colombia: { folder: "col", index: "col.html" },
  uruguay: { folder: "uru", index: "uru.html" },
  paraguay: { folder: "paraguay", index: "paraguay.html" },
  peru: { folder: "peru", index: "peru.html" },
  ecuador: { folder: "ecuador", index: "ecuador.html" },
  bolivia: { folder: "bolivia", index: "bolivia.html" },
  venezuela: { folder: "venezuela", index: "venezuela.html" },
  australia: { folder: "aus", index: "aus.html" },
  china: { folder: "chn", index: "chn.html" },
  "saudi arabia": { folder: "sau", index: "sau.html" },
  israel: { folder: "israel", index: "israel.html" },
};

/** Manual overrides when auto-match fails: ShortName → COF club folder slug (under nation folder) */
const COF_CLUB_SLUG_OVERRIDES = {
  AVL: "a_villa",
  MUN: "man_utd",
  MCI: "man_city",
  TOT: "tottenham",
  WOL: "wolverhmp",
  WHU: "westham",
  BRE: "brentford",
  BAR: "barcelona",
  ATM: "atletico",
  RMA: "real_madrid",
  JUV: "juventus",
  INT: "inter",
  MIL: "milan",
  DOR: "dortmund",
  PSG: "psg",
  AJX: "ajax",
  BEN: "benfica",
  POR: "porto",
  SPO: "sporting",
  BOC: "boca",
  COR: "corinthians",
  NAC: "atletico_nacional",
  AND: "anderlecht",
  PAL: "palmeiras",
  CVI: "celta",
};

/** When slug alone is not enough (page stem differs from folder name) */
const COF_CLUB_PATH_OVERRIDES = {
  WOL: { slug: "wolverhmp", pageStem: "wolves" },
};

const USER_AGENT =
  "Mozilla/5.0 (compatible; GPSL-KitSync/1.0; +https://github.com/gpsl)";

const COF_MIN_GAP_MS = 900;
const COF_MAX_RETRIES = 4;
const COF_MAX_BACKOFF_MS = 8000;

function createCofFetchCache() {
  return { html: new Map(), lastFetchMs: 0 };
}

function sleepMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function politeCofPause(cache) {
  if (!cache) return;
  const elapsed = Date.now() - (cache.lastFetchMs || 0);
  if (elapsed < COF_MIN_GAP_MS) {
    await sleepMs(COF_MIN_GAP_MS - elapsed);
  }
}

/** YYZZ kit code → season start year (2526 → 2025, 9899 → 1998). */
function seasonCodeToStartYear(code) {
  const s = String(code).padStart(4, "0");
  const yy = Number(s.slice(0, 2));
  if (!Number.isFinite(yy)) return 0;
  return yy <= 30 ? 2000 + yy : 1900 + yy;
}

function isPlausibleKitSeasonCode(code) {
  const start = seasonCodeToStartYear(code);
  return start >= 1990 && start <= 2040;
}

/** e.g. 2025 + 26 → 2526 (rejects bogus centuries like 1998-99 beating 2025-26). */
function seasonCodeFromYearPair(y1Text, y2Text) {
  const raw1 = String(y1Text ?? "").trim();
  const raw2 = String(y2Text ?? "").trim();
  let y1 = Number(raw1);
  let y2 = Number(raw2);
  if (!Number.isFinite(y1) || !Number.isFinite(y2)) return null;

  if (raw1.length === 2) {
    y1 = y1 <= 30 ? 2000 + y1 : 1900 + y1;
    y2 = Number(raw2) <= 30 ? 2000 + Number(raw2) : 1900 + Number(raw2);
  } else if (raw2.length === 2) {
    y2 = Math.floor(y1 / 100) * 100 + Number(raw2);
    if (y2 < y1) y2 += 100;
  }

  if (y1 < 1990 || y1 > 2040) return null;
  if (y2 < y1 || y2 > y1 + 1) return null;

  const code = Number(String(y1).slice(-2) + String(y2).slice(-2));
  return isPlausibleKitSeasonCode(code) ? code : null;
}

function normalizeNationKey(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeClubName(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(
      /\b(fc|afc|cf|sc|ac|sv|sk|united|city|town|rovers|wanderers|hotspur|athletic|club|deportivo|real|balompie|sporting)\b/g,
      " "
    )
    .replace(/[^a-z0-9]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function cofNationConfig(nation) {
  const key = normalizeNationKey(nation);
  if (COF_NATION_MAP[key]) return COF_NATION_MAP[key];
  if (key && COF_NATION_MAP[key.replace(/ republic$/, "")]) {
    return COF_NATION_MAP[key.replace(/ republic$/, "")];
  }
  return null;
}

function stripTags(html) {
  return String(html ?? "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function resolveCofUrl(pageUrl, src) {
  if (!src) return null;
  if (/^https?:\/\//i.test(src)) return src;
  if (src.startsWith("/")) return `${COF_BASE}${src}`;
  const base = pageUrl.replace(/[^/]+$/, "");
  return new URL(src, base).href;
}

function parseCofIndexLinks(html) {
  const links = [];
  const seen = new Set();

  for (const m of html.matchAll(
    /<a[^>]+href="([^"#?]+\/[^"#?]+_\d+\.html)"[^>]*>([\s\S]*?)<\/a>/gi
  )) {
    const href = m[1].replace(/^\.\//, "");
    if (seen.has(href)) continue;
    seen.add(href);

    const inner = m[2];
    const alt = inner.match(/alt="([^"]+)"/i);
    const name = stripTags(alt ? alt[1] : inner);
    if (!name || href.startsWith("http") || href.includes("..")) continue;

    const parts = href.split("/");
    if (parts.length < 2) continue;

    links.push({
      name,
      href,
      slug: parts[0],
      pageStem: parts[1].replace(/_\d+\.html$/i, ""),
    });
  }

  return links;
}

function matchCofClubLink(links, clubName) {
  const target = normalizeClubName(clubName);
  if (!target) return null;

  let best = null;
  let bestScore = 0;

  for (const link of links) {
    const name = normalizeClubName(link.name);
    if (!name) continue;
    if (name === target) return link;

    let score = 0;
    if (name.includes(target) || target.includes(name)) {
      score = Math.min(name.length, target.length);
    } else {
      const targetTokens = target.split(" ").filter((t) => t.length > 2);
      const nameTokens = new Set(name.split(" ").filter((t) => t.length > 2));
      const overlap = targetTokens.filter((t) => nameTokens.has(t)).length;
      if (overlap >= 2) score = overlap * 10;
      else if (overlap === 1 && targetTokens.length === 1) score = 8;
    }

    if (score > bestScore) {
      bestScore = score;
      best = link;
    }
  }

  return bestScore >= 6 ? best : null;
}

/** Read COF on-page headers: "home kit 2025-2026", "away kit 25-26", etc. */
function findLatestSeasonFromHtml(html) {
  let bestCode = 0;
  let bestStart = 0;

  const consider = (code) => {
    if (!code || !isPlausibleKitSeasonCode(code)) return;
    const start = seasonCodeToStartYear(code);
    if (start > bestStart) {
      bestStart = start;
      bestCode = code;
    }
  };

  for (const m of html.matchAll(
    /(?:home|away|third)\s+kit\s+(\d{4})\s*[-–/]\s*(\d{2,4})/gi
  )) {
    consider(seasonCodeFromYearPair(m[1], m[2]));
  }

  for (const m of html.matchAll(
    /(?:home|away|third)\s+kit\s+(\d{2})\s*[-–/]\s*(\d{2})/gi
  )) {
    consider(seasonCodeFromYearPair(m[1], m[2]));
  }

  return bestCode || null;
}

/** 2526 → "2025-26" for admin log / UI */
function formatSeasonCode(code) {
  if (!code) return null;
  const y1 = seasonCodeToStartYear(code);
  const y2 = y1 + 1;
  return `${y1}-${String(y2).slice(-2)}`;
}

/** European season start year (Jul–Jun): e.g. Jun 2026 → 2025 for 2025-26. */
function currentKitSeasonStartYear(now = new Date()) {
  const y = now.getFullYear();
  const m = now.getMonth() + 1;
  return m >= 7 ? y : y - 1;
}

/** 2024 → 2425 */
function startYearToSeasonCode(startYear) {
  const y1 = Number(startYear);
  if (!Number.isFinite(y1) || y1 < 1990 || y1 > 2040) return null;
  const y2 = y1 + 1;
  const code = Number(String(y1).slice(-2) + String(y2).slice(-2));
  return isPlausibleKitSeasonCode(code) ? code : null;
}

/** Parse COF filename season digits (2526→2025, 2021→2020, 0910→2009). */
function parseCofSeasonDigits(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return null;

  const yy = Math.floor(n / 100);
  const zz = n % 100;
  if (zz === (yy + 1) % 100) {
    const startYear = yy <= 30 ? 2000 + yy : 1900 + yy;
    if (startYear >= 1990 && startYear <= 2040) {
      return { seasonStartYear: startYear, seasonCode: n };
    }
  }

  if (n >= 1990 && n <= 2040) {
    const startYear = n - 1;
    if (startYear >= 1989 && startYear <= 2039) {
      return {
        seasonStartYear: startYear,
        seasonCode: startYearToSeasonCode(startYear),
      };
    }
  }

  return null;
}

/** eng_liverpool_1_2526.png → { kitNum, seasonStartYear, seasonCode, variant } */
function parseCofKitFileName(file) {
  const km = String(file || "").match(
    /_(\d)[a-z]?_(\d{4})(?:_(\d+))?\.(?:png|gif)$/i
  );
  if (!km) return null;

  const kitNum = Number(km[1]);
  const variant = km[3] ? Number(km[3]) : 0;
  const season = parseCofSeasonDigits(km[2]);
  if (!season || kitNum < 1 || kitNum > 3) return null;

  return { kitNum, variant, file, ...season };
}

function seasonStartFromKitUrl(url) {
  const file = String(url || "").split("/").pop() || "";
  const parsed = parseCofKitFileName(file);
  return parsed?.seasonStartYear ?? 0;
}

function maxSeasonStartFromKitUrls(kits) {
  let max = 0;
  for (const url of [kits?.home, kits?.away, kits?.third]) {
    max = Math.max(max, seasonStartFromKitUrl(url));
  }
  return max;
}

function countKitUrls(kits) {
  return [kits?.home, kits?.away, kits?.third].filter(Boolean).length;
}

function parseKitCandidatesFromHtml(html, pageUrl) {
  const buckets = { home: [], away: [], third: [] };

  for (const m of html.matchAll(/src="([^"]+\.(?:png|gif))"/gi)) {
    const src = m[1];
    const file = src.split("/").pop() || "";
    const parsed = parseCofKitFileName(file);
    if (!parsed) continue;

    const kind = ["home", "away", "third"][parsed.kitNum - 1];
    buckets[kind].push({
      seasonStartYear: parsed.seasonStartYear,
      seasonCode: parsed.seasonCode,
      variant: parsed.variant,
      file,
      url: resolveCofUrl(pageUrl, src),
    });
  }

  return buckets;
}

function pickKitUrlForSeasonYear(candidates, seasonStartYear, strict = false) {
  if (!candidates.length) return null;

  const year = Number(seasonStartYear);
  if (Number.isFinite(year) && year >= 1990) {
    const filtered = candidates.filter((x) => x.seasonStartYear === year);
    if (filtered.length) {
      filtered.sort(
        (a, b) => a.variant - b.variant || a.file.localeCompare(b.file)
      );
      return filtered[0].url;
    }
    if (strict) return null;
  }

  const maxSeason = Math.max(...candidates.map((x) => x.seasonStartYear));
  const top = candidates.filter((x) => x.seasonStartYear === maxSeason);
  top.sort(
    (a, b) => a.variant - b.variant || a.file.localeCompare(b.file)
  );
  return top[0]?.url ?? null;
}

function pickLatestKitUrl(candidates, latestSeasonCode = null, strict = false) {
  if (!candidates.length) return null;
  if (!latestSeasonCode) {
    if (strict) return null;
    return pickKitUrlForSeasonYear(candidates, NaN, false);
  }
  const seasonYear = seasonCodeToStartYear(latestSeasonCode);
  return pickKitUrlForSeasonYear(candidates, seasonYear, strict);
}

function pickLatestKits(buckets, latestSeasonCode = null, strict = false) {
  return {
    home: pickLatestKitUrl(buckets.home, latestSeasonCode, strict),
    away: pickLatestKitUrl(buckets.away, latestSeasonCode, strict),
    third: pickLatestKitUrl(buckets.third, latestSeasonCode, strict),
  };
}

function pickKitsForSeasonYear(buckets, seasonStartYear, strict = true) {
  const year = Number(seasonStartYear);
  return {
    home: pickKitUrlForSeasonYear(buckets.home, year, strict),
    away: pickKitUrlForSeasonYear(buckets.away, year, strict),
    third: pickKitUrlForSeasonYear(buckets.third, year, strict),
  };
}

function mergeKitBuckets(a, b) {
  return {
    home: [...a.home, ...b.home],
    away: [...a.away, ...b.away],
    third: [...a.third, ...b.third],
  };
}

/** @deprecated use pickLatestKits after merging buckets */
function parseKitImagesFromHtml(html, pageUrl) {
  return pickLatestKits(parseKitCandidatesFromHtml(html, pageUrl));
}

function mergeKitUrls(a, b) {
  const seasonFromUrl = (url) => seasonStartFromKitUrl(url);
  const pick = (left, right) => {
    if (!left) return right;
    if (!right) return left;
    return seasonFromUrl(left) >= seasonFromUrl(right) ? left : right;
  };
  return {
    home: pick(a.home, b.home),
    away: pick(a.away, b.away),
    third: pick(a.third, b.third),
  };
}

async function fetchCofHtml(url, fetchImpl = fetch, cache = null) {
  if (cache?.html?.has(url)) return cache.html.get(url);

  let lastErr = null;
  for (let attempt = 0; attempt < COF_MAX_RETRIES; attempt += 1) {
    await politeCofPause(cache);
    try {
      const res = await fetchImpl(url, {
        headers: { "User-Agent": USER_AGENT, Accept: "text/html" },
      });
      cache && (cache.lastFetchMs = Date.now());

      if (res.status === 429 || res.status === 503) {
        const wait = Math.min(COF_MAX_BACKOFF_MS, 1500 * 2 ** attempt);
        await sleepMs(wait);
        continue;
      }
      if (!res.ok) {
        throw new Error(`COF fetch failed (${res.status}): ${url}`);
      }
      const text = await res.text();
      cache?.html?.set(url, text);
      return text;
    } catch (err) {
      lastErr = err;
      if (attempt < COF_MAX_RETRIES - 1) {
        await sleepMs(Math.min(COF_MAX_BACKOFF_MS, 1200 * 2 ** attempt));
      }
    }
  }
  throw lastErr || new Error(`COF fetch failed: ${url}`);
}

async function findLastCofClubPage(
  nationFolder,
  slug,
  pageStem,
  fetchImpl = fetch,
  cache = null
) {
  let last = 1;
  for (let page = 1; page <= 12; page += 1) {
    const url = `${COF_COLOURS}/${nationFolder}/${slug}/${pageStem}_${page}.html`;
    try {
      await fetchCofHtml(url, fetchImpl, cache);
      last = page;
    } catch {
      break;
    }
  }
  return last;
}

async function resolveCofClubLink(
  nation,
  clubName,
  clubShort = null,
  fetchImpl = fetch,
  cache = null
) {
  const overrideSlug = clubShort ? COF_CLUB_SLUG_OVERRIDES[clubShort] : null;
  const pathOverride = clubShort ? COF_CLUB_PATH_OVERRIDES[clubShort] : null;
  const cfg = cofNationConfig(nation);
  if (!cfg) return { error: `No COF mapping for nation: ${nation}` };

  if (pathOverride) {
    return {
      nationFolder: cfg.folder,
      slug: pathOverride.slug,
      pageStem: pathOverride.pageStem,
      cofClubName: clubName,
      indexUrl: `${COF_COLOURS}/${cfg.folder}/${cfg.index}`,
    };
  }

  const indexUrl = `${COF_COLOURS}/${cfg.folder}/${cfg.index}`;
  const indexHtml = await fetchCofHtml(indexUrl, fetchImpl, cache);
  const links = parseCofIndexLinks(indexHtml);

  let link = null;
  if (overrideSlug) {
    link =
      links.find((l) => l.slug === overrideSlug) ||
      links.find((l) => l.pageStem === overrideSlug);
  }
  if (!link) link = matchCofClubLink(links, clubName);
  if (!link) {
    return {
      error: `Club not found on COF (${cfg.folder}): ${clubName}`,
      nationFolder: cfg.folder,
    };
  }

  return {
    nationFolder: cfg.folder,
    slug: link.slug,
    pageStem: link.pageStem,
    cofClubName: link.name,
    indexUrl,
  };
}

async function fetchLatestCofKits(
  nation,
  clubName,
  clubShort = null,
  fetchImpl = fetch,
  cache = null,
  options = {}
) {
  const {
    targetStartYear = null,
    strictSeason = false,
  } = options;
  const resolved = await resolveCofClubLink(
    nation,
    clubName,
    clubShort,
    fetchImpl,
    cache
  );
  if (resolved.error) return resolved;

  const { nationFolder, slug, pageStem } = resolved;
  let buckets = { home: [], away: [], third: [] };
  const htmlParts = [];
  let lastPage = 0;

  for (let page = 1; page <= 12; page += 1) {
    const pageUrl = `${COF_COLOURS}/${nationFolder}/${slug}/${pageStem}_${page}.html`;
    try {
      const html = await fetchCofHtml(pageUrl, fetchImpl, cache);
      lastPage = page;
      htmlParts.push(html);
      buckets = mergeKitBuckets(
        buckets,
        parseKitCandidatesFromHtml(html, pageUrl)
      );
    } catch {
      break;
    }
  }

  if (!lastPage) {
    return { ...resolved, error: `No COF kit pages found for ${clubName}` };
  }

  const latestSeasonCode = findLatestSeasonFromHtml(htmlParts.join("\n"));
  const resolvedStartYear = targetStartYear != null
    ? Number(targetStartYear)
    : latestSeasonCode
      ? seasonCodeToStartYear(latestSeasonCode)
      : null;
  const useStrict = strictSeason || targetStartYear != null;

  const kits = targetStartYear != null
    ? pickKitsForSeasonYear(buckets, targetStartYear, true)
    : pickLatestKits(buckets, latestSeasonCode, useStrict);

  const appliedSeasonCode =
    resolvedStartYear != null
      ? startYearToSeasonCode(resolvedStartYear)
      : latestSeasonCode;
  const seasonLabel = formatSeasonCode(appliedSeasonCode);
  const kitCount = countKitUrls(kits);

  if (kitCount === 0) {
    const label = seasonLabel || "requested season";
    return {
      ...resolved,
      lastPage,
      latestSeasonCode: appliedSeasonCode,
      seasonLabel,
      kits,
      source: "colours-of-football.com",
      error: `No kits found for ${label}`,
    };
  }

  return {
    ...resolved,
    lastPage,
    latestSeasonCode: appliedSeasonCode,
    seasonLabel,
    kits,
    source: "colours-of-football.com",
  };
}

async function downloadCofImage(url, fetchImpl = fetch, cache = null) {
  let lastErr = null;
  for (let attempt = 0; attempt < COF_MAX_RETRIES; attempt += 1) {
    await politeCofPause(cache);
    try {
      const res = await fetchImpl(url, {
        headers: { "User-Agent": USER_AGENT, Accept: "image/*" },
      });
      cache && (cache.lastFetchMs = Date.now());

      if (res.status === 429 || res.status === 503) {
        await sleepMs(Math.min(COF_MAX_BACKOFF_MS, 1500 * 2 ** attempt));
        continue;
      }
      if (!res.ok) {
        throw new Error(`Image download failed (${res.status}): ${url}`);
      }
      const buf = await res.arrayBuffer();
      const type = res.headers.get("content-type") || "image/png";
      return { bytes: new Uint8Array(buf), contentType: type };
    } catch (err) {
      lastErr = err;
      if (attempt < COF_MAX_RETRIES - 1) {
        await sleepMs(Math.min(COF_MAX_BACKOFF_MS, 1200 * 2 ** attempt));
      }
    }
  }
  throw lastErr || new Error(`Image download failed: ${url}`);
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const INVOCATION_BUDGET_MS = 50_000;

function timedOut(deadline: number) {
  return Math.max(0, deadline - Date.now()) < 3000;
}

type ClubRow = {
  ShortName: string;
  Club: string;
  Nation: string;
};

type KitRow = {
  home_image_url: string | null;
  away_image_url: string | null;
  third_image_url: string | null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Unauthorized" }, 401);

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

    const { data: isAdmin, error: adminError } = await userClient.rpc(
      "is_gpsl_admin"
    );
    if (adminError || !isAdmin) return jsonResponse({ error: "Admin only" }, 403);

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "sync_batch");
    const downloadImages = body?.download === true;
    const storageBucket = String(body?.bucket || "club-kits");
    const cofCache = createCofFetchCache();
    const deadline = Date.now() + INVOCATION_BUDGET_MS;

    const seasonStartYear =
      body?.season_start_year != null && body?.season_start_year !== ""
        ? Number(body.season_start_year)
        : null;
    const strictSeason = body?.strict_season !== false;
    const skipIfNewerSaved = body?.skip_if_newer_saved === true;
    const cofOptions = {
      targetStartYear: Number.isFinite(seasonStartYear) ? seasonStartYear : null,
      strictSeason,
    };

    const clubShortNames = Array.isArray(body?.club_short_names)
      ? body.club_short_names
          .map((s: unknown) => String(s ?? "").trim().toUpperCase())
          .filter(Boolean)
      : null;

    if (action === "preview_club") {
      const short = String(body?.club_short_name || "").trim().toUpperCase();
      if (!short) return jsonResponse({ error: "club_short_name required" }, 400);

      const { data: club, error } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Nation")
        .eq("ShortName", short)
        .maybeSingle();

      if (error || !club) {
        return jsonResponse({ error: `Club not found: ${short}` }, 404);
      }

      const result = await fetchLatestCofKits(
        club.Nation,
        club.Club,
        club.ShortName,
        fetch,
        cofCache,
        cofOptions
      );
      return jsonResponse({ ok: true, club, result });
    }

    if (action !== "sync_batch") {
      return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }

    const offset = Math.max(0, Number(body?.offset) || 0);
    const limit = Math.min(4, Math.max(1, Number(body?.limit) || 1));

    let rows: ClubRow[] = [];
    let totalClubs = 0;

    if (clubShortNames?.length) {
      const slice = clubShortNames.slice(offset, offset + limit);
      if (!slice.length) {
        return jsonResponse({
          ok: true,
          offset,
          limit,
          next_offset: null,
          done: true,
          total_clubs: clubShortNames.length,
          results: [],
          season_start_year: seasonStartYear,
        });
      }

      const { data: clubs, error: clubsError } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Nation")
        .in("ShortName", slice)
        .order("Club");

      if (clubsError) {
        return jsonResponse({ error: clubsError.message }, 500);
      }

      rows = (clubs || []) as ClubRow[];
      totalClubs = clubShortNames.length;
    } else {
      const { data: clubs, error: clubsError } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Nation")
        .neq("ShortName", "FOREIGN")
        .order("Club")
        .range(offset, offset + limit - 1);

      if (clubsError) {
        return jsonResponse({ error: clubsError.message }, 500);
      }

      rows = (clubs || []) as ClubRow[];

      const { count } = await adminClient
        .from("Clubs")
        .select("*", { count: "exact", head: true })
        .neq("ShortName", "FOREIGN");

      totalClubs = count || 0;
    }

    const results: Record<string, unknown>[] = [];

    for (const club of rows) {
      const entry: Record<string, unknown> = {
        club_short_name: club.ShortName,
        club_name: club.Club,
        nation: club.Nation,
        ok: false,
      };

      try {
        if (skipIfNewerSaved && cofOptions.targetStartYear != null) {
          const { data: existing } = await adminClient
            .from("club_kits")
            .select("home_image_url, away_image_url, third_image_url")
            .eq("club_short_name", club.ShortName)
            .maybeSingle();

          const savedYear = maxSeasonStartFromKitUrls(existing as KitRow);
          if (savedYear > cofOptions.targetStartYear) {
            entry.ok = true;
            entry.skipped = true;
            entry.reason = `Already has ${savedYear}-${String(savedYear + 1).slice(-2)} kits`;
            results.push(entry);
            continue;
          }
        }

        const cof = await fetchLatestCofKits(
          club.Nation,
          club.Club,
          club.ShortName,
          fetch,
          cofCache,
          cofOptions
        );

        if (cof.error) {
          entry.error = cof.error;
          results.push(entry);
          continue;
        }

        const kits = cof.kits || { home: null, away: null, third: null };
        let homeUrl = kits.home;
        let awayUrl = kits.away;
        let thirdUrl = kits.third;

        if (downloadImages) {
          if (timedOut(deadline)) {
            entry.storage_warning =
              "Skipped Storage download (edge time limit) — saved COF URLs. Use Save COF links only, or python scripts/fetch_club_kits.py for PNG files.";
          } else {
            const kinds = [
              ["home", homeUrl],
              ["away", awayUrl],
              ["third", thirdUrl],
            ] as const;

            for (const [kind, src] of kinds) {
              if (!src || timedOut(deadline)) continue;
              try {
                const { bytes, contentType } = await downloadCofImage(
                  src,
                  fetch,
                  cofCache
                );
                const ext = contentType.includes("gif") ? "gif" : "png";
                const path = `${club.ShortName}/${kind}.${ext}`;
                const { error: upErr } = await adminClient.storage
                  .from(storageBucket)
                  .upload(path, bytes, {
                    contentType,
                    upsert: true,
                  });
                if (upErr) throw upErr;
                const { data: pub } = adminClient.storage
                  .from(storageBucket)
                  .getPublicUrl(path);
                if (kind === "home") homeUrl = pub.publicUrl;
                if (kind === "away") awayUrl = pub.publicUrl;
                if (kind === "third") thirdUrl = pub.publicUrl;
              } catch (storageErr) {
                const msg =
                  storageErr instanceof Error
                    ? storageErr.message
                    : String(storageErr);
                entry.storage_warning =
                  `Storage upload failed (${msg}) — saved COF URL instead. Create public bucket "${storageBucket}".`;
              }
            }
          }
        }

        const { error: saveErr } = await adminClient.from("club_kits").upsert(
          {
            club_short_name: club.ShortName,
            home_image_url: homeUrl,
            away_image_url: awayUrl,
            third_image_url: thirdUrl,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "club_short_name" }
        );

        if (saveErr) throw saveErr;

        entry.ok = true;
        entry.cof = {
          slug: cof.slug,
          nation_folder: cof.nationFolder,
          cof_club_name: cof.cofClubName,
          last_page: cof.lastPage,
          season_label: cof.seasonLabel,
          latest_season_code: cof.latestSeasonCode,
        };
        entry.kits = { home: homeUrl, away: awayUrl, third: thirdUrl };
      } catch (err) {
        entry.error = err instanceof Error ? err.message : String(err);
      }

      results.push(entry);
    }

    const nextOffset = offset + rows.length;
    const done = nextOffset >= totalClubs;

    return jsonResponse({
      ok: true,
      offset,
      limit,
      next_offset: done ? null : nextOffset,
      done,
      total_clubs: totalClubs,
      season_start_year: seasonStartYear,
      results,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
