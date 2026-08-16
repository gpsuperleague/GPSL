// GPSL club-stadiums-sync — single file for Supabase Dashboard deploy
// Re-bundle: python scripts/bundle_club_stadiums_edge.py

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/** StadiumDB lookup — shared by edge function + local fetch script (no fs). */

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
  wales: "wal",
  ireland: "irl",
  "northern ireland": "nir",
  turkiye: "tur",
  unitedstates: "usa",
  united_states: "usa",
  morocco: "mar",
};

/** Manual overrides when auto-slug fails (ShortName → stadiumdb path after /stadiums/) */
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
  // DAN (Danubio) — StadiumDB Uruguay list is thin; use IMAGE_URL_OVERRIDES when needed
  // Morocco — nation code was missing; pin StadiumDB slugs
  RCA: "mar/stade_mohammed_v",
  HSA: "mar/grand_stade_agadir",
};

/** Direct image URL when page HTML has no parseable picture (ShortName → jpg URL) */
const IMAGE_URL_OVERRIDES = {
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
  // Gamla Ullevi images live under /pictures/historical/ on StadiumDB
  IFK: "https://stadiumdb.com/pictures/historical/swe/gamla_ullevi_2007/gamla_ullevi01.jpg",
  // Danubio — not listed on StadiumDB Uruguay; Wikimedia Commons photo
  DAN: "https://upload.wikimedia.org/wikipedia/commons/0/01/Jardines_del_hipodromo.jpg",
  // Morocco (Raja / Hassania) — force a clean gallery shot
  RCA: "https://stadiumdb.com/pictures/stadiums/mar/stade_mohammed_v/stade_mohammed_v34.jpg",
  HSA: "https://stadiumdb.com/pictures/stadiums/mar/grand_stade_agadir/grand_stade_agadir09.jpg",
};

const UA = "GPSL-StadiumSync/1.0 (personal league project)";

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

function extractImageUrl(html) {
  // Prefer current galleries; also accept historical / pic-buildings / pic-projects.
  const urls = [
    ...String(html || "").matchAll(
      /https:\/\/stadiumdb\.com\/(?:pictures\/(?:stadiums|historical)|pic-buildings|pic-projects)\/[a-z0-9_/.-]+\.jpg/gi
    ),
  ].map((m) => m[0]);

  const prefer = (list) =>
    list.find((u) => u.includes("/pictures/stadiums/")) ||
    list.find((u) => u.includes("/pic-buildings/")) ||
    list.find((u) => u.includes("/pic-projects/")) ||
    list.find((u) => u.includes("/pictures/historical/")) ||
    list[0];

  const full = prefer(urls.filter((u) => !u.endsWith("m.jpg")));
  if (full) return full;

  const thumb = prefer(urls.filter((u) => u.endsWith("m.jpg")));
  if (thumb) return thumb.replace(/m\.jpg$/i, ".jpg");
  return null;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function slugCandidates(name) {
  const base = slugify(name);
  if (!base) return [];
  const out = [base];
  const stripped = base
    .replace(/_stadium$/, "")
    .replace(/_arena$/, "")
    .replace(/_park$/, "")
    .replace(/_ground$/, "")
    .replace(/_fc$/, "")
    .replace(/_cf$/, "")
    .replace(/_afc$/, "")
    .replace(/^afc_/, "")
    .replace(/_sc$/, "")
    .replace(/^ac_/, "")
    .replace(/_ac$/, "");
  if (stripped && stripped !== base) out.push(stripped);
  return [...new Set(out)];
}

/** Prefer Stadium, then Club — both help StadiumDB matching. */
function lookupNames(club) {
  const names = [];
  const stadium = String(club?.Stadium || "").trim();
  const clubName = String(club?.Club || club?.club_name || "").trim();
  if (stadium) names.push(stadium);
  if (clubName && clubName.toLowerCase() !== stadium.toLowerCase()) {
    names.push(clubName);
  }
  return names;
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

/**
 * Score country-index links against stadium and/or club name tokens.
 * @param {string|string[]} queryNames
 */
async function searchCountryIndex(queryNames, country, fetchImpl) {
  const names = (Array.isArray(queryNames) ? queryNames : [queryNames])
    .map((n) => String(n || "").trim())
    .filter(Boolean);
  if (!names.length) return null;

  const html = await fetchPageHtml(
    `https://stadiumdb.com/stadiums/${country}/`,
    fetchImpl
  );
  if (!html) return null;

  const tokenSets = names.map((name) =>
    slugify(name)
      .split("_")
      .filter((t) => t.length > 2 && !["fc", "cf", "afc", "sc", "ac"].includes(t))
  );
  const nameSlugs = names.flatMap((n) => slugCandidates(n));

  const re =
    /href="(https:\/\/stadiumdb\.com\/stadiums\/[a-z]{3}\/[^"]+)"[^>]*>([^<]+)<\/a>/gi;
  let best = null;
  let bestScore = 0;
  let m;
  while ((m = re.exec(html))) {
    const href = m[1];
    const label = slugify(m[2]);
    const hrefSlug = slugify(href.split("/").pop() || "");
    let score = 0;

    for (const slug of nameSlugs) {
      if (label === slug || hrefSlug === slug) score = Math.max(score, 40 + slug.length);
      else if (label.includes(slug) || hrefSlug.includes(slug)) {
        score = Math.max(score, 12 + slug.length);
      }
    }

    for (const tokens of tokenSets) {
      let setScore = 0;
      for (const t of tokens) {
        if (label.includes(t) || hrefSlug.includes(t)) setScore += t.length;
      }
      score = Math.max(score, setScore);
    }

    if (score > bestScore) {
      bestScore = score;
      best = href;
    }
  }
  return bestScore >= 5 ? best : null;
}

