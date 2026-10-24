import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * Match videos ingest
 *
 * Modes:
 *   A) Poll (default when no attachments) — cron / Admin "Poll now"
 *      Scans month channels under DISCORD_MATCH_VIDEOS_CATEGORY_ID
 *   B) Push — body has message/attachments (optional live bot)
 *   C) sync_codes — post/update competition-code guide in #upload-codes
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

/**
 * Registry tags are usually plain ("croroshi"); Discord nicks are often
 * "croroshi - Marseille | MAR". Match exact, then "| CODE", then tag prefix.
 */
function matchClubByTags(
  byTag: Map<string, string>,
  clubShorts: Set<string>,
  keys: string[]
): string | null {
  for (const key of keys) {
    const k = key.trim().toLowerCase();
    if (!k) continue;
    const club = byTag.get(k);
    if (club) return club;
  }

  for (const key of keys) {
    const pipe = String(key || "").match(/\|\s*([A-Za-z0-9]{2,8})\s*$/i);
    if (pipe) {
      const code = pipe[1].toUpperCase();
      if (clubShorts.has(code)) return code;
    }
  }

  for (const key of keys) {
    const k = key.trim().toLowerCase();
    if (!k) continue;
    const head = k.split(/\s+-\s+/)[0]?.trim();
    if (head) {
      const byHead = byTag.get(head);
      if (byHead) return byHead;
    }
    for (const [tag, club] of byTag) {
      if (tag.length < 2) continue;
      if (
        k === tag ||
        k.startsWith(`${tag} `) ||
        k.startsWith(`${tag}-`) ||
        k.startsWith(`${tag} -`)
      ) {
        return club;
      }
    }
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

/** Fold channel names for matching (emoji / separators stripped). */
function foldChannelName(name: string | undefined | null): string {
  return String(name || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
}

/** Cup-codes supplement only — club/league lists already live in #upload-codes. */
const COMP_CODES_FOOTER = "gpsl-match-video-cup-codes-v1";

function competitionCodesMessageBody() {
  return {
    content:
      "**Cup competition codes** (add-on to the club / league list above)\n" +
      "Same link format: `[HomeShort 2-0 AwayShort [CUP-ROUND]](https://youtu.be/xxxxx)`",
    embeds: [
      {
        title: "GPSL cups — video tags",
        color: 0xff9900,
        description:
          "League tags (**SL** / **CA** / **CB** + `MD{n}`) stay as already listed in this channel.",
        fields: [
          {
            name: "Cup codes",
            value:
              "**S8** — Super8\n" +
              "**PL** — Plate\n" +
              "**SH** — Shield\n" +
              "**BO** — Bowl _(BW also accepted)_\n" +
              "**LC** — League Cup",
            inline: true,
          },
          {
            name: "Round tags",
            value:
              "`F` / `FINAL`\n" +
              "`SF` — semi\n" +
              "`QF` — quarter\n" +
              "`R16` · `R32` · or `R{n}`",
            inline: true,
          },
          {
            name: "Examples",
            value:
              "`[ARS 2-0 CHE [S8-QF]](https://youtu.be/xxxxx)`\n" +
              "`[LIV 1-0 MCI [LC-R32]](https://youtu.be/xxxxx)`\n" +
              "`[MON 0-0 ATA [SH-SF]](https://youtu.be/xxxxx)`\n" +
              "Match Day → **Copy video filename** builds the exact tag.",
            inline: false,
          },
        ],
        footer: { text: COMP_CODES_FOOTER },
      },
    ],
  };
}

function findUploadCodesChannel(
  channels: DiscordChannel[],
  categoryId: string | null,
  forcedId: string | null
): DiscordChannel | null {
  if (forcedId) {
    const hit = channels.find((c) => c.id === forcedId);
    if (hit) return hit;
  }
  const textChannels = channels.filter(
    (c) => c.type === 0 || c.type === undefined
  );
  const preferParent = categoryId
    ? textChannels.filter((c) => c.parent_id === categoryId)
    : textChannels;
  const pools = [preferParent, textChannels];
  for (const pool of pools) {
    for (const c of pool) {
      const fold = foldChannelName(c.name);
      if (
        fold === "uploadcodes" ||
        fold === "uploadcode" ||
        fold.includes("uploadcodes") ||
        (fold.includes("upload") && fold.includes("code"))
      ) {
        return c;
      }
    }
  }
  return null;
}

async function postOrEditChannelMessage(
  botToken: string,
  channelId: string,
  messageId: string | null,
  body: Record<string, unknown>
): Promise<{ id: string; edited: boolean }> {
  if (messageId) {
    const res = await fetch(
      `${DISCORD_API}/channels/${channelId}/messages/${messageId}`,
      {
        method: "PATCH",
        headers: {
          Authorization: `Bot ${botToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      }
    );
    if (res.ok) {
      const msg = (await res.json()) as DiscordMessage;
      return { id: String(msg.id), edited: true };
    }
  }

  // Look for an existing guide we posted (footer marker)
  try {
    const recent = await fetchChannelMessages(botToken, channelId, 50);
    const existing = recent.find((m) => {
      const embeds = (m as { embeds?: { footer?: { text?: string } }[] })
        .embeds;
      return embeds?.some((e) => e?.footer?.text === COMP_CODES_FOOTER);
    });
    if (existing?.id) {
      const res = await fetch(
        `${DISCORD_API}/channels/${channelId}/messages/${existing.id}`,
        {
          method: "PATCH",
          headers: {
            Authorization: `Bot ${botToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        }
      );
      if (res.ok) {
        return { id: String(existing.id), edited: true };
      }
    }
  } catch {
    /* fall through to create */
  }

  const res = await fetch(`${DISCORD_API}/channels/${channelId}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `Discord post codes ${res.status}: ${text.slice(0, 300)}`
    );
  }
  const msg = (await res.json()) as DiscordMessage;
  return { id: String(msg.id), edited: false };
}

async function syncCompetitionCodesGuide(
  adminClient: ReturnType<typeof createClient>,
  botToken: string,
  guildId: string,
  categoryId: string | null
): Promise<Record<string, unknown>> {
  const forcedId =
    String(Deno.env.get("DISCORD_MATCH_VIDEOS_CODES_CHANNEL_ID") || "").trim() ||
    null;

  const all = await fetchGuildChannels(botToken, guildId);
  const channel = findUploadCodesChannel(all, categoryId, forcedId);
  if (!channel) {
    return {
      ok: false,
      error:
        "No upload-codes channel found. Create a text channel named upload-codes (under Matchday videos is fine), or set Edge secret DISCORD_MATCH_VIDEOS_CODES_CHANNEL_ID.",
    };
  }

  const { data: settingsRow } = await adminClient
    .from("gpsl_discord_match_videos_settings")
    .select("codes_channel_id, codes_message_id")
    .eq("id", 1)
    .maybeSingle();

  const priorMsgId =
    channel.id === settingsRow?.codes_channel_id
      ? String(settingsRow?.codes_message_id || "").trim() || null
      : null;

  const result = await postOrEditChannelMessage(
    botToken,
    channel.id,
    priorMsgId,
    competitionCodesMessageBody()
  );

  const { error: saveErr } = await adminClient
    .from("gpsl_discord_match_videos_settings")
    .update({
      codes_channel_id: channel.id,
      codes_message_id: result.id,
      updated_at: new Date().toISOString(),
    })
    .eq("id", 1);
  if (saveErr) {
    // Columns may be missing until SQL patch is applied — still return Discord OK.
    console.warn("codes settings save:", saveErr.message);
  }

  return {
    ok: true,
    mode: "sync_codes",
    channel_id: channel.id,
    channel_name: channel.name || channel.id,
    message_id: result.id,
    edited: result.edited,
  };
}

type OwnerMaps = {
  byTag: Map<string, string>;
  byDiscordId: Map<string, string>;
  clubShorts: Set<string>;
};

function isAllowedVideoUrl(raw: string): boolean {
  const v = String(raw || "").trim();
  if (!v || v.length > 2000) return false;
  if (!/^https:\/\//i.test(v)) return false;
  if (/\s/.test(v) || v.includes("@")) return false;
  let host = "";
  try {
    host = new URL(v).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host.startsWith("www.")) host = host.slice(4);
  return (
    host === "youtube.com" ||
    host === "m.youtube.com" ||
    host === "youtu.be" ||
    host === "youtube-nocookie.com" ||
    host === "cdn.discordapp.com" ||
    host === "media.discordapp.net"
  );
}

async function buildOwnerMaps(
  adminClient: ReturnType<typeof createClient>
): Promise<OwnerMaps> {
  const byTag = new Map<string, string>();
  const byDiscordId = new Map<string, string>();
  const clubShorts = new Set<string>();

  const { data: clubRows } = await adminClient
    .from("Clubs")
    .select("ShortName, owner, owner_id");

  const { data: registryRows } = await adminClient
    .from("gpsl_owner_registry")
    .select("owner_id, owner_tag, discord_user_id");

  const clubByOwner = new Map<string, string>();
  for (const row of clubRows || []) {
    const short = String(row.ShortName || "")
      .trim()
      .toUpperCase();
    if (!short) continue;
    clubShorts.add(short);
    if (row.owner_id) clubByOwner.set(String(row.owner_id), short);

    const tag = String(row.owner || "")
      .trim()
      .toLowerCase();
    if (tag) byTag.set(tag, short);
  }

  for (const row of registryRows || []) {
    if (!row.owner_id) continue;
    const club = clubByOwner.get(String(row.owner_id));
    if (!club) continue;

    const tag = String(row.owner_tag || "")
      .trim()
      .toLowerCase();
    if (tag) byTag.set(tag, club);

    const discordId = String(row.discord_user_id || "").trim();
    if (discordId) byDiscordId.set(discordId, club);
  }

  return { byTag, byDiscordId, clubShorts };
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

/** Fold fancy Discord channel fonts (bold/double-struck/fullwidth/etc.) → a-z */
function foldChannelLetters(raw: string): string {
  let out = "";
  for (const ch of String(raw || "")) {
    const cp = ch.codePointAt(0);
    if (cp == null) continue;

    // ASCII letters
    if (cp >= 65 && cp <= 90) {
      out += String.fromCharCode(cp + 32);
      continue;
    }
    if (cp >= 97 && cp <= 122) {
      out += ch;
      continue;
    }

    // Fullwidth Latin
    if (cp >= 0xff21 && cp <= 0xff3a) {
      out += String.fromCharCode(cp - 0xff21 + 97);
      continue;
    }
    if (cp >= 0xff41 && cp <= 0xff5a) {
      out += String.fromCharCode(cp - 0xff41 + 97);
      continue;
    }

    // Mathematical Alphanumeric Symbols (Discord "aesthetic" fonts)
    // Contiguous A–Z / a–z blocks (skip known holes by range tables)
    const math = mathAlphaToAscii(cp);
    if (math) {
      out += math;
      continue;
    }

    // Circled Latin letters Ⓐ-Ⓩ / ⓐ-ⓩ
    if (cp >= 0x24b6 && cp <= 0x24cf) {
      out += String.fromCharCode(cp - 0x24b6 + 97);
      continue;
    }
    if (cp >= 0x24d0 && cp <= 0x24e9) {
      out += String.fromCharCode(cp - 0x24d0 + 97);
      continue;
    }

    // Drop decorations / separators / emoji — keep letters only
  }
  return out;
}

function mathAlphaToAscii(cp: number): string | null {
  // [start, endInclusive, asciiBase ('a' or 'A' then lowercased)]
  const ranges: [number, number, number][] = [
    [0x1d400, 0x1d419, 97], // bold A-Z
    [0x1d41a, 0x1d433, 97], // bold a-z
    [0x1d434, 0x1d44d, 97], // italic A-Z
    [0x1d44e, 0x1d467, 97], // italic a-z
    [0x1d468, 0x1d481, 97], // bold italic A-Z
    [0x1d482, 0x1d49b, 97], // bold italic a-z
    [0x1d4d0, 0x1d4e9, 97], // bold script A-Z
    [0x1d4ea, 0x1d503, 97], // bold script a-z
    [0x1d504, 0x1d51c, 97], // fraktur A-Z (holes handled below)
    [0x1d51e, 0x1d537, 97], // fraktur a-z
    [0x1d56c, 0x1d585, 97], // bold fraktur A-Z
    [0x1d586, 0x1d59f, 97], // bold fraktur a-z
    [0x1d5a0, 0x1d5b9, 97], // sans A-Z
    [0x1d5ba, 0x1d5d3, 97], // sans a-z
    [0x1d5d4, 0x1d5ed, 97], // sans bold A-Z
    [0x1d5ee, 0x1d607, 97], // sans bold a-z
    [0x1d608, 0x1d621, 97], // sans italic A-Z
    [0x1d622, 0x1d63b, 97], // sans italic a-z
    [0x1d63c, 0x1d655, 97], // sans bold italic A-Z
    [0x1d656, 0x1d66f, 97], // sans bold italic a-z
    [0x1d670, 0x1d689, 97], // monospace A-Z
    [0x1d68a, 0x1d6a3, 97], // monospace a-z
  ];

  for (const [start, end, base] of ranges) {
    if (cp >= start && cp <= end) {
      return String.fromCharCode(base + (cp - start));
    }
  }

  // Double-struck / script holes mapped individually (common Discord fonts)
  const singles: Record<number, string> = {
    0x1d538: "a",
    0x1d539: "b",
    0x2102: "c", // ℂ
    0x1d53b: "d",
    0x1d53c: "e",
    0x1d53d: "f",
    0x1d53e: "g",
    0x210d: "h", // ℍ
    0x1d540: "i",
    0x1d541: "j",
    0x1d542: "k",
    0x1d543: "l",
    0x1d544: "m",
    0x2115: "n", // ℕ
    0x1d546: "o",
    0x2119: "p", // ℙ
    0x211a: "q", // ℚ
    0x211d: "r", // ℝ
    0x1d54a: "s",
    0x1d54b: "t",
    0x1d54c: "u",
    0x1d54d: "v",
    0x1d54e: "w",
    0x1d54f: "x",
    0x1d550: "y",
    0x2124: "z", // ℤ
    // double-struck lowercase
    0x1d552: "a",
    0x1d553: "b",
    0x1d554: "c",
    0x1d555: "d",
    0x1d556: "e",
    0x1d557: "f",
    0x1d558: "g",
    0x1d559: "h",
    0x1d55a: "i",
    0x1d55b: "j",
    0x1d55c: "k",
    0x1d55d: "l",
    0x1d55e: "m",
    0x1d55f: "n",
    0x1d560: "o",
    0x1d561: "p",
    0x1d562: "q",
    0x1d563: "r",
    0x1d564: "s",
    0x1d565: "t",
    0x1d566: "u",
    0x1d567: "v",
    0x1d568: "w",
    0x1d569: "x",
    0x1d56a: "y",
    0x1d56b: "z",
  };
  return singles[cp] || null;
}

const GPSL_MONTHS = [
  "september",
  "november",
  "december",
  "february",
  "october",
  "january",
  "august",
  "april",
  "march",
  "june",
  "july",
  "may",
] as const;

function normalizeMonth(raw: string | null | undefined): string | null {
  const original = String(raw || "").trim();
  if (!original) return null;

  const lower = original.toLowerCase();
  if ((GPSL_MONTHS as readonly string[]).includes(lower)) return lower;

  // Plain ASCII word in name: "videos-october", "October Matchday"
  const word = lower.match(
    /\b(june|july|august|september|october|november|december|january|february|march|april|may)\b/i
  );
  if (word) return word[1].toLowerCase();

  // Fancy fonts / separators: "𝕆𝕔𝕥𝕠𝕓𝕖𝕣", "O·C·T·O·B·E·R", "𝕆 ℂ 𝕋 …"
  const folded = foldChannelLetters(original);
  for (const month of GPSL_MONTHS) {
    if (folded.includes(month)) return month;
  }
  return null;
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
  owners: OwnerMaps,
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
    if (!isAllowedVideoUrl(link.url)) continue;
    candidates.push({
      id: `${msg.id}:${link.id}`,
      filename: link.label,
      url: link.url,
    });
  }

  // Fallback: file attachments (optional)
  for (const a of msg.attachments || []) {
    if (!a || !(a.url || a.proxy_url) || !looksLikeVideo(a)) continue;
    const url = a.url || a.proxy_url || "";
    if (!isAllowedVideoUrl(url)) continue;
    candidates.push({
      id: a.id || `${msg.id}:file`,
      filename: a.filename || "",
      url,
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
  // Prefer Discord snowflake → gpsl_owner_registry; fall back to owner tag / nick
  const club =
    owners.byDiscordId.get(String(msg.author.id)) ||
    matchClubByTags(owners.byTag, owners.clubShorts, keys);

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

  // ✅ matched · ⏳ held until GPSL result confirmed · ⚠️ real failure
  const freshMatch = out.some(
    (r) => r.ok === true && r.status === "matched" && Number(r.credited || 0) >= 0
  );
  const freshPending = out.some(
    (r) => r.ok === true && r.status === "pending"
  );
  const freshFail = out.every((r) => r.ok === false);
  if (freshMatch && out.some((r) => r.status === "matched")) {
    await addReaction(botToken, channelId, msg.id, "✅");
  } else if (freshPending) {
    await addReaction(botToken, channelId, msg.id, "⏳");
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

    // ----- Sync competition codes guide (#upload-codes) -----
    if (body.mode === "sync_codes" || body.sync_codes === true) {
      const botToken = Deno.env.get("DISCORD_BOT_TOKEN");
      if (!botToken || !guildId) {
        return jsonResponse(
          { error: "Missing DISCORD_BOT_TOKEN / DISCORD_GUILD_ID" },
          500
        );
      }
      try {
        const out = await syncCompetitionCodesGuide(
          adminClient,
          botToken,
          guildId,
          categoryId || null
        );
        return jsonResponse(out, out.ok === false ? 400 : 200);
      } catch (e) {
        return jsonResponse(
          {
            ok: false,
            mode: "sync_codes",
            error: e instanceof Error ? e.message : String(e),
          },
          500
        );
      }
    }

    // ----- Push mode (single message / attachments) -----
    const msgPush = body.message as DiscordMessage | undefined;
    const pushAtts: DiscordAttachment[] = [];
    if (Array.isArray(body.attachments)) {
      pushAtts.push(...(body.attachments as DiscordAttachment[]));
    }
    if (Array.isArray(msgPush?.attachments)) {
      pushAtts.push(...(msgPush!.attachments || []));
    }
    const wantPoll =
      body.poll === true ||
      body.mode === "poll" ||
      (!body.message &&
        !body.attachments &&
        !body.discord_attachment_id &&
        !body.filename &&
        !body.video_url);

    const hasPush =
      !wantPoll &&
      (pushAtts.length > 0 ||
        body.discord_attachment_id ||
        body.filename ||
        body.video_url ||
        parseMarkdownVideoLinks(
          String(body.content || msgPush?.content || "")
        ).length > 0);

    if (hasPush) {
      if (!botToken || !guildId) {
        return jsonResponse(
          { error: "Missing DISCORD_BOT_TOKEN / DISCORD_GUILD_ID" },
          500
        );
      }
      const owners = await buildOwnerMaps(adminClient);
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
        owners,
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
          "No month channels found under the category — channel name must contain a GPSL month (january…may). Fancy Unicode fonts / separators are OK if the month letters are still there.",
        category_id: categoryId || null,
      });
    }

    const owners = await buildOwnerMaps(adminClient);
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
          owners,
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
