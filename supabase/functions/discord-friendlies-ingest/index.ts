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
    .trim();
}

function scorelineLooksValid(content: string): boolean {
  return /^[A-Za-z0-9]{2,8}\s+\d{1,2}\s*-\s*\d{1,2}\s+[A-Za-z0-9]{2,8}$/.test(
    cleanContent(content)
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
  limit = 40
): Promise<DiscordMessage[]> {
  const url = new URL(`${DISCORD_API}/channels/${channelId}/messages`);
  url.searchParams.set("limit", String(Math.max(1, Math.min(limit, 100))));

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

async function addReaction(
  botToken: string,
  channelId: string,
  messageId: string,
  emoji: string
) {
  const encoded = encodeURIComponent(emoji);
  try {
    await fetch(
      `${DISCORD_API}/channels/${channelId}/messages/${messageId}/reactions/${encoded}/@me`,
      {
        method: "PUT",
        headers: { Authorization: `Bot ${botToken}` },
      }
    );
  } catch {
    /* non-fatal */
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
    const messages = inject?.id
      ? [inject]
      : await fetchChannelMessages(
          botToken,
          channelId,
          Number(body.limit) > 0 ? Number(body.limit) : 40
        );

    // Oldest first so the original poster becomes report_1
    const ordered = [...messages].reverse();

    for (const msg of ordered) {
      if (!msg?.id || !msg.author || msg.author.bot) continue;
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
        const ids = Array.isArray(row.discord_message_ids)
          ? (row.discord_message_ids as string[])
          : [msg.id];
        for (const id of ids) {
          if (id) await addReaction(botToken, channelId, String(id), "✅");
        }
      } else if (status === "pending") {
        pending += 1;
        await addReaction(botToken, channelId, msg.id, "⏳");
      } else if (status === "duplicate") {
        duplicates += 1;
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
      hint:
        empty_content > 0 && scanned === 0
          ? "Discord returned messages with empty content — enable Message Content Intent and ensure the bot can read #gpsl-friendly-results"
          : scanned === 0 && messages.length > 0
            ? "Messages found but none matched CLUB score - score CLUB format"
            : messages.length === 0
              ? "No messages in channel — check DISCORD_FRIENDLIES_CHANNEL_ID"
              : null,
      results: results.slice(-30),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