/**
 * @param {{ ShortName?: string, Club?: string, Stadium?: string, Nation?: string }} club
 * @param {{ fetchImpl?: typeof fetch, cache?: Record<string, { pageUrl?: string }> }} [opts]
 */
async function resolveStadiumPageUrl(club, opts = {}) {
  const fetchImpl = opts.fetchImpl || fetch;
  const cache = opts.cache || {};
  const short = String(club?.ShortName || "").trim();

  if (short && cache[short]?.pageUrl) return cache[short].pageUrl;
  if (short && SLUG_OVERRIDES[short]) {
    return `https://stadiumdb.com/stadiums/${SLUG_OVERRIDES[short]}`;
  }

  const country = nationCode(club?.Nation);
  const names = lookupNames(club);
  if (!country || !names.length) return null;

  const fromIndex = await searchCountryIndex(names, country, fetchImpl);
  if (fromIndex) return fromIndex;

  const tried = new Set();
  for (const name of names) {
    for (const slug of slugCandidates(name)) {
      if (tried.has(slug)) continue;
      tried.add(slug);
      const pageUrl = `https://stadiumdb.com/stadiums/${country}/${slug}`;
      if (await pageExists(pageUrl, fetchImpl)) return pageUrl;
      await sleep(400);
    }
  }
  return null;
}

/**
 * Resolve StadiumDB page + image; optionally download bytes.
 * @param {{ ShortName?: string, Club?: string, Stadium?: string, Nation?: string }} club
 * @param {{ fetchImpl?: typeof fetch, cache?: Record<string, unknown>, skipBytes?: boolean }} [opts]
 * @returns {Promise<{ pageUrl: string|null, imageUrl: string|null, bytes: Uint8Array|null, error: string|null }>}
 */
