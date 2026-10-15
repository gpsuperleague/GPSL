import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import nacl from "npm:tweetnacl@1.0.3";
import {
  OFF_VALUE,
  languageLabel,
  normalizeLanguage,
  searchLanguages,
  translateTexts,
  translationConfigured,
} from "./translate.ts";

// Discord HTTP interactions:
//   * message command "Translate" — private reply in the user's language
//   * /language — choose that language (also settable on Owner Details)
//   * /english — turn your own text into English to paste in a channel
// Internal (feed invoke key / service_role):
//   * { action: "flush_dms" } — translated DMs for queued league announcements
//   * { action: "register_commands" } — create/update the guild commands
//   * { action: "diagnose" }

const DISCORD_API = "https://discord.com/api/v10";
const EPHEMERAL = 64;

const IX_PING = 1;
const IX_COMMAND = 2;
const IX_AUTOCOMPLETE = 4;

const RESP_PONG = 1;
const RESP_MESSAGE = 4;
const RESP_DEFERRED = 5;
const RESP_AUTOCOMPLETE = 8;

const CMD_TRANSLATE = "Translate";
const CMD_LANGUAGE = "language";
const CMD_ENGLISH = "english";

const MAX_SOURCE_CHARS = 3000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-signature-ed25519, x-signature-timestamp",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

let cachedPublicKey = "";

/** DISCORD_PUBLIC_KEY secret, else the application's verify_key via the bot token. */
async function discordPublicKey(): Promise<string> {
  const fromEnv = Deno.env.get("DISCORD_PUBLIC_KEY") || "";
  if (fromEnv) return fromEnv;
  if (cachedPublicKey) return cachedPublicKey;
  const botToken = Deno.env.get("DISCORD_BOT_TOKEN") || "";
  if (!botToken) return "";
  try {
    const res = await fetch(`${DISCORD_API}/oauth2/applications/@me`, {
      headers: { Authorization: `Bot ${botToken}` },
    });
    if (!res.ok) return "";
    const app = (await res.json()) as { verify_key?: string };
    cachedPublicKey = String(app.verify_key || "");
  } catch {
    cachedPublicKey = "";
  }
  return cachedPublicKey;
}

function verifyDiscordSignature(
  publicKey: string,
  signature: string,
  timestamp: string,
  rawBody: string
): boolean {
  try {
    return nacl.sign.detached.verify(
      new TextEncoder().encode(timestamp + rawBody),
      hexToBytes(signature),
      hexToBytes(publicKey)
    );
  } catch {
    return false;
  }
}

function adminClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
  );
}

// ---------------------------------------------------------------------------
// Interactions
// ---------------------------------------------------------------------------

type Embed = {
  title?: string;
  description?: string;
  fields?: { name: string; value: string }[];
  footer?: { text?: string };
};

type DiscordMessage = { content?: string; embeds?: Embed[]; author?: { username?: string } };

type Interaction = {
  type: number;
  token: string;
  application_id: string;
  member?: { nick?: string | null; user?: { id: string; username?: string; global_name?: string | null } };
  user?: { id: string; username?: string; global_name?: string | null };
  data?: {
    name?: string;
    target_id?: string;
    options?: { name: string; value?: string; focused?: boolean }[];
    resolved?: { messages?: Record<string, DiscordMessage> };
  };
};

function messageText(msg: DiscordMessage | undefined): string {
  if (!msg) return "";
  const parts: string[] = [];
  if (msg.content) parts.push(msg.content);
  for (const e of msg.embeds || []) {
    if (e.title) parts.push(e.title);
    if (e.description) parts.push(e.description);
    for (const f of e.fields || []) parts.push(`${f.name}\n${f.value}`);
  }
  return parts.join("\n\n").trim().slice(0, MAX_SOURCE_CHARS);
}

function optionValue(ix: Interaction, name: string): string {
  return String(ix.data?.options?.find((o) => o.name === name)?.value ?? "");
}

