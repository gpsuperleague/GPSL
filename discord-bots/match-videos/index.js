/**
 * GPSL Match videos bot
 *
 * Listens for MESSAGE_CREATE in channels under the Matchday videos category
 * (or an explicit channel allow-list), then POSTs video attachments to the
 * discord-match-videos-ingest Edge Function.
 *
 * Env:
 *   DISCORD_BOT_TOKEN
 *   DISCORD_GUILD_ID
 *   DISCORD_MATCH_VIDEOS_CATEGORY_ID   (preferred)
 *   DISCORD_MATCH_VIDEOS_CHANNEL_IDS  (optional comma-separated fallback)
 *   SUPABASE_URL
 *   DISCORD_MATCH_VIDEOS_INVOKE_KEY   (or SUPABASE_SERVICE_ROLE_KEY)
 *   SUPABASE_ANON_KEY                 (optional; Bearer can be invoke key)
 */
import "dotenv/config";
import {
  Client,
  GatewayIntentBits,
  Partials,
  ChannelType,
} from "discord.js";

const token = process.env.DISCORD_BOT_TOKEN;
const guildId = process.env.DISCORD_GUILD_ID;
const categoryId = process.env.DISCORD_MATCH_VIDEOS_CATEGORY_ID || "";
const channelAllow = new Set(
  String(process.env.DISCORD_MATCH_VIDEOS_CHANNEL_IDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
);
const supabaseUrl = (process.env.SUPABASE_URL || "").replace(/\/$/, "");
const invokeKey =
  process.env.DISCORD_MATCH_VIDEOS_INVOKE_KEY ||
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  "";
const ingestPath =
  process.env.DISCORD_MATCH_VIDEOS_INGEST_URL ||
  `${supabaseUrl}/functions/v1/discord-match-videos-ingest`;

const MONTHS = new Set([
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
]);

function monthFromChannelName(name) {
  const s = String(name || "").toLowerCase();
  for (const m of MONTHS) {
    if (s === m || s.includes(m)) return m;
  }
  return null;
}

function isVideoAttachment(att) {
  const name = String(att.name || "").toLowerCase();
  const ct = String(att.contentType || "").toLowerCase();
  if (ct.startsWith("video/")) return true;
  return /\.(mp4|mkv|mov|webm|avi|m4v|mpeg|mpg)$/i.test(name);
}

function channelAllowed(channel) {
  if (!channel) return false;
  if (channelAllow.size && channelAllow.has(channel.id)) return true;
  if (categoryId && channel.parentId === categoryId) return true;
  return false;
}

async function ingestMessage(message, channelMonth) {
  const attachments = [...message.attachments.values()]
    .filter(isVideoAttachment)
    .map((a) => ({
      id: a.id,
      filename: a.name,
      url: a.url,
      proxy_url: a.proxyURL,
      content_type: a.contentType,
    }));

  if (!attachments.length) return null;

  const res = await fetch(ingestPath, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${invokeKey}`,
      "x-discord-match-videos-key": invokeKey,
    },
    body: JSON.stringify({
      discord_message_id: message.id,
      discord_channel_id: message.channelId,
      discord_user_id: message.author?.id,
      channel_month: channelMonth,
      author: {
        id: message.author?.id,
        username: message.author?.username,
        global_name: message.author?.globalName,
        discriminator: message.author?.discriminator,
      },
      member: message.member
        ? { nick: message.member.nickname }
        : null,
      attachments,
      react: true,
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
    console.error("ingest failed", res.status, json);
  } else {
    console.log("ingest ok", {
      message: message.id,
      month: channelMonth,
      matched: json?.matched,
      results: json?.results?.map((r) => ({
        ok: r.ok,
        side: r.side,
        credited: r.credited,
        reason: r.reason,
      })),
    });
  }
  return json;
}

if (!token || !guildId || !supabaseUrl || !invokeKey) {
  console.error(
    "Missing env: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, SUPABASE_URL, DISCORD_MATCH_VIDEOS_INVOKE_KEY (or service role)"
  );
  process.exit(1);
}

if (!categoryId && channelAllow.size === 0) {
  console.warn(
    "Warning: set DISCORD_MATCH_VIDEOS_CATEGORY_ID or DISCORD_MATCH_VIDEOS_CHANNEL_IDS"
  );
}

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.GuildMembers,
  ],
  partials: [Partials.Channel, Partials.Message],
});

client.once("ready", () => {
  console.log(`GPSL match-videos bot ready as ${client.user?.tag}`);
});

client.on("messageCreate", async (message) => {
  try {
    if (message.author?.bot) return;
    if (message.guildId !== guildId) return;
    if (message.channel?.type !== ChannelType.GuildText) return;
    if (!channelAllowed(message.channel)) return;
    if (!message.attachments?.size) return;

    const month = monthFromChannelName(message.channel.name);
    await ingestMessage(message, month);
  } catch (err) {
    console.error("messageCreate error", err);
  }
});

client.login(token);
