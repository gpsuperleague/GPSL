import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

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

type IngestBody = {
  discord_message_id?: string;
  discord_channel_id?: string;
  discord_attachment_id?: string;
  discord_user_id?: string;
  filename?: string;
  video_url?: string;
  channel_month?: string | null;
  uploader_club?: string | null;
  author?: DiscordUser;
  member?: DiscordMember | null;
  react?: boolean;
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

    let body: IngestBody & {
      attachments?: DiscordAttachment[];
      message?: {
        id?: string;
        channel_id?: string;
        author?: DiscordUser;
        member?: DiscordMember | null;
        attachments?: DiscordAttachment[];
      };
    } = {};

    if (req.method === "POST") {
      try {
        body = (await req.json()) as typeof body;
      } catch {
        body = {};
      }
    }

    const msg = body.message;
    const attachments: DiscordAttachment[] = [];
    if (Array.isArray(body.attachments)) attachments.push(...body.attachments);
    if (Array.isArray(msg?.attachments)) attachments.push(...msg.attachments);

    const singleAtt =
      body.discord_attachment_id || body.filename || body.video_url
        ? [
            {
              id: String(body.discord_attachment_id || ""),
              filename: String(body.filename || ""),
              url: String(body.video_url || ""),
            } satisfies DiscordAttachment,
          ]
        : [];

    const queue = (attachments.length ? attachments : singleAtt).filter(
      (a) => a && (a.url || a.proxy_url) && looksLikeVideo(a)
    );

    if (!queue.length) {
      return jsonResponse({
        ok: false,
        reason: "No video attachments in payload",
      });
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const byTag = await buildOwnerTagMap(adminClient);

    const channelId = String(
      body.discord_channel_id || msg?.channel_id || ""
    ).trim();
    const messageId = String(body.discord_message_id || msg?.id || "").trim();
    const author = body.author || msg?.author;
    const userId = String(body.discord_user_id || author?.id || "").trim();
    const channelMonth = normalizeMonth(body.channel_month);

    let club = String(body.uploader_club || "")
      .trim()
      .toUpperCase() || null;

    if (!club && userId && botToken && guildId) {
      const member =
        body.member ||
        msg?.member ||
        (await fetchGuildMember(botToken, guildId, userId));
      const keys = [
        member?.nick || "",
        author?.global_name || "",
        usernameTag(author),
        author?.username || "",
      ];
      club = matchClubByTags(byTag, keys);
    }

    const results: Record<string, unknown>[] = [];
    let matched = 0;
    let creditedTotal = 0;

    for (const att of queue) {
      const { data, error } = await adminClient.rpc(
        "match_video_ingest_attachment",
        {
          p_discord_message_id: messageId || null,
          p_discord_channel_id: channelId || null,
          p_discord_attachment_id: att.id || null,
          p_discord_user_id: userId || null,
          p_uploader_club: club,
          p_filename: att.filename || "",
          p_video_url: att.url || att.proxy_url || "",
          p_channel_month: channelMonth,
          p_source: "discord",
        }
      );

      if (error) {
        results.push({
          attachment_id: att.id,
          ok: false,
          reason: error.message,
          filename: att.filename,
        });
        continue;
      }

      const row = (data || {}) as Record<string, unknown>;
      if (row.ok === true && row.status === "matched") {
        matched += 1;
        creditedTotal += Number(row.credited || 0) || 0;
      }
      results.push({
        attachment_id: att.id,
        filename: att.filename,
        club,
        ...row,
      });
    }

    const doReact = body.react !== false;
    if (doReact && botToken && channelId && messageId) {
      const anyOk = results.some((r) => r.ok === true);
      const anyFail = results.some((r) => r.ok === false);
      if (anyOk) await addReaction(botToken, channelId, messageId, "✅");
      else if (anyFail) await addReaction(botToken, channelId, messageId, "⚠️");
    }

    return jsonResponse({
      ok: results.some((r) => r.ok === true),
      matched,
      credited_total: creditedTotal,
      club,
      channel_month: channelMonth,
      results,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
