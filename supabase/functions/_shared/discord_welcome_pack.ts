/** Welcome pack copy + Discord DM / Great Hall helpers. */

export const GPSL_SITE = "https://gpsuperleague.github.io/GPSL";

export type WelcomePackAudience = "visitor" | "member";

/** Matches public.gpsl_owner_intake_mode(): live season → mid_season, else pre_season. */
export type WelcomeIntakeMode = "mid_season" | "pre_season";

export type WelcomePackContext = {
  audience?: WelcomePackAudience;
  /** When omitted, copy explains both paths without claiming “we are X right now”. */
  intakeMode?: WelcomeIntakeMode | null;
  /** e.g. 2025/26 — shown in the “right now” line when known. */
  seasonLabel?: string | null;
};

function link(label: string, path: string): string {
  const href = path.startsWith("http") ? path : `${GPSL_SITE}/${path.replace(/^\//, "")}`;
  return `[${label}](${href})`;
}

function nowLine(
  mode: WelcomeIntakeMode | null | undefined,
  seasonLabel: string | null | undefined
): string | null {
  const season = seasonLabel?.trim() ? ` (${seasonLabel.trim()})` : "";
  if (mode === "mid_season") {
    return `**Right now:** mid-season${season} — free clubs can be claimed from the waiting list (no auction).`;
  }
  if (mode === "pre_season") {
    return `**Right now:** pre-season / setup${season} — new clubs are filled by the **club draft auction** when a slot opens.`;
  }
  return null;
}

export function welcomePackBody(ctx: WelcomePackContext | WelcomePackAudience = "visitor"): string {
  const opts: WelcomePackContext =
    typeof ctx === "string" ? { audience: ctx } : ctx || {};
  const audience = opts.audience || "visitor";
  const mode = opts.intakeMode ?? null;
  const seasonLabel = opts.seasonLabel ?? null;

  const who =
    audience === "member"
      ? "You have a **GPSL account** but no club yet (Member)."
      : "You're in Discord as a **Visitor** — you can hang out here and browse the site read-only until you apply.";

  const calendar = nowLine(mode, seasonLabel);

  const browse = [
    "**Browse first (optional)**",
    `${link("Sign in as Visitor", "login.html")} — league tables, cups, auctions and the transfer market (read only). No club needed.`,
  ];

  const applyBlock = [
    "**Want a club?**",
    `${link("Apply to join GPSL", "join_gpsl.html")} — creates your account and puts you on the **waiting list** (order by Discord join date). You do **not** need to DM an admin.`,
  ];

  let pathDetail: string[];
  if (mode === "mid_season") {
    pathDetail = [
      "",
      "**What happens next (mid-season)**",
      `1. After applying, open the ${link("waiting list", "waiting_list.html")}.`,
      "2. If a club shows as vacant, claim it.",
      `3. ${link("Build your starting squad (handpick)", "handpick_squad.html")} and submit for approval — no auction.`,
      `4. Fill in your ${link("owner profile", "awaiting_club.html")} (Discord tag, timezone, when you can play).`,
    ];
  } else if (mode === "pre_season") {
    pathDetail = [
      "",
      "**What happens next (pre-season)**",
      `1. After applying, open the ${link("waiting list", "waiting_list.html")}.`,
      `2. Fill in your ${link("owner profile", "awaiting_club.html")} (Discord tag, timezone, when you can play).`,
      `3. When a slot opens, admin invites you to the ${link("club draft auction", "club_auction.html")} — you bid for a club there.`,
    ];
  } else {
    pathDetail = [
      "",
      "**What happens next** (depends on the calendar)",
      `• **Mid-season** (league already running): on the ${link("waiting list", "waiting_list.html")} claim a vacant club → ${link("handpick your squad", "handpick_squad.html")} → submit for approval.`,
      `• **Pre-season / setup**: stay on the waiting list, complete your ${link("owner profile", "awaiting_club.html")}, then join the ${link("club draft auction", "club_auction.html")} when invited.`,
    ];
  }

  const extras = [
    "",
    "**Useful links**",
    `• ${link("League handbook (how GPSL works)", "learning_gpsl.html")}`,
    `• ${link("Full welcome page on the site", "welcome_gpsl.html")}`,
    "",
    "**Roles (quick)**",
    "• **Visitor** — in Discord, no GPSL account yet",
    "• **Member** — GPSL account, no club yet (waiting list)",
    "• **Owner** — has a club",
    "",
    "**Learning the rules**",
    "Nobody expects you to know every rule on day one. After a few matches we do expect you to know the basics (scheduling, check-in, results, transfers). Use the handbook, ask in Discord, learn as you play.",
    "",
    "Questions → ask in Discord. Applying for a place does **not** need a DM to admin.",
  ];

  return [
    who,
    calendar ? ["", calendar] : [],
    "",
    ...browse,
    "",
    ...applyBlock,
    ...pathDetail,
    ...extras,
  ]
    .flat()
    .join("\n");
}

/** Default Visitor copy (static fallback when intake mode unknown). */
export const WELCOME_PACK_BODY = welcomePackBody("visitor");

/** @deprecated use WELCOME_PACK_BODY / welcomePackBody */
export const WELCOME_PACK_CONTENT = WELCOME_PACK_BODY;

const DISCORD_API = "https://discord.com/api/v10";

export function welcomePackWithMention(
  discordUserId: string,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): string {
  const opts: WelcomePackContext =
    typeof ctx === "string" ? { audience: ctx } : ctx || {};
  const audience = opts.audience || "visitor";
  const id = String(discordUserId || "").trim();
  const mention = id ? `<@${id}>` : "";
  const hello =
    audience === "member"
      ? mention
        ? `Hey ${mention}`
        : "Hey"
      : mention
        ? `Hey ${mention}`
        : "Hey";
  return [hello, "", welcomePackBody(opts)].join("\n");
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

export async function sendWelcomeDm(
  botToken: string,
  discordUserId: string,
  content?: string,
  ctx: WelcomePackContext | WelcomePackAudience = "visitor"
): Promise<{ ok: boolean; channel_id?: string; error?: string }> {
  const body =
    content ||
    welcomePackWithMention(
      discordUserId,
      typeof ctx === "string" ? { audience: ctx } : ctx
    );
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

  const msg = await discordApi(botToken, `/channels/${channelId}/messages`, {
    method: "POST",
    body: JSON.stringify({
      content: body,
      allowed_mentions: { users: [discordUserId] },
    }),
  });
  if (!msg.ok && msg.status !== 200) {
    return {
      ok: false,
      channel_id: channelId,
      error: `dm_send_${msg.status}: ${msg.text.slice(0, 160)}`,
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

  const packCtx: WelcomePackContext =
    typeof ctx === "string" ? { audience: ctx } : ctx || {};

  const msg = await discordApi(botToken, `/channels/${resolved}/messages`, {
    method: "POST",
    body: JSON.stringify({
      content: welcomePackWithMention(discordUserId, packCtx),
      allowed_mentions: { parse: [], users: [discordUserId] },
    }),
  });
  if (!msg.ok && msg.status !== 200) {
    return {
      ok: false,
      channel_id: resolved,
      error: `channel_send_${msg.status}: ${msg.text.slice(0, 160)}`,
    };
  }
  const messageId = String(
    (msg.json as { id?: string })?.id || ""
  ).trim();
  return { ok: true, channel_id: resolved, message_id: messageId || undefined };
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
