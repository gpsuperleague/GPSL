import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * Match videos ingest
 *
 * Modes:
 *   A) Poll (default when no attachments) — cron / Admin "Poll now"
 *      Scans month channels under DISCORD_MATCH_VIDEOS_CATEGORY_ID
 *   B) Push — body has message/attachments (optional live bot)
 */

const DISCORD_API = "https://discord.com/api/v10";
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-match-videos-key",
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

type DiscordAttachment = {
  id: string;
  filename?: string;
  url?: string;
  proxy_url?: string;
  content_type?: string | null;
};

type DiscordMessage = {
  id: string;
  channel_id?: string;
  content?: string;
  timestamp?: string;
  author?: DiscordUser;
  member?: DiscordMember;
  attachments?: DiscordAttachment[];
};

type DiscordChannel = {
  id: string;
  name?: string;
  type?: number;
  parent_id?: string | null;
};

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
  const url =
    `${DISCORD_API}/channels/${channelId}/messages/${messageId}/reactions/${encoded}/@me`;
  try {
    await fetch(url, {
      method: "PUT",
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Length": "0",
      },
    });
  } catch {
    /* ignore */
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function maxSnowflake(
  a: string | null | undefined,
  b: string | null | undefined
): string | null {
  if (!a) return b || null;
  if (!b) return a;
  try {
    return BigInt(a) >= BigInt(b) ? a : b;
  } catch {
    return a > b ? a : b;
  }
}

async function fetchChannelMessages(
  botToken: string,
  channelId: string,
  limit = 40,
  afterMessageId?: string | null
): Promise<DiscordMessage[]> {
  const url = new URL(`${DISCORD_API}/channels/${channelId}/messages`);
  url.searchParams.set("limit", String(Math.max(1, Math.min(limit, 100))));
  if (afterMessageId) url.searchParams.set("after", afterMessageId);

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

async function fetchGuildChannels(
  botToken: string,
  guildId: string
): Promise<DiscordChannel[]> {
  const res = await fetch(`${DISCORD_API}/guilds/${guildId}/channels`, {
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `Discord guild channels ${res.status}: ${text.slice(0, 300)}`
    );
  }
  const batch = (await res.json()) as DiscordChannel[];
  return Array.isArray(batch) ? batch : [];
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
    req.headers.get("x-discord-match-videos-key") ||
    req.headers.get("x-discord-feed-key") ||
    "";
  if (invokeKey && (bearer === invokeKey || headerKey === invokeKey)) {
    return true;
  }

  return false;
}

function looksLikeVideo(att: DiscordAttachment): boolean {
  const name = String(att.filename || "").toLowerCase();
  const ct = String(att.content_type || "").toLowerCase();
  if (ct.startsWith("video/")) return true;
  return /\.(mp4|mkv|mov|webm|avi|m4v|mpeg|mpg)$/i.test(name);
}

/** Discord markdown: [label](https://...) — greedy label so nested [SL-MD5] works */
function parseMarkdownVideoLinks(
  content: string
): { label: string; url: string; id: string }[] {
  const raw = String(content || "");
  const out: { label: string; url: string; id: string }[] = [];
  // Greedy .+ so "ARS 2-0 CHE [SL-MD5]" inside outer [] still works
  const re = /\[(.+)\]\((https?:\/\/[^)\s]+)\)/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw)) !== null) {
    const label = String(m[1] || "").trim();
    const url = String(m[2] || "").trim();
    if (!label || !url) continue;
    // Prefer youtube / common video hosts; still accept any https link
    out.push({
      label,
      url,
      id: `link:${url}`,
    });
  }
  return out;
}

type VideoCandidate = {
  id: string;
  filename: string;
  url: string;
};

function normalizeMonth(raw: string | null | undefined): string | null {
  const s = String(raw || "")
    .trim()
    .toLowerCase();
  if (!s) return null;
  const months = [
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
    "january",
    "february",
    "march",
    "april",
    "may",
  ];
  if (months.includes(s)) return s;
  const m = s.match(
    /\b(june|july|august|september|october|november|december|january|february|march|april|may)\b/i
  );
  return m ? m[1].toLowerCase() : null;
}

function monthFromChannelName(name: string | undefined): string | null {
  return normalizeMonth(name || "");
}

