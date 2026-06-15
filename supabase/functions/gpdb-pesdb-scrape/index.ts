// GPSL — scrape pesdb.net (single file for Supabase Dashboard + CLI deploy)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PLAYING_STYLES = [
  "Goal Poacher", "Dummy Runner", "Fox in the Box", "Prolific Winger",
  "Classic No. 10", "Hole Player", "Box-to-Box", "Anchor Man",
  "The Destroyer", "Extra Frontman", "Offensive Full-back",
  "Defensive Full-back", "Target Man", "Creative Playmaker",
  "Build Up", "Offensive Goalkeeper", "Defensive Goalkeeper",
  "Roaming Flank", "Cross Specialist", "Orchestrator", "Full-back Finisher",
  "Deep-Lying Forward",
];

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const PESDB_BASE = "https://pesdb.net/efootball/";

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function pesdbListUrl(page: number): string {
  if (page <= 1) return PESDB_BASE;
  return `${PESDB_BASE}?page=${page}`;
}

function pesdbPlayerMaxUrl(playerId: string): string {
  return `${PESDB_BASE}?id=${encodeURIComponent(playerId)}&mode=max_level`;
}

function decodeHtml(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .trim();
}

function stripTags(html: string): string {
  return decodeHtml(html.replace(/<[^>]+>/g, " "));
}

function detectPesdbTotals(html: string) {
  const found = html.match(/\((\d+)\s+players found\)/i);
  const totalPlayers = found ? Number(found[1]) : null;
  const pageNums: number[] = [];
  for (const m of html.matchAll(/[?&]page=(\d+)/gi)) {
    const n = Number(m[1]);
    if (Number.isFinite(n)) pageNums.push(n);
  }
  const maxPage = pageNums.length ? Math.max(...pageNums) : null;
  return { totalPlayers, maxPage };
}

type PesdbListRow = {
  konami_id: string;
  player_name: string;
  position: string;
  nationality: string;
  age: number;
  rating: number;
};

function parsePesdbListPage(html: string): PesdbListRow[] {
  const tableMatch = html.match(/<table class="players">([\s\S]*?)<\/table>/i);
  if (!tableMatch) return [];

  const rows: PesdbListRow[] = [];
  const trRe = /<tr>([\s\S]*?)<\/tr>/gi;
  let trMatch: RegExpExecArray | null;

  while ((trMatch = trRe.exec(tableMatch[1])) !== null) {
    const rowHtml = trMatch[1];
    const tds = [...rowHtml.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((m) => m[1]);
    if (tds.length < 8) continue;

    const posMatch =
      tds[0].match(/<div[^>]*title="([^"]+)"[^>]*>([^<]*)<\/div>/i) ||
      tds[0].match(/>([A-Z]{2,3})</);
    const position = decodeHtml(posMatch?.[2] || posMatch?.[1] || tds[0]).slice(0, 8);

    const nameMatch = tds[1].match(/href="[^"]*\?id=([^"&]+)[^"]*"[^>]*>([^<]+)</i);
    if (!nameMatch) continue;

    const konami_id = decodeHtml(nameMatch[1]);
    const player_name = decodeHtml(nameMatch[2]);
    const nationality = stripTags(tds[3]);
    const age = Number(stripTags(tds[6]));
    const rating = Number(stripTags(tds[7]));
    if (!konami_id || !player_name) continue;

    rows.push({
      konami_id,
      player_name,
      position: position || "CF",
      nationality,
      age: Number.isFinite(age) ? age : 25,
      rating: Number.isFinite(rating) ? rating : 60,
    });
  }
  return rows;
}

function parsePesdbMaxLevelPage(html: string) {
  let max_level_rating: number | null = null;
  const overallBlock = html.match(
    /Overall Rating:[\s\S]{0,400}?<span[^>]*>(\d+)<\/span>/i
  );
  if (overallBlock) {
    max_level_rating = Number(overallBlock[1]);
  } else {
    const alt = html.match(/Overall Rating:[\s\S]{0,200}?\(\+\d+\)[^0-9]*(\d{2})/i);
    if (alt) max_level_rating = Number(alt[1]);
  }

  let playing_style = "None";
  const styleBlock = html.match(
    /<tr>\s*<th>\s*Playing Style\s*<\/th>\s*<\/tr>\s*<tr>\s*<td>([^<]+)<\/td>/i
  );
  if (styleBlock) {
    const candidate = decodeHtml(styleBlock[1]);
    if (PLAYING_STYLES.includes(candidate)) {
      playing_style = candidate;
    } else {
      for (const style of PLAYING_STYLES) {
        if (html.includes(`<td>${style}</td>`)) {
          playing_style = style;
          break;
        }
      }
    }
  }

  return {
    max_level_rating: Number.isFinite(max_level_rating) ? max_level_rating : null,
    playing_style,
  };
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms));
}

