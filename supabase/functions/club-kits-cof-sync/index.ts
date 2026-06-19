// GPSL — sync club kit images from colours-of-football.com
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  COF_BASE,
  fetchLatestCofKits,
  downloadCofImage,
} from "./club_kits_cof.js";

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

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

type ClubRow = {
  ShortName: string;
  Club: string;
  Nation: string;
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
        club.ShortName
      );
      return jsonResponse({ ok: true, club, result });
    }

    if (action !== "sync_batch") {
      return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }

    const offset = Math.max(0, Number(body?.offset) || 0);
    const limit = Math.min(8, Math.max(1, Number(body?.limit) || 4));

    const { data: clubs, error: clubsError } = await adminClient
      .from("Clubs")
      .select("ShortName, Club, Nation")
      .neq("ShortName", "FOREIGN")
      .order("Club")
      .range(offset, offset + limit - 1);

    if (clubsError) {
      return jsonResponse({ error: clubsError.message }, 500);
    }

    const rows = (clubs || []) as ClubRow[];
    const results: Record<string, unknown>[] = [];

    for (const club of rows) {
      const entry: Record<string, unknown> = {
        club_short_name: club.ShortName,
        club_name: club.Club,
        nation: club.Nation,
        ok: false,
      };

      try {
        const cof = await fetchLatestCofKits(
          club.Nation,
          club.Club,
          club.ShortName
        );

        if (cof.error) {
          entry.error = cof.error;
          results.push(entry);
          await sleep(250);
          continue;
        }

        const kits = cof.kits || { home: null, away: null, third: null };
        let homeUrl = kits.home;
        let awayUrl = kits.away;
        let thirdUrl = kits.third;

        if (downloadImages) {
          const kinds = [
            ["home", homeUrl],
            ["away", awayUrl],
            ["third", thirdUrl],
          ] as const;

          for (const [kind, src] of kinds) {
            if (!src) continue;
            const { bytes, contentType } = await downloadCofImage(src);
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
      await sleep(400);
    }

    const { count } = await adminClient
      .from("Clubs")
      .select("*", { count: "exact", head: true })
      .neq("ShortName", "FOREIGN");

    const nextOffset = offset + rows.length;
    const done = nextOffset >= (count || 0);

    return jsonResponse({
      ok: true,
      source: COF_BASE,
      offset,
      processed: rows.length,
      next_offset: done ? null : nextOffset,
      total_clubs: count,
      done,
      download_images: downloadImages,
      results,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("club-kits-cof-sync:", message);
    return jsonResponse({ error: message }, 500);
  }
});