async function fetchStadiumImage(club, opts = {}) {
  const fetchImpl = opts.fetchImpl || fetch;
  const skipBytes = opts.skipBytes === true;

  try {
    const short = String(club?.ShortName || "").trim();
    const names = lookupNames(club);
    if (!names.length) {
      return {
        pageUrl: null,
        imageUrl: null,
        bytes: null,
        error: "no Stadium or Club name in DB",
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
          error: `no StadiumDB page (tried: ${names.join(" / ")})`,
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

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const INVOCATION_BUDGET_MS = 50_000;
const STADIUM_FETCH_DELAY_MS = 800;

const GITHUB_OWNER = Deno.env.get("GITHUB_OWNER") || "gpsuperleague";
const GITHUB_REPO = Deno.env.get("GITHUB_REPO") || "GPSL";
const GITHUB_BRANCH = Deno.env.get("GITHUB_BRANCH") || "main";

function timedOut(deadline: number) {
  return Math.max(0, deadline - Date.now()) < 3000;
}

function githubToken(): string | null {
  return Deno.env.get("GITHUB_TOKEN") ?? Deno.env.get("GPSL_GITHUB_TOKEN") ?? null;
}

function githubHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "GPSL-StadiumSync/1.0",
  };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function repoStadiumPath(clubShort: string): string {
  return `images/stadiums/${clubShort}.jpg`;
}

function repoBadgePath(clubShort: string): string {
  return `images/club_badges/${clubShort}.png`;
}

async function sleepMs(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

async function githubFileExists(
  token: string,
  path: string
): Promise<boolean> {
  const api =
    `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/` +
    `${encodeURI(path)}?ref=${GITHUB_BRANCH}`;
  const res = await fetch(api, { headers: githubHeaders(token) });
  return res.ok;
}

async function githubCommitRepoFile(
  token: string,
  repoPath: string,
  bytes: Uint8Array,
  commitMessage: string
): Promise<{ path: string; commitSha: string }> {
  let lastErr: Error | null = null;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const api = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}`;

      const headRes = await fetch(`${api}/git/ref/heads/${GITHUB_BRANCH}`, {
        headers: githubHeaders(token),
      });
      if (!headRes.ok) {
        throw new Error(`GitHub ref failed (${headRes.status})`);
      }
      const headRef = await headRes.json();
      const headCommitSha = headRef.object.sha as string;

      const commitMetaRes = await fetch(`${api}/git/commits/${headCommitSha}`, {
        headers: githubHeaders(token),
      });
      if (!commitMetaRes.ok) {
        throw new Error(`GitHub commit read failed (${commitMetaRes.status})`);
      }
      const commitMeta = await commitMetaRes.json();
      const baseTreeSha = commitMeta.tree.sha as string;

      const blobRes = await fetch(`${api}/git/blobs`, {
        method: "POST",
        headers: {
          ...githubHeaders(token),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          content: bytesToBase64(bytes),
          encoding: "base64",
        }),
      });
      if (!blobRes.ok) {
        throw new Error(`GitHub blob failed (${blobRes.status})`);
      }
      const blob = await blobRes.json();

      const treeRes = await fetch(`${api}/git/trees`, {
        method: "POST",
        headers: {
          ...githubHeaders(token),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          base_tree: baseTreeSha,
          tree: [
            {
              path: repoPath,
              mode: "100644",
              type: "blob",
              sha: blob.sha as string,
            },
          ],
        }),
      });
      if (!treeRes.ok) {
        throw new Error(`GitHub tree failed (${treeRes.status})`);
      }
      const newTree = await treeRes.json();

      const newCommitRes = await fetch(`${api}/git/commits`, {
        method: "POST",
        headers: {
          ...githubHeaders(token),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: commitMessage,
          tree: newTree.sha,
          parents: [headCommitSha],
        }),
      });
      if (!newCommitRes.ok) {
        throw new Error(`GitHub commit failed (${newCommitRes.status})`);
      }
      const newCommit = await newCommitRes.json();

      const updateRefRes = await fetch(
        `${api}/git/refs/heads/${GITHUB_BRANCH}`,
        {
          method: "PATCH",
          headers: {
            ...githubHeaders(token),
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ sha: newCommit.sha }),
        }
      );
      if (!updateRefRes.ok) {
        throw new Error(`GitHub ref update failed (${updateRefRes.status})`);
      }

      return { path: repoPath, commitSha: newCommit.sha as string };
    } catch (err) {
      lastErr = err instanceof Error ? err : new Error(String(err));
      if (attempt < 2) {
        await sleepMs(1500 * (attempt + 1));
      }
    }
  }

  throw lastErr || new Error("GitHub commit failed");
}

async function githubCommitStadiumImage(
  token: string,
  clubShort: string,
  bytes: Uint8Array
): Promise<{ path: string; commitSha: string }> {
  return githubCommitRepoFile(
    token,
    repoStadiumPath(clubShort),
    bytes,
    `Update ${clubShort} stadium image`
  );
}

type ClubRow = {
  ShortName: string;
  Club: string;
  Stadium: string | null;
  Nation: string | null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  try {
    return await handleClubStadiumsSync(req);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});

async function handleClubStadiumsSync(req: Request): Promise<Response> {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey =
      Deno.env.get("SUPABASE_ANON_KEY") ?? req.headers.get("apikey") ?? "";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "sync_batch");

    if (action === "ping") {
      return jsonResponse({ ok: true, pong: true, ts: Date.now() });
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
    if (adminError || !isAdmin) {
      return jsonResponse({ error: "Admin only" }, 403);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const deadline = Date.now() + INVOCATION_BUDGET_MS;
    const ghToken = githubToken();

    if (action === "upload_club_badge") {
      const short = String(body?.club_short_name || "").trim().toUpperCase();
      if (!short) {
        return jsonResponse({ error: "club_short_name required" }, 400);
      }

      const { data: club, error: clubErr } = await adminClient
        .from("Clubs")
        .select("ShortName")
        .eq("ShortName", short)
        .maybeSingle();
      if (clubErr || !club) {
        return jsonResponse({ error: `Club not found: ${short}` }, 404);
      }

      let raw = String(body?.image_base64 || "").trim();
      if (!raw) return jsonResponse({ error: "image_base64 required" }, 400);
      if (raw.includes(",")) raw = raw.split(",")[1] || raw;
      raw = raw.replace(/\s/g, "");

      let bytes: Uint8Array;
      try {
        bytes = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
      } catch {
        return jsonResponse({ error: "Invalid image_base64" }, 400);
      }
      if (bytes.length < 32) {
        return jsonResponse({ error: "Image data too small" }, 400);
      }
      if (bytes.length > 4_000_000) {
        return jsonResponse({ error: "Image too large (max ~4MB)" }, 400);
      }

      // PNG signature
      if (
        bytes.length < 8 ||
        bytes[0] !== 0x89 ||
        bytes[1] !== 0x50 ||
        bytes[2] !== 0x4e ||
        bytes[3] !== 0x47
      ) {
        return jsonResponse(
          { error: "Badge must be PNG (convert SVG in the admin UI first)" },
          400
        );
      }

      if (!ghToken) {
        return jsonResponse(
          {
            error:
              "GITHUB_TOKEN not set — add a GitHub PAT with repo contents write access in Supabase → Edge Functions → Secrets.",
          },
          400
        );
      }

      const { path, commitSha } = await githubCommitRepoFile(
        ghToken,
        repoBadgePath(short),
        bytes,
        `Update ${short} club badge`
      );

      return jsonResponse({
        ok: true,
        club_short_name: short,
        path,
        github: { commit_sha: commitSha },
      });
    }

    if (action === "preview") {
      const short = String(body?.club_short_name || "").trim().toUpperCase();
      if (!short) {
        return jsonResponse({ error: "club_short_name required" }, 400);
      }

      const { data: club, error } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Stadium, Nation")
        .eq("ShortName", short)
        .maybeSingle();

      if (error || !club) {
        return jsonResponse({ error: `Club not found: ${short}` }, 404);
      }

      const result = await fetchStadiumImage(club as ClubRow, {
        fetchImpl: fetch,
        skipBytes: true,
      });
      return jsonResponse({
        ok: !result.error,
        club,
        page_url: result.pageUrl,
        image_url: result.imageUrl,
        error: result.error,
      });
    }

    if (action === "preview_freeform") {
      const clubName = String(body?.club_name || body?.Club || "").trim();
      const stadium = String(body?.stadium || body?.Stadium || "").trim();
      const nation = String(body?.nation || body?.Nation || "").trim();
      if (!nation) {
        return jsonResponse({ error: "nation required" }, 400);
      }
      if (!stadium && !clubName) {
        return jsonResponse(
          { error: "stadium or club_name required" },
          400
        );
      }

      const club = {
        ShortName: String(body?.club_short_name || "").trim().toUpperCase(),
        Club: clubName || stadium,
        Stadium: stadium || null,
        Nation: nation,
      };

      const result = await fetchStadiumImage(club as ClubRow, {
        fetchImpl: fetch,
        skipBytes: true,
      });
      return jsonResponse({
        ok: !result.error,
        club,
        page_url: result.pageUrl,
        image_url: result.imageUrl,
        error: result.error,
      });
    }

    if (action === "sync_one") {
      const short = String(body?.club_short_name || "").trim().toUpperCase();
      if (!short) {
        return jsonResponse({ error: "club_short_name required" }, 400);
      }

      const { data: club, error } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Stadium, Nation")
        .eq("ShortName", short)
        .maybeSingle();

      if (error || !club) {
        return jsonResponse({ error: `Club not found: ${short}` }, 404);
      }

      const entry = await syncClubStadium(club as ClubRow, {
        ghToken,
        deadline,
        onlyMissing: false,
      });
      return jsonResponse({
        ok: true,
        results: [entry],
        done: true,
        next_offset: null,
      });
    }

    if (action !== "sync_batch") {
      return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }

    const offset = Math.max(0, Number(body?.offset) || 0);
    const limit = Math.min(3, Math.max(1, Number(body?.limit) || 1));
    const onlyMissing = body?.only_missing === true;

    const clubShortNames = Array.isArray(body?.club_short_names)
      ? body.club_short_names
          .map((s: unknown) => String(s ?? "").trim().toUpperCase())
          .filter(Boolean)
      : null;

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
        });
      }

      const { data: clubs, error: clubsError } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Stadium, Nation")
        .in("ShortName", slice)
        .order("ShortName");

      if (clubsError) {
        return jsonResponse({ error: clubsError.message }, 500);
      }

      rows = (clubs || []) as ClubRow[];
      totalClubs = clubShortNames.length;
    } else {
      const { data: clubs, error: clubsError } = await adminClient
        .from("Clubs")
        .select("ShortName, Club, Stadium, Nation")
        .neq("ShortName", "FOREIGN")
        .not("Stadium", "is", null)
        .neq("Stadium", "")
        .order("ShortName")
        .range(offset, offset + limit - 1);

      if (clubsError) {
        return jsonResponse({ error: clubsError.message }, 500);
      }

      rows = (clubs || []) as ClubRow[];

      const { count } = await adminClient
        .from("Clubs")
        .select("*", { count: "exact", head: true })
        .neq("ShortName", "FOREIGN")
        .not("Stadium", "is", null)
        .neq("Stadium", "");

      totalClubs = count || 0;
    }

    const results: Record<string, unknown>[] = [];

    for (const club of rows) {
      if (timedOut(deadline)) {
        results.push({
          short_name: club.ShortName,
          ok: false,
          error: "Edge time limit — retry this club.",
        });
        continue;
      }

      const entry = await syncClubStadium(club, {
        ghToken,
        deadline,
        onlyMissing,
      });
      results.push(entry);
      await sleepMs(STADIUM_FETCH_DELAY_MS);
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
      results,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
}

async function syncClubStadium(
  club: ClubRow,
  opts: {
    ghToken: string | null;
    deadline: number;
    onlyMissing: boolean;
  }
): Promise<Record<string, unknown>> {
  const entry: Record<string, unknown> = {
    short_name: club.ShortName,
    club_name: club.Club,
    stadium: club.Stadium,
    nation: club.Nation,
    ok: false,
  };

  try {
    if (
      !club.Stadium?.toString().trim() &&
      !club.Club?.toString().trim()
    ) {
      entry.error = "no Stadium or Club name in DB";
      return entry;
    }

    if (opts.onlyMissing) {
      if (!opts.ghToken) {
        entry.error =
          "GITHUB_TOKEN not set — required to check existing stadium files.";
        return entry;
      }
      const exists = await githubFileExists(
        opts.ghToken,
        repoStadiumPath(club.ShortName)
      );
      if (exists) {
        entry.ok = true;
        entry.skipped = true;
        entry.reason = "stadium image already on GitHub";
        return entry;
      }
    }

    if (!opts.ghToken) {
      entry.error =
        "GITHUB_TOKEN not set — add a GitHub PAT with repo contents write access in Supabase → Edge Functions → Secrets.";
      return entry;
    }

    if (timedOut(opts.deadline)) {
      entry.error = "Edge time limit — retry this club.";
      return entry;
    }

    const fetched = await fetchStadiumImage(club, { fetchImpl: fetch });
    entry.page_url = fetched.pageUrl;
    entry.image_url = fetched.imageUrl;

    if (fetched.error || !fetched.bytes) {
      entry.error = fetched.error || "no image bytes";
      return entry;
    }

    const { path, commitSha } = await githubCommitStadiumImage(
      opts.ghToken,
      club.ShortName,
      fetched.bytes
    );
    entry.ok = true;
    entry.github = { path, commit_sha: commitSha };
  } catch (err) {
    entry.error = err instanceof Error ? err.message : String(err);
  }

  return entry;
}