/** Randomised pause so requests are less bursty. */
async function politePause(baseMs: number, jitterMs = 1500): Promise<void> {
  await sleep(baseMs + Math.floor(Math.random() * jitterMs));
}

/** Fetch with retry on 429/503 and a polite pause after each success. */
async function fetchPesdbHtml(url: string, attempt = 1): Promise<string> {
  const res = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml",
      "Accept-Language": "en-GB,en;q=0.9",
    },
  });

  if ((res.status === 429 || res.status === 503) && attempt < 10) {
    const waitMs = Math.min(300000, 20000 * Math.pow(2, attempt - 1));
    console.warn(`PESDB ${res.status} — retry ${attempt}/9 in ${waitMs}ms: ${url}`);
    await sleep(waitMs);
    return fetchPesdbHtml(url, attempt + 1);
  }

  if (!res.ok) {
    if (res.status === 429) {
      throw new Error(
        "PESDB rate limited (429). Wait 30–60 minutes, then resume or use CSV upload."
      );
    }
    throw new Error(`PESDB fetch failed (${res.status}): ${url}`);
  }

  const text = await res.text();
  await politePause(4500, 3500);
  return text;
}

async function mapWithConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (true) {
      const i = next++;
      if (i >= items.length) break;
      out[i] = await fn(items[i], i);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => worker())
  );
  return out;
}

type ScrapePlayer = PesdbListRow & {
  max_level_rating: number;
  playing_style: string;
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

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

    const { data: isAdmin, error: adminError } = await userClient.rpc("is_gpsl_admin");
    if (adminError || !isAdmin) return jsonResponse({ error: "Admin only" }, 403);

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "scrape_page");

    if (action === "detect") {
      const html = await fetchPesdbHtml(pesdbListUrl(1));
      const { totalPlayers, maxPage } = detectPesdbTotals(html);
      const estimatedPages = totalPlayers
        ? Math.max(1, Math.ceil(totalPlayers / 30))
        : maxPage ?? 100;
      return jsonResponse({
        ok: true,
        total_players: totalPlayers,
        max_page_link: maxPage,
        estimated_pages: estimatedPages,
      });
    }

    if (action === "enrich_players") {
      const raw = body?.players;
      if (!Array.isArray(raw) || !raw.length) {
        return jsonResponse({ error: "players array required" }, 400);
      }
      if (raw.length > 1) {
        return jsonResponse({ error: "Max 1 player per enrich call (PESDB rate limit)" }, 400);
      }

      const players: ScrapePlayer[] = [];
      for (const row of raw) {
        const base: PesdbListRow = {
          konami_id: String(row.konami_id ?? ""),
          player_name: String(row.player_name ?? ""),
          position: String(row.position ?? "CF"),
          nationality: String(row.nationality ?? ""),
          age: Number(row.age) || 25,
          rating: Number(row.rating) || 60,
        };
        if (!base.konami_id) continue;
        try {
          const detailHtml = await fetchPesdbHtml(pesdbPlayerMaxUrl(base.konami_id));
          const detail = parsePesdbMaxLevelPage(detailHtml);
          players.push({
            ...base,
            max_level_rating: detail.max_level_rating ?? base.rating,
            playing_style: detail.playing_style,
          });
        } catch (err) {
          console.error(`detail ${base.konami_id}:`, err);
          players.push({
            ...base,
            max_level_rating: base.rating,
            playing_style: "None",
          });
        }
        await politePause(6000, 4000);
      }

      return jsonResponse({
        ok: true,
        players,
        players_enriched: players.length,
      });
    }

    if (action !== "scrape_page") {
      return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }

    const page = Math.max(1, Number(body?.page) || 1);

    const listHtml = await fetchPesdbHtml(pesdbListUrl(page));
    const listRows = parsePesdbListPage(listHtml);

    if (!listRows.length) {
      return jsonResponse({
        ok: true,
        page,
        players: [],
        players_on_page: 0,
        warning: "No players parsed on this page",
      });
    }

    const players: ScrapePlayer[] = listRows.map((row) => ({
      ...row,
      max_level_rating: row.rating,
      playing_style: "None",
    }));

    return jsonResponse({
      ok: true,
      page,
      players,
      players_on_page: players.length,
      list_only: true,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("gpdb-pesdb-scrape:", message);
    return jsonResponse({ error: message }, 500);
  }
});
