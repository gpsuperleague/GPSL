// GPSL — fetch Goal.com NXGN list HTML and extract ranked players
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";

const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const DEFAULT_SOURCE_URL =
  "https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd";

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function decodeHtml(text: string): string {
  return text
    .replace(/&#x27;/gi, "'")
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .trim();
}

type NxgnPlayer = { rank: number; name: string; club: string };

/** Goal list headlines: <span aria-label="Number">50</span>JJ Gabriel (Manchester United) */
function parseGoalNxgnHtml(html: string): NxgnPlayer[] {
  const byRank = new Map<number, NxgnPlayer>();

  const primary =
    /<span[^>]*aria-label=["']Number["'][^>]*>(\d{1,3})<\/span>\s*([^<(]+?)\s*\(([^)]+)\)/gi;
  for (const m of html.matchAll(primary)) {
    const rank = Number(m[1]);
    const name = decodeHtml(m[2] || "").replace(/\s+/g, " ").trim();
    const club = decodeHtml(m[3] || "").replace(/\s+/g, " ").trim();
    if (!Number.isFinite(rank) || rank < 1 || !name) continue;
    byRank.set(rank, { rank, name, club });
  }

  // Fallback: markdown-ish / plain "## 50Name (Club)" or "50. Name (Club)"
  if (byRank.size < 10) {
    const fallback =
      /(?:^|>|\n)\s*#*\s*(\d{1,3})[.\s]*([A-Za-zÀ-ÿ][^<(\n]{1,80}?)\s*\(([^)\n]{2,80})\)/g;
    for (const m of html.matchAll(fallback)) {
      const rank = Number(m[1]);
      const name = decodeHtml(m[2] || "").replace(/\s+/g, " ").trim();
      const club = decodeHtml(m[3] || "").replace(/\s+/g, " ").trim();
      if (!Number.isFinite(rank) || rank < 1 || rank > 200 || !name) continue;
      if (!byRank.has(rank)) byRank.set(rank, { rank, name, club });
    }
  }

  return [...byRank.values()].sort((a, b) => a.rank - b.rank);
}

function isAllowedSourceUrl(url: string): boolean {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return false;
    const host = u.hostname.toLowerCase();
    return host === "www.goal.com" || host === "goal.com" || host.endsWith(".goal.com");
  } catch {
    return false;
  }
}

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
    if (!authHeader) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();

    if (userError || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    if (!(await isGpslAdminOrMod(userClient, user, GPSL_ADMIN_EMAIL))) {
      return jsonResponse({ error: "Admin or mod only" }, 403);
    }

    let body: { url?: string; save_url?: boolean } = {};
    try {
      body = await req.json();
    } catch {
      body = {};
    }

    let url = String(body.url || "").trim();

    if (!url) {
      const { data: settings } = await userClient.rpc("nextgen_youth_settings_get");
      url = String(settings?.source_url || "").trim();
    }
    if (!url) url = DEFAULT_SOURCE_URL;

    if (!isAllowedSourceUrl(url)) {
      return jsonResponse(
        { error: "URL must be a goal.com NXGN list page (https://www.goal.com/...)" },
        400
      );
    }

    if (body.save_url !== false) {
      await userClient.rpc("admin_nextgen_youth_settings_set", {
        p_source_url: url,
      });
    }

    const res = await fetch(url, {
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html,application/xhtml+xml",
        "Accept-Language": "en-GB,en;q=0.9",
      },
      redirect: "follow",
    });

    if (!res.ok) {
      return jsonResponse(
        { error: `Goal.com returned HTTP ${res.status}`, source_url: url },
        502
      );
    }

    const html = await res.text();
    const players = parseGoalNxgnHtml(html);

    if (!players.length) {
      return jsonResponse(
        {
          error:
            "No ranked players found on that page. Check the URL is a Goal NXGN list article.",
          source_url: url,
          html_bytes: html.length,
        },
        422
      );
    }

    return jsonResponse({
      ok: true,
      source_url: url,
      player_count: players.length,
      players,
    });
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : String(err) },
      500
    );
  }
});
