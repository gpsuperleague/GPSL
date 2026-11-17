/** Welcome pack copy + Discord DM / Great Hall helpers. */

export const GPSL_SITE = "https://gpsuperleague.github.io/GPSL";

export type WelcomePackAudience = "visitor" | "member";

/** Matches public.gpsl_owner_intake_mode(): live season → mid_season, else pre_season. */
export type WelcomeIntakeMode = "mid_season" | "pre_season";

export type WelcomePackContext = {
  audience?: WelcomePackAudience;
  /** mid_season → claim vacant + handpick; pre_season → wait for club auction. */
  intakeMode?: WelcomeIntakeMode | null;
  /** Reserved for callers; phase copy no longer embeds the label. */
  seasonLabel?: string | null;
};

function link(label: string, path: string): string {
  const href = path.startsWith("http") ? path : `${GPSL_SITE}/${path.replace(/^\//, "")}`;
  return `[${label}](${href})`;
}

function packContext(ctx: WelcomePackContext | WelcomePackAudience = "visitor"): WelcomePackContext {
  return typeof ctx === "string" ? { audience: ctx } : ctx || {};
}

/** One Discord message. Must stay within 2000 including "Hey <@id>". */
export function welcomePackParts(ctx: WelcomePackContext | WelcomePackAudience = "visitor"): string[] {
  const opts = packContext(ctx);
  const audience = opts.audience || "visitor";
  const friendlies = "［𝐆𝐏𝐒𝐋］𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐅𝐫𝐢𝐞𝐧𝐝𝐥𝐢𝐞𝐬";
  const videos = "𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐕𝐢𝐝𝐞𝐨𝐬";
  const who =
    audience === "member"
      ? "You have a **GPSL account** and no club yet."
      : "You're a Discord **Visitor**.";
  const door =
    audience === "member"
      ? `**Your account.** ${link("Open qualifying", "qualifying.html")}. A club stays closed until the stages below are done.`
      : `**Want a club?** ${link("Apply to join GPSL", "join_gpsl.html")}. Qualifying opens. A club stays closed until the stages below are done.`;

  const body = [
    `**Welcome to the GPSL.** ${who}`,
    "",
    `**Just looking?** ${link("Sign in as Visitor", "login.html")} — tables, cups, auctions, transfer market.`,
    `**Need help?** ${link("Beginner's guide", "getting_started.html")} · ${link("GPSL handbook", "learning_gpsl.html")} · ask in [Q&A](https://discord.com/channels/1483974134361886802/1536360993368580136).`,
    "",
    door,
    "",
    "*Stage 1* — **Tag and availability**",
    "Tag, timezone, and when you can play. Both saved, or nothing else unlocks.",
    "",
    "*Stage 2* — **Five friendlies**",
    `Log them in ${friendlies}. Any club, any players, PA3 or PA4. Five within 7 days of joining the GPSL site.`,
    "",
    "*Stage 3* — **Film the last match**",
    `Post your page code with the film in ${videos} within 72 hours of day 7. Staff tick the card. A fail returns only the video.`,
    "Show: settings to ratings, 10 min, injuries off, PA3/PA4 & advanced skill, manager, subtactic, squad, blank instructions, Fluid on screen, no dragging, scoreboard, HUD, ratings.",
    "",
    "*Stage 4* — **Waiting list**",
    "An approved video puts you on the list.",
    "**In season:** pick a vacant division club. 7 days. Keep the cash. GPDB players, one MGDB manager, Handpick green.",
    "**Between seasons:** club auction, if an admin invites you. First club and a backup. Bid only if invited.",
    "",
    "**Your club**",
    "Agree kick-offs. Check in from 10 min before to 10 min after. Record the match, post the video, enter the result. Locks Thursday 7pm UK. Fines come off when they happen. August squad 24–28. Star cap 3 Super League, 2 Championship.",
    "",
    "**Roles** — **Visitor** no account · **Member** qualifying, then the list · **Owner** has a club.",
    "Read the handbook before a club. Do not wait for a fine.",
  ].join("\n");

  return [body];
}

export function welcomePackBody(ctx: WelcomePackContext | WelcomePackAudience = "visitor"): string {
  return welcomePackParts(ctx).join("\n\n");
}

/** Default Visitor copy (static fallback when intake mode unknown). */
export const WELCOME_PACK_BODY = welcomePackBody("visitor");

/** @deprecated use WELCOME_PACK_BODY / welcomePackBody */
export const WELCOME_PACK_CONTENT = WELCOME_PACK_BODY;

const DISCORD_API = "https://discord.com/api/v10";

