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

async function sleep(ms: number) {
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
        await sleep(1500 * (attempt + 1));
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
      await sleep(STADIUM_FETCH_DELAY_MS);
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
    if (!club.Stadium?.toString().trim()) {
      entry.error = "no Stadium name in DB";
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
