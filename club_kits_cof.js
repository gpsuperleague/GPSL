/** Colours-of-Football.com kit lookup — shared by edge function + local sync script */

export const COF_BASE = "https://www.colours-of-football.com";
export const COF_COLOURS = `${COF_BASE}/colours03`;

/** GPSL Clubs.Nation (normalized) → COF folder + index page */
export const COF_NATION_MAP = {
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
export const COF_CLUB_SLUG_OVERRIDES = {
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
export const COF_CLUB_PATH_OVERRIDES = {
  WOL: { slug: "wolverhmp", pageStem: "wolves" },
};

const USER_AGENT =
  "Mozilla/5.0 (compatible; GPSL-KitSync/1.0; +https://github.com/gpsl)";

const COF_MIN_GAP_MS = 900;
const COF_MAX_RETRIES = 4;
const COF_MAX_BACKOFF_MS = 8000;

export function createCofFetchCache() {
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
export function seasonCodeToStartYear(code) {
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
export function seasonCodeFromYearPair(y1Text, y2Text) {
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

export function normalizeNationKey(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

export function normalizeClubName(value) {
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

export function cofNationConfig(nation) {
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

export function parseCofIndexLinks(html) {
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

export function matchCofClubLink(links, clubName) {
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
export function findLatestSeasonFromHtml(html) {
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
export function formatSeasonCode(code) {
  if (!code) return null;
  const y1 = seasonCodeToStartYear(code);
  const y2 = y1 + 1;
  return `${y1}-${String(y2).slice(-2)}`;
}

/** European season start year (Jul–Jun): e.g. Jun 2026 → 2025 for 2025-26. */
export function currentKitSeasonStartYear(now = new Date()) {
  const y = now.getFullYear();
  const m = now.getMonth() + 1;
  return m >= 7 ? y : y - 1;
}

/** 2024 → 2425 */
export function startYearToSeasonCode(startYear) {
  const y1 = Number(startYear);
  if (!Number.isFinite(y1) || y1 < 1990 || y1 > 2040) return null;
  const y2 = y1 + 1;
  const code = Number(String(y1).slice(-2) + String(y2).slice(-2));
  return isPlausibleKitSeasonCode(code) ? code : null;
}

export function seasonStartFromKitUrl(url) {
  const m = String(url || "").match(/_(\d)_(\d{4})(?:_\d+)?\.(?:png|gif)/i);
  return m ? Number(m[2]) : 0;
}

export function maxSeasonStartFromKitUrls(kits) {
  let max = 0;
  for (const url of [kits?.home, kits?.away, kits?.third]) {
    max = Math.max(max, seasonStartFromKitUrl(url));
  }
  return max;
}

export function countKitUrls(kits) {
  return [kits?.home, kits?.away, kits?.third].filter(Boolean).length;
}

function parseKitCandidatesFromHtml(html, pageUrl) {
  const buckets = { home: [], away: [], third: [] };

  for (const m of html.matchAll(/src="([^"]+\.(?:png|gif))"/gi)) {
    const src = m[1];
    const file = src.split("/").pop() || "";
    const km = file.match(/_(\d)_(\d{4})(?:_(\d+))?\.(?:png|gif)$/i);
    if (!km) continue;

    const kitNum = Number(km[1]);
    const season = Number(km[2]);
    const variant = km[3] ? Number(km[3]) : 0;
    if (kitNum < 1 || kitNum > 3 || !Number.isFinite(season)) continue;

    const kind = ["home", "away", "third"][kitNum - 1];
    buckets[kind].push({
      season,
      variant,
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
    const filtered = candidates.filter((x) => x.season === year);
    if (filtered.length) {
      filtered.sort(
        (a, b) => a.variant - b.variant || a.file.localeCompare(b.file)
      );
      return filtered[0].url;
    }
    if (strict) return null;
  }

  const maxSeason = Math.max(...candidates.map((x) => x.season));
  const top = candidates.filter((x) => x.season === maxSeason);
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
  const seasonFromUrl = (url) => {
    const m = String(url || "").match(/_(\d)_(\d{4})(?:_\d+)?\.(?:png|gif)$/i);
    return m ? Number(m[2]) : 0;
  };
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

export async function fetchCofHtml(url, fetchImpl = fetch, cache = null) {
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

export async function findLastCofClubPage(
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

export async function resolveCofClubLink(
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

export async function fetchLatestCofKits(
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

export async function downloadCofImage(url, fetchImpl = fetch, cache = null) {
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