export function welcomePackMessages(
  discordUserId: string,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): string[] {
  const id = String(discordUserId || "").trim();
  const hello = id ? `Hey <@${id}>` : "Hey";
  const [body] = welcomePackParts(ctx);
  return [`${hello}\n\n${body}`];
}

export function welcomePackWithMention(
  discordUserId: string,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): string {
  return welcomePackMessages(discordUserId, ctx).join("\n\n");
}

export async function discordApi(
  botToken: string,
  path: string,
  init?: RequestInit
): Promise<{ ok: boolean; status: number; json: unknown; text: string }> {
  const res = await fetch(`${DISCORD_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { ok: res.ok, status: res.status, json, text };
}

export async function resolveGreatHallChannelId(
  botToken: string,
  guildId: string
): Promise<string | null> {
  const fromEnv = (
    Deno.env.get("DISCORD_GREAT_HALL_CHANNEL_ID") ||
    Deno.env.get("DISCORD_WELCOME_CHANNEL_ID") ||
    ""
  ).trim();
  if (fromEnv) return fromEnv;

  const res = await discordApi(botToken, `/guilds/${guildId}/channels`);
  if (!res.ok || !Array.isArray(res.json)) return null;

  const channels = res.json as Array<{
    id?: string;
    name?: string;
    type?: number;
  }>;
  // Guild text = 0
  const textChannels = channels.filter((c) => c.type === 0 && c.id && c.name);
  // Discord channel names often use Mathematical Bold (𝐓𝐡𝐞-𝐆𝐫𝐞𝐚𝐭-𝐇𝐚𝐥𝐥).
  const foldMath = (s: string) => {
    let out = "";
    for (const ch of s) {
      const cp = ch.codePointAt(0)!;
      const blocks: Array<[number, number, number]> = [
        [0x1d400, 0x1d419, 65], // bold A–Z
        [0x1d41a, 0x1d433, 97], // bold a–z
        [0x1d434, 0x1d44d, 65], // italic A–Z
        [0x1d44e, 0x1d467, 97],
        [0x1d468, 0x1d481, 65], // bold italic A–Z
        [0x1d482, 0x1d49b, 97],
        [0x1d5d4, 0x1d5ed, 65], // sans bold A–Z
        [0x1d5ee, 0x1d607, 97],
        [0x1d63c, 0x1d655, 65], // sans bold italic A–Z
        [0x1d656, 0x1d66f, 97],
      ];
      let mapped = false;
      for (const [lo, hi, base] of blocks) {
        if (cp >= lo && cp <= hi) {
          out += String.fromCharCode(base + (cp - lo));
          mapped = true;
          break;
        }
      }
      if (!mapped) out += ch;
    }
    return out;
  };
  const norm = (s: string) =>
    foldMath(s)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "");

  const preferredExact = [
    "greathall",
    "thegreathall",
    "greathallgpsl",
    "gpslgreathall",
    "welcome",
    "arrivals",
  ];
  for (const key of preferredExact) {
    const hit = textChannels.find((c) => norm(String(c.name)) === key);
    if (hit?.id) return String(hit.id);
  }
  // Fuzzy: channel name contains "great" + "hall", or greathall
  const fuzzy = textChannels.find((c) => {
    const n = norm(String(c.name));
    return (
      n.includes("greathall") ||
      (n.includes("great") && n.includes("hall"))
    );
  });
  if (fuzzy?.id) return String(fuzzy.id);
  return null;
}

/** Admin helper: list text channels + which one resolveGreatHall would pick. */
export async function listGreatHallCandidates(
  botToken: string,
  guildId: string
): Promise<{
  resolved_id: string | null;
  from_env: string | null;
  text_channels: Array<{ id: string; name: string }>;
}> {
  const fromEnv = (
    Deno.env.get("DISCORD_GREAT_HALL_CHANNEL_ID") ||
    Deno.env.get("DISCORD_WELCOME_CHANNEL_ID") ||
    ""
  ).trim() || null;

  const res = await discordApi(botToken, `/guilds/${guildId}/channels`);
  const text_channels: Array<{ id: string; name: string }> = [];
  if (res.ok && Array.isArray(res.json)) {
    for (const c of res.json as Array<{
      id?: string;
      name?: string;
      type?: number;
    }>) {
      if (c.type === 0 && c.id && c.name) {
        text_channels.push({ id: String(c.id), name: String(c.name) });
      }
    }
    text_channels.sort((a, b) => a.name.localeCompare(b.name));
  }

  const resolved_id = fromEnv || (await resolveGreatHallChannelId(botToken, guildId));
  return { resolved_id, from_env: fromEnv, text_channels };
}

async function postDiscordMessages(
  botToken: string,
  channelId: string,
  parts: string[],
  discordUserId: string
): Promise<{ ok: boolean; error?: string; message_id?: string }> {
  const errors: string[] = [];
  let messageId = "";
  for (let i = 0; i < parts.length; i++) {
    const msg = await discordApi(botToken, `/channels/${channelId}/messages`, {
      method: "POST",
      body: JSON.stringify({
        content: parts[i],
        allowed_mentions: { parse: [], users: [discordUserId] },
      }),
    });
    if (!msg.ok && msg.status !== 200) {
      errors.push(`part${i + 1}_${msg.status}: ${msg.text.slice(0, 120)}`);
      continue;
    }
    messageId = String((msg.json as { id?: string })?.id || messageId);
  }
  return {
    ok: errors.length === 0,
    error: errors.length ? errors.join(" | ") : undefined,
    message_id: messageId || undefined,
  };
}

export async function sendWelcomeDm(
  botToken: string,
  discordUserId: string,
  content?: string,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): Promise<{ ok: boolean; channel_id?: string; error?: string }> {
  const parts = content
    ? [content]
    : welcomePackMessages(discordUserId, ctx);
  const dm = await discordApi(botToken, "/users/@me/channels", {
    method: "POST",
    body: JSON.stringify({ recipient_id: discordUserId }),
  });
  if (!dm.ok) {
    return {
      ok: false,
      error: `dm_open_${dm.status}: ${dm.text.slice(0, 160)}`,
    };
  }
  const channelId = String(
    (dm.json as { id?: string })?.id || ""
  ).trim();
  if (!channelId) {
    return { ok: false, error: "dm_channel_missing" };
  }

  const posted = await postDiscordMessages(botToken, channelId, parts, discordUserId);
  if (!posted.ok) {
    return {
      ok: false,
      channel_id: channelId,
      error: `dm_send_${posted.error}`,
    };
  }
  return { ok: true, channel_id: channelId };
}

export async function sendWelcomeChannel(
  botToken: string,
  guildId: string,
  discordUserId: string,
  channelId?: string | null,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): Promise<{
  ok: boolean;
  channel_id?: string;
  message_id?: string;
  skipped?: string;
  error?: string;
}> {
  const resolved =
    (channelId && String(channelId).trim()) ||
    (await resolveGreatHallChannelId(botToken, guildId));
  if (!resolved) {
    return {
      ok: false,
      skipped: "great_hall_channel_not_found",
      error:
        "Set DISCORD_GREAT_HALL_CHANNEL_ID or name a text channel great-hall",
    };
  }

  const parts = welcomePackMessages(discordUserId, ctx);
  const posted = await postDiscordMessages(botToken, resolved, parts, discordUserId);
  if (!posted.ok) {
    return {
      ok: false,
      channel_id: resolved,
      error: `channel_send_${posted.error}`,
    };
  }
  return {
    ok: true,
    channel_id: resolved,
    message_id: posted.message_id,
  };
}

export async function ensureVisitorRole(
  botToken: string,
  guildId: string,
  discordUserId: string,
  visitorRoleId: string,
  memberRoleId: string,
  ownerRoleId: string
): Promise<{ ok: boolean; assigned: boolean; skipped?: string; error?: string }> {
  const member = await discordApi(
    botToken,
    `/guilds/${guildId}/members/${discordUserId}`
  );
  if (member.status === 404) {
    return { ok: false, assigned: false, skipped: "not_in_guild" };
  }
  if (!member.ok) {
    return {
      ok: false,
      assigned: false,
      error: `member_lookup_${member.status}`,
    };
  }
  const roles = new Set<string>(
    Array.isArray((member.json as { roles?: string[] })?.roles)
      ? ((member.json as { roles: string[] }).roles || []).map(String)
      : []
  );
  if (
    (ownerRoleId && roles.has(ownerRoleId)) ||
    (memberRoleId && roles.has(memberRoleId))
  ) {
    return { ok: true, assigned: false, skipped: "already_member_or_owner" };
  }
  if (visitorRoleId && roles.has(visitorRoleId)) {
    return { ok: true, assigned: false, skipped: "already_visitor" };
  }
  if (!visitorRoleId) {
    return { ok: true, assigned: false, skipped: "visitor_role_not_configured" };
  }
  const put = await discordApi(
    botToken,
    `/guilds/${guildId}/members/${discordUserId}/roles/${visitorRoleId}`,
    { method: "PUT" }
  );
  if (put.ok || put.status === 204) {
    return { ok: true, assigned: true };
  }
  return {
    ok: false,
    assigned: false,
    error: `assign_visitor_${put.status}: ${put.text.slice(0, 160)}`,
  };
}
