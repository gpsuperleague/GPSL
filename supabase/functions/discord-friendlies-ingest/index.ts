import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const DISCORD_API = "https://discord.com/api/v10";
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-friendlies-key",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type DiscordUser = {
  id: string;
  username?: string;
  global_name?: string | null;
  discriminator?: string;
  bot?: boolean;
};

type DiscordMember = {
  user?: DiscordUser;
  nick?: string | null;
};

type DiscordMessage = {
  id: string;
  content?: string;
  timestamp?: string;
  author?: DiscordUser;
  member?: DiscordMember;
};

function cleanContent(raw: string): string {
  return String(raw || "")
    .replace(/[\u200B-\u200D\uFEFF]/g, "")
    .replace(/[\u2013\u2014\u2212\u2010\u2011]/g, "-")
    .trim();
}

/** A) JUB 2 - 2 BEN  or  B) ROS 2 - JUB 3 */
function scorelineLooksValid(content: string): boolean {
  const c = cleanContent(content);
  return (
    /^[A-Za-z0-9]{2,8}\s+\d{1,2}\s*-\s*\d{1,2}\s+[A-Za-z0-9]{2,8}$/.test(c) ||
    /^[A-Za-z0-9]{2,8}\s+\d{1,2}\s*-\s*[A-Za-z0-9]{2,8}\s+\d{1,2}$/.test(c)
  );
}

function usernameTag(u: DiscordUser | undefined): string {
  if (!u?.username) return "";
  if (u.discriminator && u.discriminator !== "0") {
    return `${u.username}#${u.discriminator}`;
  }
  return u.username;
}

function matchClubByTags(
  byTag: Map<string, string>,
  keys: string[]
): string | null {
  for (const key of keys) {
    const k = key.trim().toLowerCase();
    if (!k) continue;
    const club = byTag.get(k);
    if (club) return club;
  }
  return null;
}

async function fetchChannelMessages(
  botToken: string,
  channelId: string,
  limit = 40,
  afterMessageId?: string | null
): Promise<DiscordMessage[]> {
  const url = new URL(`${DISCORD_API}/channels/${channelId}/messages`);
  url.searchParams.set("limit", String(Math.max(1, Math.min(limit, 100))));
  if (afterMessageId) {
    url.searchParams.set("after", afterMessageId);
  }

  const res = await fetch(url, {
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `Discord channel messages ${res.status}: ${text.slice(0, 300)}`
    );
  }

  const batch = (await res.json()) as DiscordMessage[];
  return Array.isArray(batch) ? batch : [];
}

function maxSnowflake(a: string | null | undefined, b: string | null | undefined): string | null {
  if (!a) return b || null;
  if (!b) return a;
  try {
    return BigInt(a) >= BigInt(b) ? a : b;
  } catch {
    return a > b ? a : b;
  }
}

async function fetchGuildMember(
  botToken: string,
  guildId: string,
  userId: string
): Promise<DiscordMember | null> {
  const res = await fetch(
    `${DISCORD_API}/guilds/${guildId}/members/${userId}`,
    {
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Type": "application/json",
      },
    }
  );
  if (!res.ok) return null;
  return (await res.json()) as DiscordMember;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function asIdList(value: unknown, fallback?: string): string[] {
  const out: string[] = [];
  if (Array.isArray(value)) {
    for (const v of value) {
      const id = String(v || "").trim();
      if (id) out.push(id);
    }
  } else if (typeof value === "string" && value.trim()) {
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) {
        for (const v of parsed) {
          const id = String(v || "").trim();
          if (id) out.push(id);
        }
      }
    } catch {
      out.push(value.trim());
    }
  }
  if (fallback) out.push(fallback);
  return [...new Set(out)];
}

async function addReaction(
  botToken: string,
  channelId: string,
  messageId: string,
  emoji: string
) {
  const encoded = encodeURIComponent(emoji);
  const url =
    `${DISCORD_API}/channels/${channelId}/messages/${messageId}/reactions/${encoded}/@me`;

  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, {
        method: "PUT",
        headers: {
          Authorization: `Bot ${botToken}`,
          "Content-Length": "0",
        },
      });
      if (res.status === 204 || res.status === 200) return;
      if (res.status === 429) {
        const retry = Number(res.headers.get("retry-after") || "1");
        await sleep(Math.max(300, retry * 1000));
        continue;
      }
      // Already reacted / unknown — stop retrying
      return;
    } catch {
      await sleep(300);
    }
  }
}

async function reactMany(
  botToken: string,
  channelId: string,
  messageIds: string[],
  emoji: string
) {
  for (const id of messageIds) {
    if (!id) continue;
    await addReaction(botToken, channelId, id, emoji);
    await sleep(250);
  }
}

