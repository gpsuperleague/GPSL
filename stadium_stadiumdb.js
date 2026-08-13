/** StadiumDB lookup — shared by edge function + local fetch script (no fs). */

export const NATION_TO_CODE = {
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
  wales: "wal",
  ireland: "irl",
  "northern ireland": "nir",
  turkiye: "tur",
  unitedstates: "usa",
  united_states: "usa",
};

/** Manual overrides when auto-slug fails (ShortName → stadiumdb path after /stadiums/) */
export const SLUG_OVERRIDES = {
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
  AJX: "ned/arena",
  BAR: "esp/camp_nou",
  RMA: "esp/nuevo_santiago_bernabeu",
  ATM: "esp/estadio_metropolitano",
  VAL: "esp/ciutat_de_valencia",
  SEV: "esp/ramon_sanchez_pizjuan",
  JUV: "ita/juventus_stadium",
  INT: "ita/stadio_giuseppe_meazza",
  MIL: "ita/giuseppe_meazza",
  LAZ: "ita/stadio_olimpico",
  ROM: "ita/stadio_olimpico",
  NAP: "ita/diego_armando_maradona",
  DOR: "ger/westfalenstadion",
  LEV: "ger/bayarena",
  BMU: "ger/allianz_arena",
  PSG: "fra/parc_des_princes",
  LYO: "fra/parc_ol",
  MAR: "fra/stade_velodrome",
  LIL: "fra/stadium_lille_metropole",
  MON: "fra/stade_louis_ii",
  POR: "por/estadio_do_dragao",
  BEN: "por/estadio_da_luz",
  SPO: "por/estadio_jose_alvalade",
  BRU: "bel/jan_breydel",
  AND: "bel/constant_vanden_stock",
  CEL: "sco/celtic_park",
  RAN: "sco/ibrox_stadium",
  FLA: "bra/maracana",
  COR: "bra/arena_corinthians",
  PAL: "bra/allianz_parque",
  SAN: "bra/vila_belmiro",
  BOC: "arg/la_bombonera",
  RIV: "arg/el_monumental",
  IND: "arg/estadio_libertadores_de_america",
  NAC: "col/estadio_atanasio_girardot",
  SOA: "civ/stade_de_yamoussoukro",
  WOL: "eng/molineux_stadium",
  BET: "esp/estadio_benito_villamarin",
  VIL: "esp/el_madrigal",
  FIO: "ita/stadio_artemio_franchi",
  COP: "den/parken",
  BES: "tur/vodafone_arena",
  KAS: "tur/recep_tayyip_erdogan_stadi",
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
  // IFK Göteborg — Gamla Ullevi
  IFK: "swe/gamla_ullevi",
  // DAN (Danubio / Jardines del Hipódromo) — not on StadiumDB; leave for auto / manual later
};

/** Direct image URL when page HTML has no parseable picture (ShortName → jpg URL) */
export const IMAGE_URL_OVERRIDES = {
  AJX: "https://stadiumdb.com/pictures/stadiums/ned/arena/arena41.jpg",
  AND: "https://stadiumdb.com/pictures/stadiums/bel/constant_vanden_stock/constant_vanden_stock24.jpg",
  BES: "https://stadiumdb.com/pictures/stadiums/tur/vodafone_arena/vodafone_arena03.jpg",
  BET: "https://stadiumdb.com/pic-buildings/esp/estadio_benito_villamarin/estadio_benito_villamarin102.jpg",
  BRU: "https://stadiumdb.com/pic-projects/club_brugge_stadion/club_brugge_stadion28.jpg",
  COP: "https://www.fck.dk/sites/default/files/styles/article_full/public/2020-04/200419_teliaparken_luftfoto-2.jpg?itok=UuTpSNfJ",
  FIO: "https://stadiumdb.com/img/news/2025/09/33Fra01.jpg",
  INT: "https://stadiumdb.com/img/news/2024/10/93San01.jpg",
  JUV: "https://stadiumdb.com/pictures/stadiums/ita/juventus_stadium/juventus_stadium13.jpg",
  KAS: "https://stadiumdb.com/pictures/stadiums/tur/recep_tayyip_erdogan_stadi/recep_tayyip_erdogan_stadi21.jpg",
  LAZ: "https://stadiumdb.com/img/news/2026/05/24Fla03.jpg",
  LIL: "https://stadiumdb.com/pictures/stadiums/fra/stadium_lille_metropole/stadium_lille_metropole10.jpg",
  LYO: "https://stadiumdb.com/pictures/stadiums/fra/parc_ol/parc_ol11.jpg",
  NAC: "https://stadiumdb.com/pic-projects/estadio_atanasio_girardot/estadio_atanasio_girardot05.jpg",
  SOA: "https://commons.wikimedia.org/wiki/Special:FilePath/Le_stade_de_Yamoussoukro(Bosson).jpg",
  RMA: "https://stadiumdb.com/pictures/stadiums/esp/nuevo_santiago_bernabeu/nuevo_santiago_bernabeu24.jpg",
  SAN: "https://stadiumdb.com/img/news/2025/08/58Cal02.jpg",
  VAL: "https://stadiumdb.com/pictures/stadiums/esp/ciutat_de_valencia/ciutat_de_valencia28.jpg",
  VIL: "https://stadiumdb.com/pictures/stadiums/esp/el_madrigal/el_madrigal29.jpg",
};

