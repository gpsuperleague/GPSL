import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  detectPesdbTotals,
  fetchPesdbHtml,
  mapWithConcurrency,
  parsePesdbListPage,
  parsePesdbMaxLevelPage,
  pesdbListUrl,
  pesdbPlayerMaxUrl,
  type PesdbListRow,
} from "./pesdb_parser.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type ScrapePlayer = PesdbListRow & {
  max_level_rating: number;
  playing_style: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
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

    const { data: isAdmin, error: adminError } = await userClient.rpc(
      "is_gpsl_admin"
    );
    if (adminError || !isAdmin) {
      return jsonResponse({ error: "Admin only" }, 403);
    }

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

    if (action !== "scrape_page") {
      return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }

    const page = Math.max(1, Number(body?.page) || 1);
    const includeDetails = body?.include_details !== false;
    const concurrency = Math.min(
      8,
      Math.max(1, Number(body?.concurrency) || 4)
    );

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

    let players: ScrapePlayer[];

    if (!includeDetails) {
      players = listRows.map((row) => ({
        ...row,
        max_level_rating: row.rating,
        playing_style: "None",
      }));
    } else {
      players = await mapWithConcurrency(
        listRows,
        concurrency,
        async (row) => {
          try {
            const detailHtml = await fetchPesdbHtml(
              pesdbPlayerMaxUrl(row.konami_id)
            );
            const detail = parsePesdbMaxLevelPage(detailHtml);
            return {
              ...row,
              max_level_rating: detail.max_level_rating ?? row.rating,
              playing_style: detail.playing_style,
            };
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            console.error(`detail ${row.konami_id}:`, message);
            return {
              ...row,
              max_level_rating: row.rating,
              playing_style: "None",
            };
          }
        }
      );
    }

    return jsonResponse({
      ok: true,
      page,
      players,
      players_on_page: players.length,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("gpdb-pesdb-scrape:", message);
    return jsonResponse({ error: message }, 500);
  }
});
