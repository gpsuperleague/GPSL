import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * New thread in #q-and-a → one reply tagging the opener, with the handbook.
 *
 * Polled about once a minute (Discord does not push thread-created events
 * to Supabase). Threads older than LOOKBACK_MS are left alone.
 *
 * Secrets already used by the other Discord jobs:
 *   DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_FEED_INVOKE_KEY
 * The Q-and-A channel is found by name. No extra secret.
 *
 * Bot needs View Channel and Send Messages in that channel / its threads.
 */

const DISCORD_API = "https://discord.com/api/v10";
const HANDBOOK_URL = "https://gpsuperleague.github.io/GPSL/learning_gpsl.html";
const LOOKBACK_MS = 30 * 60 * 1000;
const DELAY_MS = 5000;
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-qa-key, x-discord-feed-key",
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

function snowflakeMs(id: string): number {
  try {
    return Number((BigInt(id) >> 22n) + 1420070400000n);
  } catch {
    return 0;
  }
}

function channelSlug(name: string): string {
  return String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
}

function isQaName(name: string): boolean {
  const n = channelSlug(name);
  return (
    n === "qanda" ||
    n === "qa" ||
    n === "questionsandanswers" ||
    n.includes("qanda")
  );
}

type DiscordChannel = {
  id: string;
  name?: string;
  type?: number;
  parent_id?: string | null;
  owner_id?: string | null;
  thread_metadata?: {
    archived?: boolean;
    locked?: boolean;
    create_timestamp?: string;
  };
};

async function discordFetch(
  botToken: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const headers = new Headers(init.headers || {});
  headers.set("Authorization", `Bot ${botToken}`);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(`${DISCORD_API}${path}`, { ...init, headers });
    if (res.status !== 429) return res;
    let waitSec = Number(res.headers.get("retry-after") || "1");
    try {
      const body = await res.clone().json();
      if (typeof body?.retry_after === "number") waitSec = body.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(waitSec * 1000) + 200);
  }
  return new Response("rate limited", { status: 429 });
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
    req.headers.get("x-discord-qa-key") ||
    req.headers.get("x-discord-feed-key") ||
    "";
  if (invokeKey && (bearer === invokeKey || headerKey === invokeKey)) {
    return true;
  }
  return false;
}

function threadCreatedMs(thread: DiscordChannel): number {
  const stamp = thread.thread_metadata?.create_timestamp;
  if (stamp) {
    const ms = Date.parse(stamp);
    if (Number.isFinite(ms)) return ms;
  }
  return snowflakeMs(thread.id);
}

