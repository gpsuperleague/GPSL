import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * Keeps one index in #index (or #where-to-go): every channel, grouped by category,
 * with what it is for. The admin category, its channels, and check-pins
 * reminders are left out.
 * Edits the same messages. No extra secret.
 *
 * Purpose: the channel topic if one is set, otherwise a built-in line.
 */

const DISCORD_API = "https://discord.com/api/v10";
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-feed-key",
};

const MONTHS = new Set([
  "june", "july", "august", "september", "october", "november",
  "december", "january", "february", "march", "april", "may",
]);

const PURPOSES: Record<string, string> = {
  thegreathall: "Main chat.",
  whattodo: "What to do next if you are new or stuck.",
  index: "This index. The bot keeps it up to date.",
  channelindex: "This index. The bot keeps it up to date.",
  wheretogo: "This index. The bot keeps it up to date.",
  whatisgpsl: "What GPSL is.",
  news: "League news, posted by the bot.",
  results: "League results, posted when a score is confirmed.",
  natter: "Colour and lines from the match reports.",
  calendar: "GPSL month dates and deadlines.",
  tables: "League tables.",
  friendlyresults: "Friendly results.",
  friendlies: "Arrange and report friendlies.",
  transfergossip: "Transfer talk. The site posts listings and interest here.",
  whoswho: "Owner tag next to each club. The bot updates it.",
  fonts: "The styled letters used for channel names.",
  checkpins: "Pinned info for this area. Read the pins.",
  announcements: "League announcements.",
  qanda: "Questions. A new thread gets a pointer to the handbook.",
  scheduled: "Fixtures with a kick-off locked in.",
  donedeals: "Completed transfers.",
  contracts: "Contract news.",
  jobcenter: "Managers available and clubs looking.",
  nationpicker: "World Cup nation picks.",
  uploadcodes: "Codes for uploading a match video.",
  recording: "How to record your match.",
  youtubeupload: "Where match videos go.",
  donationsmemberships: "Ko-fi and memberships.",
  matchdays: "Matchday talk.",
  playoffs: "Playoff matches.",
  whattoshow: "What a match recording should show.",
  agreematchesfinaliseingpsl: "Agree a kick-off here, then lock it on the GPSL site.",
  highlights: "Match highlights.",
  gpslsoftware: "The GPSL site and tools.",
  themodroom: "Moderators.",
  reportbugs: "Report a bug on the site.",
  suggestions: "Suggestions.",
  polls: "Polls.",
  devtodo: "Dev to-do. Not an owner channel.",
};

type DiscordChannel = {
  id: string;
  name?: string;
  type?: number;
  position?: number;
  parent_id?: string | null;
  topic?: string | null;
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function foldStyledLetters(name: string): string {
  let out = "";
  for (const ch of String(name || "")) {
    const cp = ch.codePointAt(0) ?? 0;
    if (cp >= 0x1d400 && cp <= 0x1d419) {
      out += String.fromCharCode(65 + (cp - 0x1d400));
    } else if (cp >= 0x1d41a && cp <= 0x1d433) {
      out += String.fromCharCode(97 + (cp - 0x1d41a));
    } else {
      out += ch;
    }
  }
  return out;
}

function channelSlug(name: string): string {
  return foldStyledLetters(name)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
}

function isAdminCategory(name: string): boolean {
  const slug = channelSlug(name);
  return slug === "admin" || slug.startsWith("admin");
}

function isCheckPins(name: string): boolean {
  return channelSlug(name).includes("checkpin");
}

function purposeFor(ch: DiscordChannel): string {
  const topic = String(ch.topic || "").replace(/\s+/g, " ").trim();
  if (topic) return topic.slice(0, 180);
  const slug = channelSlug(ch.name || "");
  if (MONTHS.has(slug)) return "Match videos for this GPSL month.";
  return PURPOSES[slug] || "No description yet.";
}

async function discordFetch(
  botToken: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const headers = new Headers(init.headers || {});
  headers.set("Authorization", `Bot ${botToken}`);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(`${DISCORD_API}${path}`, { ...init, headers });
    if (res.status !== 429) return res;
    let waitSec = Number(res.headers.get("retry-after") || "1");
    try {
      const body = await res.clone().json();
      if (typeof body?.retry_after === "number") waitSec = body.retry_after;
    } catch {
      /* ignore */
    }
    await sleep(Math.ceil(waitSec * 1000) + 200);
  }
  return new Response("rate limited", { status: 429 });
}

