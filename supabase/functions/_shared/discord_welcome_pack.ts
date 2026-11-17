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

/** Two Discord messages. Part 1 is the qualify path. Part 2 is the club and the week. */
export function welcomePackParts(ctx: WelcomePackContext | WelcomePackAudience = "visitor"): string[] {
  const opts = packContext(ctx);
  const audience = opts.audience || "visitor";
  const who =
    audience === "member"
      ? "You have a **GPSL account** and no club yet."
      : "You're in Discord as a **Visitor**. Browse the site read-only until you apply.";
  const door =
    audience === "member"
      ? [
          "**Your account**",
          `Open ${link("Become an owner", "qualifying.html")} and start at the first step still open. A club stays closed until you pass the steps below.`,
        ]
      : [
          "**Want a club?**",
          `${link("Apply to join GPSL", "join_gpsl.html")}. That creates your account and opens one page: ${link("Become an owner", "qualifying.html")}. A club stays closed until you pass the steps below.`,
        ];

  const part1 = [
    "**Welcome**",
    who,
    "",
    "**Just looking?**",
    `${link("Sign in as Visitor", "login.html")} — tables, cups, auctions and the transfer market, read only. No club needed.`,
    "",
    ...door,
    "",
    "**1. Tag and availability**",
    "Set the owner tag people will see, your timezone, and the times you can play. Nothing else unlocks until both are saved.",
    "",
    "**2. Five friendlies**",
    "Play them in ［𝐆𝐏𝐒𝐋］𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐅𝐫𝐢𝐞𝐧𝐝𝐥𝐢𝐞𝐬. Both owners post the score with their tags. It counts when the other post matches. Practice side, not a league club. Any players. PA3 or PA4. Five finished games. They do not touch league stats, injuries, fitness, or fines. Missing the first week does not delete your account.",
    "",
    "**3. Film the latest one**",
    "The page gives you a code. Put it in the filename and post the video in 𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐕𝐢𝐝𝐞𝐨𝐬. Staff tick a card. If something fails, they name the ticks and only the video comes back. Play another friendly, log it, and send a new recording with the new code. The five already logged still count.",
    "",
    "**What the recording has to show**",
    "Start before the match-room settings and stop after the player ratings.",
    "• 10-minute match, injuries off",
    "• PA3 or PA4 before kick-off. PA1 and PA2 are not allowed. Advanced skill only",
    "• Match-room settings, manager, subtactic, and squad on screen",
    "• Player instructions on screen, and left blank",
    "• Sub tactic and Fluid are a default formation, set before the match. Do not drag players",
    "• Scoreboard and HUD on for the whole match. After the whistle, the ratings and player of the match",
    "",
    "**4. The waiting list**",
    "An approved video puts you on the waiting list. You do not pick a club yourself.",
  ].join("\n");

  const part2 = [
    "**Season in full flow**",
    "An admin names the one vacant club you can handpick. You have 7 days to take it. You keep that club's cash, the old squad is released, and you build a new one on the site.",
    "",
    `• In ${link("GPDB", "GPDB.html")}, tick free agents. Check the player is still in eFootball. A tick is not a signing.`,
    `• ${link("Handpick Squad", "handpick_squad.html")} has to be green: squad size, home-grown, under-21s, a goalkeeper, the star cap, and the cash.`,
    `• In ${link("MGDB", "MGDB.html")}, tick one manager.`,
    "• Submit the squad and the manager together. Staff approve. The fees leave the club then.",
    "",
    "**A week, once the club is yours**",
    "• Agree a kick-off. The other club has 48 hours to accept or send another time. Agreeing in Discord still has to be locked on the site by both clubs.",
    "• Check in from 10 minutes before kick-off until 10 minutes after.",
    "• Play it on eFootball.",
    "• Record it, from the match-room settings through to the ratings, and post your own video. The result only counts if the video does.",
    "• Enter the result on Match Day.",
    "",
    "A GPSL month is about a week. It locks every Thursday at 7pm UK. Fines come off the balance when they happen. From August the squad is 24 to 28, with home-grown, under-21s, a goalkeeper, and a star cap: 3 in the Super League, 2 in the Championship.",
    "",
    "**Between seasons**",
    "Same waiting list. The door is the club auction. An admin invites you. You mark a first club and a backup, and you bid only if invited. The bid pays for the club and the stadium. What is left is your balance. Squad and manager then come through the drafts.",
    "",
    "**Roles**",
    "• **Visitor** — in Discord, no GPSL account yet",
    "• **Member** — account, then qualifying, then the waiting list",
    "• **Owner** — has a club",
    "",
    `Read the ${link("league handbook", "learning_gpsl.html")} before you take a club. Ask in Discord when something is unclear. Do not wait for a fine to find out.`,
  ].join("\n");

  return [part1, part2];
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
  const [first, second] = welcomePackParts(ctx);
  return [`${hello}\n\n${first}`, second];
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
