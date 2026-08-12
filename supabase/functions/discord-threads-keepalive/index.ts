import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * GPSL Discord management — keep threads alive.
 *
 * Unarchives public (and optionally private) threads under configured parent
 * channels so inactivity auto-archive does not leave them stuck closed.
 * Does NOT post bump messages.
 *
 * Secrets:
 *   DISCORD_BOT_TOKEN
 *   DISCORD_GUILD_ID
 *   DISCORD_KEEPALIVE_PARENT_CHANNEL_IDS  — comma-separated forum/text channel IDs
 *   DISCORD_FEED_INVOKE_KEY (or DISCORD_KEEPALIVE_INVOKE_KEY)
 *
 * Bot needs: Manage Threads (+ View Channel) on those parents.
 */

const DISCORD_API = "https://discord.com/api/v10";
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-keepalive-key, x-discord-feed-key",
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

type DiscordThread = {
  id: string;
  name?: string;
  parent_id?: string | null;
  thread_metadata?: {
    archived?: boolean;
    locked?: boolean;
    auto_archive_duration?: number;
  };
};

function parseParentIds(raw: string | undefined): string[] {
  if (!raw?.trim()) return [];
  return [
    ...new Set(
      raw
        .split(/[,;\s]+/)
        .map((s) => s.trim())
        .filter(Boolean)
    ),
  ];
}

async function discordFetch(
  botToken: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const headers = new Headers(init.headers || {});
  headers.set("Authorization", `Bot ${botToken}`);
  if (!headers.has("Content-Type") && init.body) {
    headers.set("Content-Type", "application/json");
  }

  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(`${DISCORD_API}${path}`, { ...init, headers });
    if (res.status !== 429) return res;

    let waitSec = Number(res.headers.get("retry-after") || "1");
    try {
      const body = await res.json();
      if (typeof body?.retry_after === "number") waitSec = body.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(waitSec * 1000) + 150);
  }

  return new Response("rate limited", { status: 429 });
}

async function listArchivedThreads(
  botToken: string,
  parentId: string,
  kind: "public" | "private"
): Promise<DiscordThread[]> {
  const out: DiscordThread[] = [];
  let before: string | undefined;

  for (let page = 0; page < 20; page++) {
    const qs = new URLSearchParams({ limit: "100" });
    if (before) qs.set("before", before);

    const res = await discordFetch(
      botToken,
      `/channels/${parentId}/threads/archived/${kind}?${qs}`
    );

    if (res.status === 403 || res.status === 404) {
      // No access / not a forum — skip quietly
      return out;
    }
    if (!res.ok) {
      const text = await res.text();
      throw new Error(
        `List ${kind} archived ${parentId}: ${res.status} ${text.slice(0, 200)}`
      );
    }

    const json = (await res.json()) as {
      threads?: DiscordThread[];
      has_more?: boolean;
    };
    const batch = Array.isArray(json.threads) ? json.threads : [];
    out.push(...batch);

    if (!json.has_more || batch.length === 0) break;
    const last = batch[batch.length - 1];
    // Discord wants archive_timestamp as before cursor; id works for many clients —
    // prefer id for pagination continuity.
    before = last?.id;
    if (!before) break;
    await sleep(400);
  }

  return out;
}

async function unarchiveThread(
  botToken: string,
  threadId: string
): Promise<{ ok: boolean; status: number; detail?: string }> {
  const res = await discordFetch(botToken, `/channels/${threadId}`, {
    method: "PATCH",
    body: JSON.stringify({
      archived: false,
      locked: false,
      // Max auto-archive (1 week) so they stay open longer between cron runs
      auto_archive_duration: 10080,
    }),
  });

  if (res.ok) return { ok: true, status: res.status };

  const text = await res.text();
  return { ok: false, status: res.status, detail: text.slice(0, 200) };
}