const UA = "GPSL-StadiumSync/1.0 (personal league project)";

export function slugify(text) {
  return String(text || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export function nationCode(nation) {
  const raw = slugify(nation);
  const spaced = raw.replace(/_/g, " ");
  return NATION_TO_CODE[spaced] || NATION_TO_CODE[raw] || null;
}

export function extractImageUrl(html) {
  const urls = [
    ...String(html || "").matchAll(
      /https:\/\/stadiumdb\.com\/pictures\/stadiums\/[a-z0-9_/]+\.jpg/gi
    ),
  ].map((m) => m[0]);

  const full = urls.find((u) => !u.endsWith("m.jpg"));
  if (full) return full;

  const thumb = urls.find((u) => u.endsWith("m.jpg"));
  if (thumb) return thumb.replace(/m\.jpg$/i, ".jpg");
  return null;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
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

async function fetchPageHtml(pageUrl, fetchImpl) {
  const res = await fetchImpl(pageUrl, {
    headers: { "User-Agent": UA },
  });
  if (!res.ok) return null;
  return res.text();
}

async function pageExists(pageUrl, fetchImpl) {
  const html = await fetchPageHtml(pageUrl, fetchImpl);
  if (!html) return false;
  return !html.includes("404") && html.includes("stadiumdb.com");
}

async function searchCountryIndex(stadiumName, country, fetchImpl) {
  const html = await fetchPageHtml(
    `https://stadiumdb.com/stadiums/${country}/`,
    fetchImpl
  );
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

/**
 * @param {{ ShortName?: string, Stadium?: string, Nation?: string }} club
 * @param {{ fetchImpl?: typeof fetch, cache?: Record<string, { pageUrl?: string }> }} [opts]
 */
export async function resolveStadiumPageUrl(club, opts = {}) {
  const fetchImpl = opts.fetchImpl || fetch;
  const cache = opts.cache || {};
  const short = String(club?.ShortName || "").trim();

  if (short && cache[short]?.pageUrl) return cache[short].pageUrl;
  if (short && SLUG_OVERRIDES[short]) {
    return `https://stadiumdb.com/stadiums/${SLUG_OVERRIDES[short]}`;
  }

  const country = nationCode(club?.Nation);
  if (!country || !club?.Stadium) return null;

  const fromIndex = await searchCountryIndex(club.Stadium, country, fetchImpl);
  if (fromIndex) return fromIndex;

  for (const slug of slugCandidates(club.Stadium)) {
    const pageUrl = `https://stadiumdb.com/stadiums/${country}/${slug}`;
    if (await pageExists(pageUrl, fetchImpl)) return pageUrl;
    await sleep(400);
  }
  return null;
}

/**
 * Resolve StadiumDB page + image; optionally download bytes.
 * @param {{ ShortName?: string, Stadium?: string, Nation?: string }} club
 * @param {{ fetchImpl?: typeof fetch, cache?: Record<string, unknown>, skipBytes?: boolean }} [opts]
 * @returns {Promise<{ pageUrl: string|null, imageUrl: string|null, bytes: Uint8Array|null, error: string|null }>}
 */
export async function fetchStadiumImage(club, opts = {}) {
  const fetchImpl = opts.fetchImpl || fetch;
  const skipBytes = opts.skipBytes === true;

  try {
    const short = String(club?.ShortName || "").trim();
    if (!club?.Stadium?.toString().trim()) {
      return {
        pageUrl: null,
        imageUrl: null,
        bytes: null,
        error: "no Stadium name in DB",
      };
    }

    const forcedImage = short ? IMAGE_URL_OVERRIDES[short] : null;
    let pageUrl = await resolveStadiumPageUrl(club, opts);
    let imageUrl = forcedImage || null;

    if (!imageUrl) {
      if (!pageUrl) {
        return {
          pageUrl: null,
          imageUrl: null,
          bytes: null,
          error: "no StadiumDB page",
        };
      }
      const html = await fetchPageHtml(pageUrl, fetchImpl);
      imageUrl = html ? extractImageUrl(html) : null;
    }

    if (!imageUrl) {
      return {
        pageUrl,
        imageUrl: null,
        bytes: null,
        error: `no picture on ${pageUrl || "(no page)"}`,
      };
    }

    if (!pageUrl && short && SLUG_OVERRIDES[short]) {
      pageUrl = `https://stadiumdb.com/stadiums/${SLUG_OVERRIDES[short]}`;
    }

    if (skipBytes) {
      return { pageUrl, imageUrl, bytes: null, error: null };
    }

    const imgRes = await fetchImpl(imageUrl, {
      headers: { "User-Agent": "GPSL-StadiumSync/1.0" },
    });
    if (!imgRes.ok) {
      return {
        pageUrl,
        imageUrl,
        bytes: null,
        error: `download ${imgRes.status}`,
      };
    }

    const bytes = new Uint8Array(await imgRes.arrayBuffer());
    return { pageUrl, imageUrl, bytes, error: null };
  } catch (err) {
    return {
      pageUrl: null,
      imageUrl: null,
      bytes: null,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
