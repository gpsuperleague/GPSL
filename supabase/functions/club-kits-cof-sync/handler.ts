import { createClient } from "npm:@supabase/supabase-js@2";

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
    return await handleClubKitsCofSync(req);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});

async function handleClubKitsCofSync(req: Request): Promise<Response> {
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
    if (adminError || !isAdmin) return jsonResponse({ error: "Admin only" }, 403);

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
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
}