function authorized(
  req: Request,
  serviceRoleKey: string,
  invokeKey: string | undefined
): boolean {
  const bearer = (req.headers.get("Authorization") || "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  if (bearer && bearer === serviceRoleKey) return true;
  const headerKey = req.headers.get("x-discord-feed-key") || "";
  if (invokeKey && (bearer === invokeKey || headerKey === invokeKey)) return true;
  return false;
}

function buildEmbeds(channels: DiscordChannel[]): Record<string, unknown>[] {
  const categories = channels
    .filter((c) => c.type === 4 && !isAdminCategory(c.name || ""))
    .sort((a, b) => (a.position || 0) - (b.position || 0));
  const hiddenParents = new Set(
    channels
      .filter((c) => c.type === 4 && isAdminCategory(c.name || ""))
      .map((c) => c.id)
  );
  const listed = channels
    .filter(
      (c) =>
        (c.type === 0 || c.type === 5 || c.type === 15 || c.type === 2) &&
        !hiddenParents.has(c.parent_id || "") &&
        !isCheckPins(c.name || "")
    )
    .sort((a, b) => (a.position || 0) - (b.position || 0));

  const groups: { title: string; lines: string[] }[] = [];
  const loose = listed.filter((c) => !c.parent_id);
  if (loose.length) {
    groups.push({
      title: "Channels",
      lines: loose.map((c) => `<#${c.id}> — ${purposeFor(c)}`),
    });
  }
  for (const cat of categories) {
    const kids = listed.filter((c) => c.parent_id === cat.id);
    if (!kids.length) continue;
    groups.push({
      title: cat.name || "Category",
      lines: kids.map((c) => `<#${c.id}> — ${purposeFor(c)}`),
    });
  }

  const embeds: Record<string, unknown>[] = [];
  for (const group of groups) {
    let chunk: string[] = [];
    let size = 0;
    const flush = () => {
      if (!chunk.length) return;
      embeds.push({
        title: embeds.some((e) => e.title === group.title) ? undefined : group.title,
        description: chunk.join("\n").slice(0, 4000),
        color: 0xf5b041,
      });
      chunk = [];
      size = 0;
    };
    for (const line of group.lines) {
      if (chunk.length && size + line.length + 1 > 3900) flush();
      chunk.push(line);
      size += line.length + 1;
    }
    flush();
  }
  if (!embeds.length) {
    embeds.push({
      title: "GPSL channels",
      description: "No channels found.",
      color: 0xf5b041,
    });
  }
  return embeds;
}

function packMessages(embeds: Record<string, unknown>[]): Record<string, unknown>[][] {
  const out: Record<string, unknown>[][] = [];
  let cur: Record<string, unknown>[] = [];
  for (const embed of embeds) {
    if (cur.length >= 10) {
      out.push(cur);
      cur = [];
    }
    cur.push(embed);
  }
  if (cur.length) out.push(cur);
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
    const invokeKey = Deno.env.get("DISCORD_FEED_INVOKE_KEY");

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization") || "";
    let allow = authorized(req, serviceRoleKey, invokeKey);
    if (!allow && authHeader) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: { user } } = await userClient.auth.getUser();
      if (user) {
        const { data: adminFlag } = await userClient.rpc("is_gpsl_admin");
        if (adminFlag === true) allow = true;
        if (!allow && (user.email || "").toLowerCase() === GPSL_ADMIN_EMAIL) {
          allow = true;
        }
      }
    }
    if (!allow) return jsonResponse({ error: "Unauthorized" }, 401);
    if (!botToken || !guildId) {
      return jsonResponse({ error: "Missing DISCORD_BOT_TOKEN or DISCORD_GUILD_ID" }, 500);
    }

    const listRes = await discordFetch(botToken, `/guilds/${guildId}/channels`);
    if (!listRes.ok) {
      const text = await listRes.text();
      return jsonResponse({ error: `List channels ${listRes.status} ${text.slice(0, 180)}` }, 502);
    }
    const channels = (await listRes.json()) as DiscordChannel[];
    const home =
      channels.find((c) => channelSlug(c.name || "") === "index") ||
      channels.find((c) => channelSlug(c.name || "") === "channelindex") ||
      channels.find((c) => channelSlug(c.name || "") === "wheretogo");
    if (!home) {
      return jsonResponse({
        error: "No channel named index. Create a text channel called index and allow the bot to send messages there.",
      }, 400);
    }

    const embeds = buildEmbeds(channels);
    const packs = packMessages(embeds);
    const hash = embeds
      .map((e) => `${e.title || ""}\n${e.description || ""}`)
      .join("\n---\n");

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const { data: settings, error: settingsError } = await admin
      .from("gpsl_discord_channel_index_settings")
      .select("message_ids, content_hash")
      .eq("id", 1)
      .maybeSingle();
    if (settingsError) {
      return jsonResponse(
        {
          error: settingsError.message,
          hint: "Run supabase/sql/patches/discord_channel_index_20261110.sql",
        },
        500
      );
    }

    const previousIds = Array.isArray(settings?.message_ids)
      ? (settings.message_ids as string[])
      : [];
    if (settings?.content_hash && settings.content_hash === hash && previousIds.length === packs.length) {
      return jsonResponse({
        ok: true,
        unchanged: true,
        channel_id: home.id,
        messages: previousIds.length,
      });
    }

    const ids: string[] = [];
    for (let i = 0; i < packs.length; i++) {
      const payload: Record<string, unknown> = {
        embeds: packs[i],
        allowed_mentions: { parse: [] },
      };
      if (i === 0) payload.content = "GPSL channels. The bot updates this list.";
      const body = JSON.stringify(payload);
      const existing = previousIds[i];
      let res: Response | null = null;
      if (existing) {
        res = await discordFetch(botToken, `/channels/${home.id}/messages/${existing}`, {
          method: "PATCH",
          body,
        });
        if (res.ok) {
          ids.push(existing);
          continue;
        }
      }
      res = await discordFetch(botToken, `/channels/${home.id}/messages`, {
        method: "POST",
        body,
      });
      if (!res.ok) {
        const text = await res.text();
        const denied = res.status === 403;
        return jsonResponse(
          {
            error: denied
              ? "The bot cannot send messages in that channel. Allow it View Channel, Send Messages, and Embed Links."
              : `Post ${res.status} ${text.slice(0, 180)}`,
            channel_id: home.id,
            channel_name: home.name,
          },
          502
        );
      }
      const created = (await res.json()) as { id?: string };
      if (!created.id) {
        return jsonResponse({ error: "Discord returned no message id" }, 502);
      }
      ids.push(created.id);
      if (i === 0) {
        await discordFetch(botToken, `/channels/${home.id}/pins/${created.id}`, {
          method: "PUT",
        });
      }
      await sleep(400);
    }

    for (const stale of previousIds.slice(packs.length)) {
      await discordFetch(botToken, `/channels/${home.id}/messages/${stale}`, {
        method: "DELETE",
      });
    }

    const { error: saveError } = await admin
      .from("gpsl_discord_channel_index_settings")
      .update({
        message_ids: ids,
        content_hash: hash,
        updated_at: new Date().toISOString(),
      })
      .eq("id", 1);
    if (saveError) {
      return jsonResponse({ error: saveError.message, posted: ids }, 500);
    }

    return jsonResponse({
      ok: true,
      channel_id: home.id,
      channel_name: home.name,
      messages: ids,
      sections: embeds.length,
    });
  } catch (e) {
    console.error("discord-channel-index:", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : String(e) },
      500
    );
  }
});