function authorized(
  req: Request,
  serviceRoleKey: string,
  invokeKey: string | undefined
): boolean {
  const auth = req.headers.get("Authorization") || "";
  const bearer = auth.replace(/^Bearer\s+/i, "").trim();
  if (bearer && bearer === serviceRoleKey) return true;

  const headerKey =
    req.headers.get("x-discord-keepalive-key") ||
    req.headers.get("x-discord-feed-key") ||
    "";
  if (invokeKey && (bearer === invokeKey || headerKey === invokeKey)) {
    return true;
  }

  return false;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const botToken = Deno.env.get("DISCORD_BOT_TOKEN");
    const guildId = Deno.env.get("DISCORD_GUILD_ID");
    const parentIds = parseParentIds(
      Deno.env.get("DISCORD_KEEPALIVE_PARENT_CHANNEL_IDS")
    );
    const invokeKey =
      Deno.env.get("DISCORD_KEEPALIVE_INVOKE_KEY") ||
      Deno.env.get("DISCORD_FEED_INVOKE_KEY");
    const includePrivate =
      String(Deno.env.get("DISCORD_KEEPALIVE_INCLUDE_PRIVATE") || "")
        .toLowerCase() === "true";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization") || "";
    let allow = authorized(req, serviceRoleKey, invokeKey);

    if (!allow && authHeader) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const {
        data: { user },
      } = await userClient.auth.getUser();
      if (user) {
        const { data: staffFlag } = await userClient.rpc("is_gpsl_admin_or_mod");
        if (staffFlag === true) allow = true;
        if (!allow) {
          const { data: adminFlag } = await userClient.rpc("is_gpsl_admin");
          if (adminFlag === true) allow = true;
        }
        if (
          !allow &&
          (user.email || "").toLowerCase() === GPSL_ADMIN_EMAIL
        ) {
          allow = true;
        }
      }
    }

    if (!allow) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    if (!botToken || !guildId) {
      return jsonResponse(
        {
          error:
            "Missing Discord secrets — set DISCORD_BOT_TOKEN and DISCORD_GUILD_ID",
        },
        500
      );
    }

    if (!parentIds.length) {
      return jsonResponse(
        {
          error:
            "Set DISCORD_KEEPALIVE_PARENT_CHANNEL_IDS to comma-separated forum/channel IDs",
          hint: "Right-click channel → Copy Channel ID (Developer Mode on)",
        },
        400
      );
    }

    let dryRun = false;
    try {
      if (req.method === "POST") {
        const body = await req.json().catch(() => ({}));
        dryRun = Boolean(body?.dry_run);
      }
    } catch {
      /* ignore */
    }

    const seen = new Set<string>();
    const toRevive: DiscordThread[] = [];
    const listErrors: string[] = [];

    for (const parentId of parentIds) {
      try {
        const pub = await listArchivedThreads(botToken, parentId, "public");
        for (const t of pub) {
          if (!t?.id || seen.has(t.id)) continue;
          seen.add(t.id);
          if (t.thread_metadata?.archived !== false) toRevive.push(t);
        }
        await sleep(350);

        if (includePrivate) {
          const priv = await listArchivedThreads(botToken, parentId, "private");
          for (const t of priv) {
            if (!t?.id || seen.has(t.id)) continue;
            seen.add(t.id);
            if (t.thread_metadata?.archived !== false) toRevive.push(t);
          }
          await sleep(350);
        }
      } catch (e) {
        listErrors.push(
          `${parentId}: ${e instanceof Error ? e.message : String(e)}`
        );
      }
    }

    const revived: string[] = [];
    const failed: { id: string; status: number; detail?: string }[] = [];

    for (const thread of toRevive) {
      if (dryRun) {
        revived.push(thread.id);
        continue;
      }
      const result = await unarchiveThread(botToken, thread.id);
      if (result.ok) revived.push(thread.id);
      else failed.push({ id: thread.id, ...result });
      await sleep(500);
    }

    return jsonResponse({
      ok: true,
      dry_run: dryRun,
      guild_id: guildId,
      parents: parentIds,
      archived_found: toRevive.length,
      revived: revived.length,
      revived_ids: revived.slice(0, 50),
      failed: failed.slice(0, 20),
      list_errors: listErrors,
      note: "Unarchives threads and sets auto_archive_duration to 7 days. No bump messages posted.",
    });
  } catch (e) {
    console.error("discord-threads-keepalive:", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : String(e) },
      500
    );
  }
});
