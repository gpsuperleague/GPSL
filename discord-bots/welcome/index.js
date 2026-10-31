/**
 * GPSL Discord welcome bot
 *
 * On GUILD_MEMBER_ADD → POST discord-welcome-pack (assign Visitor + DM once).
 *
 * Env:
 *   DISCORD_BOT_TOKEN
 *   DISCORD_GUILD_ID
 *   SUPABASE_URL
 *   DISCORD_WELCOME_INVOKE_KEY  (or DISCORD_FEED_INVOKE_KEY / DISCORD_MATCH_VIDEOS_INVOKE_KEY / service role)
 *
 * Discord Developer Portal: enable Privileged Gateway Intent → Server Members Intent.
 */
import "dotenv/config";
import { Client, GatewayIntentBits, Partials } from "discord.js";

const token = process.env.DISCORD_BOT_TOKEN;
const guildId = process.env.DISCORD_GUILD_ID;
const supabaseUrl = (process.env.SUPABASE_URL || "").replace(/\/$/, "");
const invokeKey =
  process.env.DISCORD_WELCOME_INVOKE_KEY ||
  process.env.DISCORD_FEED_INVOKE_KEY ||
  process.env.DISCORD_MATCH_VIDEOS_INVOKE_KEY ||
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  "";
const welcomeUrl =
  process.env.DISCORD_WELCOME_URL ||
  `${supabaseUrl}/functions/v1/discord-welcome-pack`;

if (!token || !guildId || !supabaseUrl || !invokeKey) {
  console.error(
    "Missing env: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, SUPABASE_URL, DISCORD_WELCOME_INVOKE_KEY (or feed/match-videos key)"
  );
  process.exit(1);
}

async function sendWelcome(discordUserId, displayName) {
  const res = await fetch(welcomeUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${invokeKey}`,
      "x-discord-welcome-key": invokeKey,
      "x-discord-feed-key": invokeKey,
    },
    body: JSON.stringify({
      action: "on_join",
      discord_user_id: discordUserId,
      assign_visitor: true,
      source: "welcome_bot",
      display_name: displayName || null,
    }),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  if (!res.ok) {
    console.error("welcome failed", discordUserId, res.status, json);
  } else {
    console.log("welcome", {
      user: discordUserId,
      name: displayName,
      ok: json?.ok,
      skipped: json?.skipped,
      dm: json?.dm?.ok,
      visitor: json?.visitor_role,
    });
  }
  return json;
}

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMembers],
  partials: [Partials.GuildMember],
});

client.once("ready", () => {
  console.log(`GPSL welcome bot ready as ${client.user?.tag}`);
});

client.on("guildMemberAdd", async (member) => {
  try {
    if (member.user?.bot) return;
    if (member.guild?.id !== guildId) return;
    const name =
      member.displayName ||
      member.user?.globalName ||
      member.user?.username ||
      member.id;
    console.log("guildMemberAdd", name, member.id);
    await sendWelcome(member.id, name);
  } catch (err) {
    console.error("guildMemberAdd error", err);
  }
});

client.login(token);
