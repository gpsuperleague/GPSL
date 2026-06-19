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
  MUN: "manutd",
  MCI: "man_city",
  TOT: "tottenham",
  WOL: "wolverhampton",
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
};

const USER_AGENT =
  "Mozilla/5.0 (compatible; GPSL-KitSync/1.0; +https://github.com/gpsl)";

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
    /<a[^>]+href="([^"#?]+\/[^"#?]+_1\.html)"[^>]*>([\s\S]*?)<\/a>/gi
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
      pageStem: parts[1].replace(/_1\.html$/i, ""),
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

function pickLatestKitUrl(candidates) {
  if (!candidates.length) return null;
  const maxSeason = Math.max(...candidates.map((x) => x.season));
  const top = candidates.filter((x) => x.season === maxSeason);
  top.sort(
    (a, b) => a.variant - b.variant || a.file.localeCompare(b.file)
  );
  return top[0]?.url ?? null;
}

function pickLatestKits(buckets) {
  return {
    home: pickLatestKitUrl(buckets.home),
    away: pickLatestKitUrl(buckets.away),
    third: pickLatestKitUrl(buckets.third),
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

export async function fetchCofHtml(url, fetchImpl = fetch) {
  const res = await fetchImpl(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "text/html" },
  });
  if (!res.ok) {
    throw new Error(`COF fetch failed (${res.status}): ${url}`);
  }
  return res.text();
}

export async function findLastCofClubPage(
  nationFolder,
  slug,
  pageStem,
  fetchImpl = fetch
) {
  let last = 1;
  for (let page = 1; page <= 12; page += 1) {
    const url = `${COF_COLOURS}/${nationFolder}/${slug}/${pageStem}_${page}.html`;
    const res = await fetchImpl(url, {
      method: "HEAD",
      headers: { "User-Agent": USER_AGENT },
    });
    if (res.ok) last = page;
    else break;
  }
  return last;
}

export async function resolveCofClubLink(
  nation,
  clubName,
  clubShort = null,
  fetchImpl = fetch
) {
  const overrideSlug = clubShort ? COF_CLUB_SLUG_OVERRIDES[clubShort] : null;
  const cfg = cofNationConfig(nation);
  if (!cfg) return { error: `No COF mapping for nation: ${nation}` };

  const indexUrl = `${COF_COLOURS}/${cfg.folder}/${cfg.index}`;
  const indexHtml = await fetchCofHtml(indexUrl, fetchImpl);
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
  fetchImpl = fetch
) {
  const resolved = await resolveCofClubLink(
    nation,
    clubName,
    clubShort,
    fetchImpl
  );
  if (resolved.error) return resolved;

  const { nationFolder, slug, pageStem } = resolved;
  const lastPage = await findLastCofClubPage(
    nationFolder,
    slug,
    pageStem,
    fetchImpl
  );

  let buckets = { home: [], away: [], third: [] };

  for (let page = 1; page <= lastPage; page += 1) {
    const pageUrl = `${COF_COLOURS}/${nationFolder}/${slug}/${pageStem}_${page}.html`;
    const html = await fetchCofHtml(pageUrl, fetchImpl);
    buckets = mergeKitBuckets(
      buckets,
      parseKitCandidatesFromHtml(html, pageUrl)
    );
  }

  const kits = pickLatestKits(buckets);

  return {
    ...resolved,
    lastPage,
    kits,
    source: "colours-of-football.com",
  };
}

export async function downloadCofImage(url, fetchImpl = fetch) {
  const res = await fetchImpl(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "image/*" },
  });
  if (!res.ok) throw new Error(`Image download failed (${res.status}): ${url}`);
  const buf = await res.arrayBuffer();
  const type = res.headers.get("content-type") || "image/png";
  return { bytes: new Uint8Array(buf), contentType: type };
}