async function resolveQaChannel(
  botToken: string,
  guildId: string
): Promise<{ id: string; name: string } | { error: string; forums: string[] }> {
  const res = await discordFetch(botToken, `/guilds/${guildId}/channels`);
  if (!res.ok) {
    const text = await res.text();
    return {
      error: `List channels: ${res.status} ${text.slice(0, 160)}`,
      forums: [],
    };
  }
  const channels = (await res.json()) as DiscordChannel[];
  const matches = channels.filter((c) => isQaName(c.name || ""));
  matches.sort((a, b) => {
    const aExact = channelSlug(a.name || "") === "qanda" ? 0 : 1;
    const bExact = channelSlug(b.name || "") === "qanda" ? 0 : 1;
    if (aExact !== bExact) return aExact - bExact;
    const aForum = a.type === 15 ? 0 : 1;
    const bForum = b.type === 15 ? 0 : 1;
    return aForum - bForum;
  });
  const match = matches[0];
  if (match) return { id: match.id, name: match.name || match.id };
  const forums = channels
    .filter((c) => c.type === 15 || c.type === 0)
    .map((c) => `${c.name || "?"} (${c.id})`);
  return {
    error: "No Discord channel named q-and-a.",
    forums,
  };
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
    const invokeKey =
      Deno.env.get("DISCORD_QA_HANDBOOK_INVOKE_KEY") ||
      Deno.env.get("DISCORD_FEED_INVOKE_KEY");

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
        const { data: adminFlag } = await userClient.rpc("is_gpsl_admin");
        if (adminFlag === true) allow = true;
        if (
          !allow &&
          (user.email || "").toLowerCase() === GPSL_ADMIN_EMAIL
        ) {
          allow = true;
        }
      }
    }
    if (!allow) return jsonResponse({ error: "Unauthorized" }, 401);

    if (!botToken || !guildId) {
      return jsonResponse(
        { error: "Missing DISCORD_BOT_TOKEN or DISCORD_GUILD_ID" },
        500
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

    const qa = await resolveQaChannel(botToken, guildId);
    if ("error" in qa) {
      return jsonResponse({ error: qa.error, forums: qa.forums }, 400);
    }

    const meRes = await discordFetch(botToken, "/users/@me");
    const me = meRes.ok
      ? ((await meRes.json()) as { id?: string })
      : {};
    const botId = String(me.id || "");

    const listRes = await discordFetch(
      botToken,
      `/channels/${qa.id}/threads/active`
    );
    if (!listRes.ok) {
      const text = await listRes.text();
      return jsonResponse(
        {
          error: `List threads in ${qa.name}: ${listRes.status} ${text.slice(0, 200)}`,
          channel_id: qa.id,
        },
        502
      );
    }
    const listed = (await listRes.json()) as { threads?: DiscordChannel[] };
    const now = Date.now();
    const recent = (listed.threads || []).filter((t) => {
      if (!t?.id) return false;
      if (t.thread_metadata?.archived || t.thread_metadata?.locked) return false;
      const created = threadCreatedMs(t);
      if (!created) return false;
      return now - created >= 0 && now - created <= LOOKBACK_MS;
    });

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const ids = recent.map((t) => t.id);
    const already = new Set<string>();
    if (ids.length) {
      const { data: rows, error } = await admin
        .from("gpsl_discord_qa_handbook_sent")
        .select("thread_id")
        .in("thread_id", ids);
      if (error) {
        return jsonResponse(
          {
            error: error.message,
            hint: "Run supabase/sql/patches/discord_qa_handbook_20261110.sql",
          },
          500
        );
      }
      for (const row of rows || []) {
        if (row?.thread_id) already.add(String(row.thread_id));
      }
    }

    const posted: { thread_id: string; owner_id: string | null }[] = [];
    const skipped: string[] = [];
    const failed: { thread_id: string; status: number; detail: string }[] = [];

    for (const thread of recent) {
      if (already.has(thread.id)) {
        skipped.push(thread.id);
        continue;
      }
      const ownerId = String(thread.owner_id || "").trim();
      if (botId && ownerId === botId) {
        skipped.push(thread.id);
        continue;
      }

      const age = now - threadCreatedMs(thread);
      if (!dryRun && age < DELAY_MS) {
        await sleep(DELAY_MS - age);
      }

      const mention = ownerId ? `<@${ownerId}> ` : "";
      const content =
        `${mention}have you checked in here first?\n${HANDBOOK_URL}`;

      if (dryRun) {
        posted.push({ thread_id: thread.id, owner_id: ownerId || null });
        continue;
      }

      const { error: claimError } = await admin
        .from("gpsl_discord_qa_handbook_sent")
        .insert({
          thread_id: thread.id,
          owner_id: ownerId || null,
          channel_id: qa.id,
        });
      if (claimError) {
        if (claimError.code === "23505") {
          skipped.push(thread.id);
          continue;
        }
        failed.push({
          thread_id: thread.id,
          status: 500,
          detail: claimError.message,
        });
        continue;
      }

      const postRes = await discordFetch(
        botToken,
        `/channels/${thread.id}/messages`,
        {
          method: "POST",
          body: JSON.stringify({
            content,
            allowed_mentions: ownerId
              ? { parse: [], users: [ownerId] }
              : { parse: [] },
          }),
        }
      );
      if (!postRes.ok) {
        const text = await postRes.text();
        if (postRes.status !== 403) {
          await admin
            .from("gpsl_discord_qa_handbook_sent")
            .delete()
            .eq("thread_id", thread.id);
        }
        failed.push({
          thread_id: thread.id,
          status: postRes.status,
          detail: text.slice(0, 180),
        });
        continue;
      }
      posted.push({ thread_id: thread.id, owner_id: ownerId || null });
      await sleep(400);
    }

    return jsonResponse({
      ok: true,
      dry_run: dryRun,
      channel_id: qa.id,
      channel_name: qa.name,
      recent: recent.length,
      posted,
      skipped: skipped.length,
      failed,
    });
  } catch (e) {
    console.error("discord-qa-handbook:", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : String(e) },
      500
    );
  }
});
