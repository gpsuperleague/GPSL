/** Welcome pack copy + Discord DM / Great Hall helpers. */

export const GPSL_SITE = "https://gpsuperleague.github.io/GPSL";

export type WelcomePackAudience = "visitor" | "member";

export function welcomePackBody(
  audience: WelcomePackAudience = "visitor"
): string {
  const statusLine =
    audience === "member"
      ? "You're currently in as a **Member**, without a club — GPSL account ready; waiting list / next steps below."
      : "You're in as a **Visitor** — hang out in Discord and browse the site read-only.";

  const nextSteps =
    audience === "member"
      ? [
          "**Next**",
          "1. Confirm waiting list + owner details on the site",
          `2. Handbook: ${GPSL_SITE}/learning_gpsl.html`,
          "3. Path **b** (auction) or **c** (pick club → handpick), depending on the calendar",
        ]
      : [
          "**Then**",
          "1. Waiting list + owner details on the site",
          `2. Handbook: ${GPSL_SITE}/learning_gpsl.html`,
          "3. Path **b** (auction) or **c** (pick club → handpick), depending on the calendar",
        ];

  return [
    "**Welcome to GPSL**",
    "",
    statusLine,
    "",
    "**a. Just watching?**",
    `Sign in as Visitor: ${GPSL_SITE}/login.html`,
    "→ **Visitor — sign in with Discord** (tables, cups, auctions, market — read only).",
    "",
    "**b. Want a club (draft / pre-season)?**",
    `Apply (no need to message admin): ${GPSL_SITE}/join_gpsl.html`,
    "→ Creates your account + waiting list (by Discord join date).",
    "When a slot opens, admin invites you to the **club draft auction**.",
    "",
    "**c. Want a club mid-season?**",
    "Same apply link. On the waiting list, **pick a vacant club**, then go straight into",
    "**handpick** (build from scratch) and **submit for approval** — no auction.",
    `Waiting list: ${GPSL_SITE}/waiting_list.html`,
    `Handpick: ${GPSL_SITE}/handpick_squad.html`,
    "",
    ...nextSteps,
    "",
    "**Roles**",
    "• **Visitor** — in Discord, no GPSL owner account yet",
    "• **Member** — GPSL account, no club yet (waiting list / etc.)",
    "• **Owner** — has a club",
    "",
    "**Learning the rules**",
    "GPSL does **not** expect a new owner to know every rule on day one.",
    "After several games in, we do expect **strong familiarity** with how the league works",
    "(scheduling, check-in, results, transfers). Use the handbook, ask in Discord, and learn as you play.",
    "",
    `Full pack: ${GPSL_SITE}/welcome_gpsl.html`,
    "",
    "Questions → ask in Discord. Applying for a place doesn't need a DM to admin.",
  ].join("\n");
}

/** Default Visitor copy (cron / on_join). */
export const WELCOME_PACK_BODY = welcomePackBody("visitor");

/** @deprecated use WELCOME_PACK_BODY / welcomePackBody */
export const WELCOME_PACK_CONTENT = WELCOME_PACK_BODY;

const DISCORD_API = "https://discord.com/api/v10";

export function welcomePackWithMention(
  discordUserId: string,
  audience: WelcomePackAudience = "visitor"
): string {
  const id = String(discordUserId || "").trim();
  const mention = id ? `<@${id}>` : "";
  const hello =
    audience === "member"
      ? mention
        ? `Hey ${mention} — you're a GPSL **Member**.`
        : "Hey — you're a GPSL **Member**."
      : mention
        ? `Hey ${mention} — welcome!`
        : "Hey — welcome!";
  return [hello, "", welcomePackBody(audience)].join("\n");
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
  const norm = (s: string) =>
    s.toLowerCase().replace(/[^a-z0-9]+/g, "");

  const preferred = [
    "greathall",
    "thegreathall",
    "great-hall",
    "welcome",
    "arrivals",
  ];
  for (const key of preferred) {
    const hit = textChannels.find((c) => {
      const n = norm(String(c.name));
      return n === norm(key) || n.includes("greathall");
    });
    if (hit?.id) return String(hit.id);
  }
  return null;
}

export async function sendWelcomeDm(
  botToken: string,
  discordUserId: string,
  content?: string,
  audience: WelcomePackAudience = "visitor"
): Promise<{ ok: boolean; channel_id?: string; error?: string }> {
  const body = content || welcomePackWithMention(discordUserId, audience);
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
  audience: WelcomePackAudience = "visitor"
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

  const msg = await discordApi(botToken, `/channels/${resolved}/messages`, {
    method: "POST",
    body: JSON.stringify({
      content: welcomePackWithMention(discordUserId, audience),
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