async function editOriginal(ix: Interaction, payload: Record<string, unknown>) {
  await fetch(
    `${DISCORD_API}/webhooks/${ix.application_id}/${ix.token}/messages/@original`,
    {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ allowed_mentions: { parse: [] }, ...payload }),
    }
  );
}

const NO_LANGUAGE_TEXT =
  "Pick your language first: type **/language** and choose it from the list " +
  "(or set it on your GPSL **Owner Details** page). Then use Translate again.";

async function lookupLanguage(userId: string, ix?: Interaction): Promise<string | null> {
  const db = adminClient();
  const { data, error } = await db.rpc("gpsl_discord_language_for_user", {
    p_discord_user_id: userId,
  });
  if (error) throw new Error(error.message);
  if (data) return data as string;
  if (!ix) return null;

  // Owner not linked to this Discord id yet: match their owner tag to the caller's names
  const u = ix.member?.user || ix.user;
  const names = [ix.member?.nick, u?.global_name, u?.username].filter(
    (n): n is string => typeof n === "string" && n.trim() !== ""
  );
  if (!names.length) return null;
  const { data: linked, error: linkErr } = await db.rpc("gpsl_discord_link_owner_by_names", {
    p_discord_user_id: userId,
    p_names: names,
  });
  if (linkErr) {
    console.warn("gpsl_discord_link_owner_by_names:", linkErr.message);
    return null;
  }
  return (linked as string | null) || null;
}

async function runTranslate(ix: Interaction, userId: string) {
  try {
    const lang = await lookupLanguage(userId, ix);
    if (!lang) {
      await editOriginal(ix, { content: NO_LANGUAGE_TEXT });
      return;
    }
    const msg = ix.data?.resolved?.messages?.[ix.data?.target_id || ""];
    const text = messageText(msg);
    if (!text) {
      await editOriginal(ix, { content: "That message has no text to translate." });
      return;
    }
    const { texts, detected } = await translateTexts([text], lang);
    await editOriginal(ix, {
      embeds: [
        {
          description: (texts[0] || "").slice(0, 4000),
          color: 0x5865f2,
          footer: {
            text: `${languageLabel(lang)} · translated from ${detected || "?"} · only you can see this`,
          },
        },
      ],
    });
  } catch (err) {
    await editOriginal(ix, {
      content: `Translation failed: ${err instanceof Error ? err.message : String(err)}`.slice(0, 1900),
    });
  }
}

async function runSetLanguage(ix: Interaction, userId: string) {
  try {
    const raw = optionValue(ix, "language");
    const code = normalizeLanguage(raw);
    if (code === undefined) {
      await editOriginal(ix, {
        content: `I don't know "${raw.slice(0, 50)}". Start typing in /language and pick from the list.`,
      });
      return;
    }
    const { data, error } = await adminClient().rpc("gpsl_discord_language_set", {
      p_discord_user_id: userId,
      p_language: code ?? OFF_VALUE,
    });
    if (error) throw new Error(error.message);
    const res = (data || {}) as { ok?: boolean; reason?: string };
    if (!res.ok) throw new Error(res.reason || "save failed");
    await editOriginal(ix, {
      content: code
        ? `Saved: **${languageLabel(code)}**. Right-click any message → **Apps → Translate** to read it in your language. ` +
          "League announcements will also reach you as a translated DM."
        : "Translation turned off (English).",
    });
  } catch (err) {
    await editOriginal(ix, {
      content: `Could not save: ${err instanceof Error ? err.message : String(err)}`.slice(0, 1900),
    });
  }
}

async function runToEnglish(ix: Interaction) {
  try {
    const text = optionValue(ix, "text").slice(0, MAX_SOURCE_CHARS);
    if (!text.trim()) {
      await editOriginal(ix, { content: "Nothing to translate." });
      return;
    }
    const { texts } = await translateTexts([text], "EN-GB");
    await editOriginal(ix, {
      content:
        "English version — copy and paste it into the channel:\n\n" +
        (texts[0] || "").slice(0, 1800),
    });
  } catch (err) {
    await editOriginal(ix, {
      content: `Translation failed: ${err instanceof Error ? err.message : String(err)}`.slice(0, 1900),
    });
  }
}