async function buildOwnerTagMap(
  adminClient: ReturnType<typeof createClient>
): Promise<Map<string, string>> {
  const byTag = new Map<string, string>();

  const { data: clubRows } = await adminClient
    .from("Clubs")
    .select("ShortName, owner, owner_id");

  const { data: registryRows } = await adminClient
    .from("gpsl_owner_registry")
    .select("owner_id, owner_tag");

  const clubByOwner = new Map<string, string>();
  for (const row of clubRows || []) {
    const short = String(row.ShortName || "")
      .trim()
      .toUpperCase();
    if (!short) continue;
    if (row.owner_id) clubByOwner.set(String(row.owner_id), short);

    const tag = String(row.owner || "")
      .trim()
      .toLowerCase();
    if (tag) byTag.set(tag, short);
  }

  for (const row of registryRows || []) {
    const tag = String(row.owner_tag || "")
      .trim()
      .toLowerCase();
    if (!tag || !row.owner_id) continue;
    const club = clubByOwner.get(String(row.owner_id));
    if (club) byTag.set(tag, club);
  }

  return byTag;
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
    req.headers.get("x-discord-friendlies-key") ||
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
    const channelId = Deno.env.get("DISCORD_FRIENDLIES_CHANNEL_ID");
    const invokeKey =
      Deno.env.get("DISCORD_FRIENDLIES_INVOKE_KEY") ||
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
        const { data: adminFlag, error: adminErr } = await userClient.rpc(
          "is_gpsl_admin"
        );
        if (!adminErr && adminFlag === true) allow = true;
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

    if (!botToken || !guildId || !channelId) {
      return jsonResponse(
        {
          error:
            "Missing Discord secrets — set DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_FRIENDLIES_CHANNEL_ID",
        },
        500
      );
    }

    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      try {
        body = (await req.json()) as Record<string, unknown>;
      } catch {
        body = {};
      }
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const byTag = await buildOwnerTagMap(adminClient);
    const memberCache = new Map<string, DiscordMember | null>();

    const results: Record<string, unknown>[] = [];
    let scanned = 0;
    let matched = 0;
    let pending = 0;
    let ignored = 0;
    let duplicates = 0;
    let skipped_format = 0;
    let empty_content = 0;

    const inject = body.message as DiscordMessage | undefined;
    const forceRescan = body.rescan === true || body.force === true;
    let lastIngestedId: string | null = null;

    if (!inject?.id && !forceRescan) {
      const { data: settingsRow } = await adminClient
        .from("gpsl_discord_friendlies_settings")
        .select("last_ingested_message_id")
        .eq("id", 1)
        .maybeSingle();
      lastIngestedId =
        (settingsRow?.last_ingested_message_id as string | null) || null;
    }

    const messages = inject?.id
      ? [inject]
      : await fetchChannelMessages(
          botToken,
          channelId,
          Number(body.limit) > 0 ? Number(body.limit) : 40,
          lastIngestedId
        );

    let newestSeenId = lastIngestedId;

    // Oldest first so the original poster becomes report_1
    const ordered = [...messages].reverse();

    for (const msg of ordered) {
      if (!msg?.id) continue;
      newestSeenId = maxSnowflake(newestSeenId, msg.id);

      if (!msg.author || msg.author.bot) continue;
      const content = cleanContent(String(msg.content || ""));
      if (!content) {
        empty_content += 1;
        continue;
      }
      if (!scorelineLooksValid(content)) {
        skipped_format += 1;
        continue;
      }

      scanned += 1;

      if (!memberCache.has(msg.author.id)) {
        memberCache.set(
          msg.author.id,
          msg.member ||
            (await fetchGuildMember(botToken, guildId, msg.author.id))
        );
      }
      const member = memberCache.get(msg.author.id) || null;

      const keys = [
        member?.nick || "",
        msg.author.global_name || "",
        usernameTag(msg.author),
        msg.author.username || "",
      ];
      const club = matchClubByTags(byTag, keys);
      if (!club) {
        ignored += 1;
        results.push({
          message_id: msg.id,
          status: "ignored",
          reason: "No GPSL club for Discord user",
          content,
          discord_user: usernameTag(msg.author) || msg.author.username,
          lookup_keys: keys.filter(Boolean),
        });
        continue;
      }

      const { data, error } = await adminClient.rpc(
        "gpsl_friendlies_ingest_post",
        {
          p_discord_message_id: msg.id,
          p_discord_user_id: msg.author.id,
          p_reporter_club: club,
          p_content: content,
          p_posted_at: msg.timestamp || new Date().toISOString(),
        }
      );

      if (error) {
        results.push({
          message_id: msg.id,
          status: "error",
          reason: error.message,
          content,
          club,
        });
        continue;
      }

      const row = (data || {}) as Record<string, unknown>;
      const status = String(row.status || "");

      if (status === "matched") {
        matched += 1;
        // React only on first match — never on later polls (stops Discord ping spam)
        const ids = asIdList(row.discord_message_ids, msg.id);
        await reactMany(botToken, channelId, ids, "✅");
      } else if (status === "pending") {
        pending += 1;
        await addReaction(botToken, channelId, msg.id, "⏳");
      } else if (status === "duplicate") {
        duplicates += 1;
        // Already ingested — do not re-react (was notifying posters every 2 min)
      } else {
        ignored += 1;
      }

      results.push({
        message_id: msg.id,
        club,
        content,
        ...row,
      });
    }

    // Advance watermark so the 2-minute cron only sees new posts
    if (!inject?.id && newestSeenId && newestSeenId !== lastIngestedId) {
      const { error: wmErr } = await adminClient
        .from("gpsl_discord_friendlies_settings")
        .update({
          last_ingested_message_id: newestSeenId,
          updated_at: new Date().toISOString(),
        })
        .eq("id", 1);
      if (wmErr) {
        console.warn("friendlies watermark update failed:", wmErr.message);
      }
    }

    return jsonResponse({
      ok: true,
      messages_fetched: messages.length,
      scanned,
      matched,
      pending,
      ignored,
      duplicates,
      skipped_format,
      empty_content,
      last_ingested_message_id: newestSeenId,
      hint:
        empty_content > 0 && scanned === 0
          ? "Discord returned messages with empty content — enable Message Content Intent and ensure the bot can read #gpsl-friendly-results"
          : scanned === 0 && messages.length > 0
            ? "Messages found but none matched CLUB score - score CLUB format"
            : messages.length === 0
              ? lastIngestedId
                ? "No new messages since last poll"
                : "No messages in channel — check DISCORD_FRIENDLIES_CHANNEL_ID"
              : null,
      results: results.slice(-30),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