function channelIdList(raw: string | undefined): string[] {
  return String(raw || "")
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

async function ingestOneMessage(
  adminClient: ReturnType<typeof createClient>,
  byTag: Map<string, string>,
  botToken: string,
  guildId: string,
  msg: DiscordMessage,
  channelId: string,
  channelMonth: string | null,
  memberCache: Map<string, DiscordMember | null>
): Promise<Record<string, unknown>[]> {
  if (!msg?.id || !msg.author || msg.author.bot) return [];

  const candidates: VideoCandidate[] = [];

  // Primary: Discord markdown [ARS 2-0 CHE [SL-MD5]](https://youtu.be/...)
  for (const link of parseMarkdownVideoLinks(String(msg.content || ""))) {
    candidates.push({
      id: `${msg.id}:${link.id}`,
      filename: link.label,
      url: link.url,
    });
  }

  // Fallback: file attachments (optional)
  for (const a of msg.attachments || []) {
    if (!a || !(a.url || a.proxy_url) || !looksLikeVideo(a)) continue;
    candidates.push({
      id: a.id || `${msg.id}:file`,
      filename: a.filename || "",
      url: a.url || a.proxy_url || "",
    });
  }

  if (!candidates.length) return [];

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

  const out: Record<string, unknown>[] = [];
  let anyOk = false;
  let anyFail = false;

  for (const att of candidates) {
    const { data, error } = await adminClient.rpc(
      "match_video_ingest_attachment",
      {
        p_discord_message_id: msg.id,
        p_discord_channel_id: channelId,
        p_discord_attachment_id: att.id || null,
        p_discord_user_id: msg.author.id,
        p_uploader_club: club,
        p_filename: att.filename || "",
        p_video_url: att.url || "",
        p_channel_month: channelMonth,
        p_source: "discord",
      }
    );

    if (error) {
      anyFail = true;
      out.push({
        message_id: msg.id,
        attachment_id: att.id,
        ok: false,
        reason: error.message,
        filename: att.filename,
        club,
      });
      continue;
    }

    const row = (data || {}) as Record<string, unknown>;
    if (row.ok === true) anyOk = true;
    else anyFail = true;
    out.push({
      message_id: msg.id,
      attachment_id: att.id,
      filename: att.filename,
      club,
      ...row,
    });
  }

  // React only on first successful match (duplicates skip re-react via status)
  const freshMatch = out.some(
    (r) => r.ok === true && r.status === "matched" && Number(r.credited || 0) >= 0
  );
  const freshFail = out.every((r) => r.ok === false);
  if (freshMatch && out.some((r) => r.status === "matched")) {
    await addReaction(botToken, channelId, msg.id, "✅");
  } else if (freshFail && anyFail && !anyOk) {
    await addReaction(botToken, channelId, msg.id, "⚠️");
  }

  return out;
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
    const categoryId = Deno.env.get("DISCORD_MATCH_VIDEOS_CATEGORY_ID") || "";
    const extraChannels = channelIdList(
      Deno.env.get("DISCORD_MATCH_VIDEOS_CHANNEL_IDS")
    );
    const invokeKey =
      Deno.env.get("DISCORD_MATCH_VIDEOS_INVOKE_KEY") ||
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

    if (!allow) {
      return jsonResponse({ error: "Unauthorized" }, 401);
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

    // ----- Push mode (single message / attachments) -----
    const msgPush = body.message as DiscordMessage | undefined;
    const pushAtts: DiscordAttachment[] = [];
    if (Array.isArray(body.attachments)) {
      pushAtts.push(...(body.attachments as DiscordAttachment[]));
    }
    if (Array.isArray(msgPush?.attachments)) {
      pushAtts.push(...(msgPush!.attachments || []));
    }
    const hasPush =
      pushAtts.length > 0 ||
      body.discord_attachment_id ||
      body.filename ||
      body.video_url ||
      parseMarkdownVideoLinks(
        String(body.content || msgPush?.content || "")
      ).length > 0;

    if (hasPush) {
      if (!botToken || !guildId) {
        return jsonResponse(
          { error: "Missing DISCORD_BOT_TOKEN / DISCORD_GUILD_ID" },
          500
        );
      }
      const byTag = await buildOwnerTagMap(adminClient);
      const channelId = String(
        body.discord_channel_id || msgPush?.channel_id || ""
      ).trim();
      const synthetic: DiscordMessage = {
        id: String(body.discord_message_id || msgPush?.id || ""),
        content: String(body.content || msgPush?.content || ""),
        author: (body.author as DiscordUser) || msgPush?.author,
        member: (body.member as DiscordMember) || msgPush?.member || null,
        attachments:
          pushAtts.length > 0
            ? pushAtts
            : body.filename || body.video_url
              ? [
                  {
                    id: String(body.discord_attachment_id || ""),
                    filename: String(body.filename || ""),
                    url: String(body.video_url || ""),
                  },
                ]
              : [],
      };
      const results = await ingestOneMessage(
        adminClient,
        byTag,
        botToken,
        guildId,
        synthetic,
        channelId,
        normalizeMonth(body.channel_month as string),
        new Map()
      );
      return jsonResponse({
        ok: results.some((r) => r.ok === true),
        mode: "push",
        results,
      });
    }

    // ----- Poll mode (cron / admin) -----
    if (!botToken || !guildId) {
      return jsonResponse(
        {
          error:
            "Missing Discord secrets — set DISCORD_BOT_TOKEN and DISCORD_GUILD_ID",
        },
        500
      );
    }
    if (!categoryId && extraChannels.length === 0) {
      return jsonResponse(
        {
          error:
            "Set Edge secret DISCORD_MATCH_VIDEOS_CATEGORY_ID (Matchday videos category) or DISCORD_MATCH_VIDEOS_CHANNEL_IDS",
        },
        500
      );
    }

    const forceRescan = body.rescan === true || body.force === true;
    const limit = Number(body.limit) > 0 ? Number(body.limit) : 40;

    const { data: settingsRow } = await adminClient
      .from("gpsl_discord_match_videos_settings")
      .select("channel_cursors")
      .eq("id", 1)
      .maybeSingle();

    const cursors: Record<string, string> = {
      ...((settingsRow?.channel_cursors as Record<string, string>) || {}),
    };

    let channels: { id: string; month: string | null; name: string }[] = [];

    if (categoryId) {
      const all = await fetchGuildChannels(botToken, guildId);
      // type 0 = GUILD_TEXT
      channels = all
        .filter(
          (c) =>
            c.parent_id === categoryId &&
            (c.type === 0 || c.type === undefined) &&
            monthFromChannelName(c.name)
        )
        .map((c) => ({
          id: c.id,
          name: c.name || c.id,
          month: monthFromChannelName(c.name),
        }));
    }

    for (const id of extraChannels) {
      if (!channels.some((c) => c.id === id)) {
        channels.push({ id, name: id, month: null });
      }
    }

    if (!channels.length) {
      return jsonResponse({
        ok: false,
        mode: "poll",
        reason:
          "No month channels found under the category — name them january, february, …",
        category_id: categoryId || null,
      });
    }

    const byTag = await buildOwnerTagMap(adminClient);
    const memberCache = new Map<string, DiscordMember | null>();
    const results: Record<string, unknown>[] = [];
    let matched = 0;
    let scanned = 0;
    let duplicates = 0;
    const cursorUpdates: Record<string, string> = { ...cursors };

    for (const ch of channels) {
      const after = forceRescan ? null : cursors[ch.id] || null;
      let messages: DiscordMessage[] = [];
      try {
        messages = await fetchChannelMessages(botToken, ch.id, limit, after);
      } catch (err) {
        results.push({
          channel_id: ch.id,
          channel: ch.name,
          ok: false,
          reason: err instanceof Error ? err.message : String(err),
        });
        continue;
      }

      let newest = after;
      // Oldest first
      const ordered = [...messages].reverse();
      for (const msg of ordered) {
        if (!msg?.id) continue;
        newest = maxSnowflake(newest, msg.id);
        const rows = await ingestOneMessage(
          adminClient,
          byTag,
          botToken,
          guildId,
          { ...msg, channel_id: ch.id },
          ch.id,
          ch.month,
          memberCache
        );
        for (const r of rows) {
          scanned += 1;
          if (r.status === "matched") matched += 1;
          if (r.status === "duplicate") duplicates += 1;
          results.push({ channel: ch.name, month: ch.month, ...r });
        }
        await sleep(150);
      }
      if (newest) cursorUpdates[ch.id] = newest;
    }

    await adminClient.from("gpsl_discord_match_videos_settings").upsert({
      id: 1,
      channel_cursors: cursorUpdates,
      updated_at: new Date().toISOString(),
    });

    return jsonResponse({
      ok: true,
      mode: "poll",
      channels_scanned: channels.length,
      messages_with_videos: scanned,
      matched,
      duplicates,
      results: results.slice(-40),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