function deferEphemeral(work: Promise<void>): Response {
  EdgeRuntime.waitUntil(work);
  return json({ type: RESP_DEFERRED, data: { flags: EPHEMERAL } });
}

function handleInteraction(ix: Interaction): Response {
  if (ix.type === IX_PING) return json({ type: RESP_PONG });

  const userId = ix.member?.user?.id || ix.user?.id || "";
  const name = ix.data?.name || "";

  if (ix.type === IX_AUTOCOMPLETE && name === CMD_LANGUAGE) {
    const focused = ix.data?.options?.find((o) => o.focused)?.value ?? "";
    const choices = searchLanguages(String(focused))
      .slice(0, 24)
      .map((l) => ({ name: `${l.name} — ${l.english}`, value: l.code }));
    choices.push({ name: "English — turn translation off", value: OFF_VALUE });
    return json({ type: RESP_AUTOCOMPLETE, data: { choices } });
  }

  if (ix.type === IX_COMMAND) {
    if (!translationConfigured() && name !== CMD_LANGUAGE) {
      return json({
        type: RESP_MESSAGE,
        data: { flags: EPHEMERAL, content: "Translation is not set up yet — ask a GPSL admin." },
      });
    }
    if (name === CMD_TRANSLATE) return deferEphemeral(runTranslate(ix, userId));
    if (name === CMD_LANGUAGE) return deferEphemeral(runSetLanguage(ix, userId));
    if (name === CMD_ENGLISH) return deferEphemeral(runToEnglish(ix));
  }

  return json({
    type: RESP_MESSAGE,
    data: { flags: EPHEMERAL, content: "Unknown command." },
  });
}

// ---------------------------------------------------------------------------
// Command registration
// ---------------------------------------------------------------------------

async function registerCommands(botToken: string, guildId: string) {
  const appRes = await fetch(`${DISCORD_API}/oauth2/applications/@me`, {
    headers: { Authorization: `Bot ${botToken}` },
  });
  if (!appRes.ok) {
    throw new Error(`Discord app lookup ${appRes.status}: ${(await appRes.text()).slice(0, 200)}`);
  }
  const app = (await appRes.json()) as { id?: string };
  if (!app.id) throw new Error("Discord app id missing");

  const commands = [
    { name: CMD_TRANSLATE, type: 3 },
    {
      name: CMD_LANGUAGE,
      type: 1,
      description: "Choose the language GPSL translates into for you (only you see it)",
      options: [
        {
          type: 3,
          name: "language",
          description: "Start typing, e.g. Español, Deutsch, Português, Türkçe",
          required: true,
          autocomplete: true,
        },
      ],
    },
    {
      name: CMD_ENGLISH,
      type: 1,
      description: "Turn your message into English to paste in the channel (only you see it)",
      options: [
        {
          type: 3,
          name: "text",
          description: "What you want to say, in your own language",
          required: true,
          max_length: 1500,
        },
      ],
    },
  ];

  const res = await fetch(`${DISCORD_API}/applications/${app.id}/guilds/${guildId}/commands`, {
    method: "PUT",
    headers: { Authorization: `Bot ${botToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(commands),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Register commands ${res.status}: ${text.slice(0, 300)}`);
  const list = JSON.parse(text) as { name: string }[];
  return { app_id: app.id, commands: list.map((c) => c.name) };
}

// ---------------------------------------------------------------------------
// Translated announcement DMs
// ---------------------------------------------------------------------------

type DiscordMember = {
  user?: { id: string; username?: string; global_name?: string | null; bot?: boolean };
  nick?: string | null;
};

async function fetchGuildMembers(botToken: string, guildId: string): Promise<DiscordMember[]> {
  const members: DiscordMember[] = [];
  let after: string | null = null;
  for (let page = 0; page < 50; page++) {
    const url = new URL(`${DISCORD_API}/guilds/${guildId}/members`);
    url.searchParams.set("limit", "1000");
    if (after) url.searchParams.set("after", after);
    const res = await fetch(url, { headers: { Authorization: `Bot ${botToken}` } });
    if (!res.ok) throw new Error(`Discord guild members ${res.status}`);
    const batch = (await res.json()) as DiscordMember[];
    if (!Array.isArray(batch) || !batch.length) break;
    members.push(...batch);
    const last = batch[batch.length - 1]?.user?.id;
    if (!last || batch.length < 1000) break;
    after = last;
  }
  return members;
}

function memberIdForTag(members: DiscordMember[], tag: string): string | null {
  const needle = tag.replace(/^@+/, "").trim().toLowerCase();
  if (!needle) return null;
  for (const m of members) {
    const u = m.user;
    if (!u || u.bot) continue;
    const names = [m.nick, u.global_name, u.username]
      .filter(Boolean)
      .map((s) => String(s).trim().toLowerCase());
    if (names.includes(needle)) return u.id;
  }
  return null;
}

async function sendDm(botToken: string, userId: string, content: string): Promise<boolean> {
  const headers = { Authorization: `Bot ${botToken}`, "Content-Type": "application/json" };
  for (let attempt = 0; attempt < 2; attempt++) {
    const chRes = await fetch(`${DISCORD_API}/users/@me/channels`, {
      method: "POST",
      headers,
      body: JSON.stringify({ recipient_id: userId }),
    });
    if (chRes.status === 429) {
      const body = (await chRes.json().catch(() => ({}))) as { retry_after?: number };
      await sleep(Math.ceil((body.retry_after || 1) * 1000));
      continue;
    }
    if (!chRes.ok) return false;
    const ch = (await chRes.json()) as { id?: string };
    if (!ch.id) return false;
    const msgRes = await fetch(`${DISCORD_API}/channels/${ch.id}/messages`, {
      method: "POST",
      headers,
      body: JSON.stringify({ content: content.slice(0, 2000), allowed_mentions: { parse: [] } }),
    });
    if (msgRes.status === 429) {
      const body = (await msgRes.json().catch(() => ({}))) as { retry_after?: number };
      await sleep(Math.ceil((body.retry_after || 1) * 1000));
      continue;
    }
    // 403 = user has DMs from server members turned off
    return msgRes.ok;
  }
  return false;
}

type Recipient = {
  owner_id: string;
  discord_user_id: string | null;
  owner_tag: string | null;
  language: string;
};

type QueueRow = { id: number; headline: string; body: string | null; attempts: number };

async function flushDms(botToken: string, guildId: string) {
  const db = adminClient();
  const { data: claimed, error: claimErr } = await db.rpc("gpsl_discord_translate_dm_claim", {
    p_limit: 3,
  });
  if (claimErr) throw new Error(claimErr.message);
  const rows = (claimed || []) as QueueRow[];
  if (!rows.length) return { claimed: 0 };

  const { data: recipData, error: recipErr } = await db.rpc("gpsl_discord_translate_recipients");
  if (recipErr) throw new Error(recipErr.message);
  const recipients = (recipData || []) as Recipient[];

  let members: DiscordMember[] | null = null;
  const unlinked = recipients.filter((r) => !r.discord_user_id && r.owner_tag);
  if (unlinked.length && guildId) {
    try {
      members = await fetchGuildMembers(botToken, guildId);
    } catch {
      members = null;
    }
  }

  const byLang = new Map<string, string[]>();
  let unreachable = 0;
  for (const r of recipients) {
    const id = r.discord_user_id || (members && r.owner_tag ? memberIdForTag(members, r.owner_tag) : null);
    if (!id) {
      unreachable += 1;
      continue;
    }
    const ids = byLang.get(r.language) || [];
    if (!ids.includes(id)) ids.push(id);
    byLang.set(r.language, ids);
  }

  const results: Record<string, unknown>[] = [];
  for (const row of rows) {
    let delivered = 0;
    let failed = unreachable;
    try {
      for (const [lang, ids] of byLang) {
        const { texts } = await translateTexts([row.headline, row.body || ""], lang);
        const content = [
          `🌐 **${(texts[0] || row.headline).trim()}**`,
          (texts[1] || "").trim(),
          `-# ${languageLabel(lang)} · GPSL automatic translation of a league announcement`,
        ]
          .filter(Boolean)
          .join("\n\n");
        for (const id of ids) {
          if (await sendDm(botToken, id, content)) delivered += 1;
          else failed += 1;
          await sleep(400);
        }
      }
      await db
        .from("gpsl_discord_translate_dm_queue")
        .update({
          status: "sent",
          recipients: recipients.length,
          delivered,
          failed,
          last_error: null,
          processed_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      results.push({ id: row.id, delivered, failed });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await db
        .from("gpsl_discord_translate_dm_queue")
        .update({
          // Some owners already got it — do not resend to them on retry.
          status: delivered > 0 ? "sent" : row.attempts >= 3 ? "error" : "pending",
          claimed_at: null,
          delivered,
          last_error: message.slice(0, 500),
        })
        .eq("id", row.id);
      results.push({ id: row.id, error: message });
    }
  }
  return { claimed: rows.length, recipients: recipients.length, unreachable, results };
}

// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const raw = await req.text();
  const signature = req.headers.get("x-signature-ed25519");
  const timestamp = req.headers.get("x-signature-timestamp");

  if (signature && timestamp) {
    const publicKey = await discordPublicKey();
    if (!publicKey || !verifyDiscordSignature(publicKey, signature, timestamp, raw)) {
      return new Response("invalid request signature", { status: 401 });
    }
    try {
      return handleInteraction(JSON.parse(raw) as Interaction);
    } catch {
      return new Response("bad request", { status: 400 });
    }
  }

  const feedKey = Deno.env.get("DISCORD_FEED_INVOKE_KEY") || Deno.env.get("CRON_API_KEY") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer || (bearer !== feedKey && bearer !== serviceKey)) {
    return json({ error: "Unauthorized" }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    body = raw ? JSON.parse(raw) : {};
  } catch {
    body = {};
  }

  const botToken = Deno.env.get("DISCORD_BOT_TOKEN") || "";
  const guildId = Deno.env.get("DISCORD_GUILD_ID") || "";
  const action = String(body.action || "flush_dms");

  try {
    if (action === "diagnose") {
      return json({
        ok: true,
        public_key_configured: Boolean(await discordPublicKey()),
        bot_token_configured: Boolean(botToken),
        guild_id_configured: Boolean(guildId),
        azure_configured: Boolean(Deno.env.get("AZURE_TRANSLATOR_KEY")),
        azure_region: Deno.env.get("AZURE_TRANSLATOR_REGION") || null,
        deepl_configured: Boolean(Deno.env.get("DEEPL_API_KEY")),
        google_configured: Boolean(Deno.env.get("GOOGLE_TRANSLATE_API_KEY")),
      });
    }
    if (!botToken) return json({ ok: false, error: "DISCORD_BOT_TOKEN secret missing" }, 400);
    if (action === "test") {
      const sample = "Welcome to GPSL! Your next match is on Saturday. Good luck <@123> 🎉";
      const { texts, detected } = await translateTexts([sample], "ES");
      return json({
        ok: true,
        public_key_configured: Boolean(await discordPublicKey()),
        azure_configured: Boolean(Deno.env.get("AZURE_TRANSLATOR_KEY")),
        sample,
        spanish: texts[0],
        detected,
      });
    }
    if (action === "register_commands") {
      if (!guildId) return json({ ok: false, error: "DISCORD_GUILD_ID secret missing" }, 400);
      return json({ ok: true, ...(await registerCommands(botToken, guildId)) });
    }
    if (action === "flush_dms") {
      if (!translationConfigured()) {
        return json({ ok: false, error: "Set AZURE_TRANSLATOR_KEY (or DEEPL_API_KEY / GOOGLE_TRANSLATE_API_KEY)" }, 400);
      }
      return json({ ok: true, ...(await flushDms(botToken, guildId)) });
    }
    return json({ ok: false, error: `Unknown action ${action}` }, 400);
  } catch (err) {
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
