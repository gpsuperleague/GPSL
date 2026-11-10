import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const DISCORD_API = "https://discord.com/api/v10";
const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-gossip-key, x-discord-friendlies-key",
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
  bot?: boolean;
};

type DiscordMessage = {
  id: string;
  content?: string;
  timestamp?: string;
  author?: DiscordUser;
};

function cleanContent(raw: string): string {
  const firstLine = String(raw || "")
    .replace(/[\u200B-\u200D\uFEFF]/g, "")
    .replace(/[\u2013\u2014\u2212]/g, "-")
    .split(/\r?\n/)[0] || "";
  return firstLine
    .replace(/<@!?\d+>/g, "")
    .replace(/<@&\d+>/g, "")
    .replace(/@[A-Za-z0-9_./-]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function looksLikeGossip(content: string): boolean {
  const c = cleanContent(content);
  return (
    /^.+?\s+are\s+interested\s+in\s+.+$/i.test(c) ||
    /^.+?\s+is\s+interested\s+in\s+.+$/i.test(c)
  );
}

async function fetchChannelMessages(
  botToken: string,
  channelId: string,
  limit = 40
): Promise<DiscordMessage[]> {
  const url = new URL(`${DISCORD_API}/channels/${channelId}/messages`);
  url.searchParams.set("limit", String(Math.max(1, Math.min(limit, 100))));
  const res = await fetch(url, {
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Discord messages ${res.status}: ${text.slice(0, 300)}`);
  }
  const batch = (await res.json()) as DiscordMessage[];
  return Array.isArray(batch) ? batch : [];
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function storageCardUrl(id: string) {
  const base = String(Deno.env.get("SUPABASE_URL") || "").replace(/\/$/, "");
  return `${base}/storage/v1/object/public/player-cards/${id}.png`;
}

async function ensurePlayerCard(
  admin: ReturnType<typeof createClient>,
  rawId: string
): Promise<string | null> {
  const id = String(rawId || "").trim();
  if (!/^\d{4,12}$/.test(id)) return null;
  const publicUrl = storageCardUrl(id);
  try {
    const head = await fetch(publicUrl, { method: "HEAD" });
    if (head.ok) return publicUrl;
  } catch {
    /* fetch a fresh copy */
  }
  try {
    const upstream = await fetch(
      `https://pesdb.net/assets/img/card/b${encodeURIComponent(id)}.png`,
      {
        headers: {
          "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          Accept: "image/png,image/*;q=0.8,*/*;q=0.2",
        },
      }
    );
    const contentType = String(upstream.headers.get("content-type") || "").toLowerCase();
    if (!upstream.ok || !contentType.startsWith("image/")) return null;
    const bytes = new Uint8Array(await upstream.arrayBuffer());
    const { error } = await admin.storage.from("player-cards").upload(`${id}.png`, bytes, {
      upsert: true,
      contentType: contentType || "image/png",
      cacheControl: "31536000",
    });
    if (error) return null;
    return publicUrl;
  } catch {
    return null;
  }
}

async function postChannelMessage(
  botToken: string,
  channelId: string,
  content: string,
  embed?: Record<string, unknown> | null
): Promise<{ message_id: string }> {
  const body: Record<string, unknown> = {
    allowed_mentions: { parse: [] },
  };
  if (content.trim()) body.content = content.slice(0, 1800);
  if (embed && typeof embed === "object") body.embeds = [embed];

  const send = () =>
    fetch(`${DISCORD_API}/channels/${channelId}/messages`, {
      method: "POST",
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

  let res = await send();
  if (res.status === 429) {
    let waitMs = 2000;
    try {
      const retry = (await res.json()) as { retry_after?: number };
      if (Number(retry.retry_after) > 0) {
        waitMs = Math.min(Number(retry.retry_after) * 1000, 10000);
      }
    } catch {
      /* keep the default wait */
    }
    await sleep(waitMs);
    res = await send();
  }
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Discord post ${res.status}: ${text.slice(0, 300)}`);
  }
  const posted = (await res.json()) as DiscordMessage;
  if (!posted?.id) throw new Error("Discord post returned no message id");
  return { message_id: posted.id };
}

async function addReaction(
  botToken: string,
  channelId: string,
  messageId: string,
  emoji: string
) {
  const encoded = encodeURIComponent(emoji);
  try {
    await fetch(
      `${DISCORD_API}/channels/${channelId}/messages/${messageId}/reactions/${encoded}/@me`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bot ${botToken}`,
          "Content-Length": "0",
        },
      }
    );
  } catch {
    /* non-fatal */
  }
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
    req.headers.get("x-discord-gossip-key") ||
    req.headers.get("x-discord-friendlies-key") ||
    "";
  if (invokeKey && (bearer === invokeKey || headerKey === invokeKey)) {
    return true;
  }
  return false;
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
    const channelId = Deno.env.get("DISCORD_TRANSFER_GOSSIP_CHANNEL_ID");
    const invokeKey =
      Deno.env.get("DISCORD_TRANSFER_GOSSIP_INVOKE_KEY") ||
      Deno.env.get("DISCORD_FRIENDLIES_INVOKE_KEY") ||
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
        const { data: staffFlag } = await userClient.rpc("is_gpsl_admin_or_mod");
        if (staffFlag === true) allow = true;
        if (!allow) {
          const { data: adminFlag } = await userClient.rpc("is_gpsl_admin");
          if (adminFlag === true) allow = true;
        }
        if (
          !allow &&
          (user.email || "").toLowerCase() === GPSL_ADMIN_EMAIL
        ) {
          allow = true;
        }
      }
    }

    if (!allow) return jsonResponse({ error: "Unauthorized" }, 401);

    if (!botToken || !channelId) {
      return jsonResponse(
        {
          error:
            "Missing secrets — set DISCORD_BOT_TOKEN and DISCORD_TRANSFER_GOSSIP_CHANNEL_ID",
        },
        500
      );
    }

    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      try {
        body = (await req.json()) as Record<string, unknown>;
      } catch {
        body = {};
      }
    }

    const action = String(body.action || "").toLowerCase();
    if (action === "post") {
      const content = cleanContent(String(body.content || ""));
      if (!looksLikeGossip(content)) {
        return jsonResponse(
          {
            ok: false,
            error:
              "Not a gossip line. Use: Club are interested in Player",
          },
          400
        );
      }
      const posted = await postChannelMessage(botToken, channelId, content);
      return jsonResponse({ ok: true, posted: true, ...posted });
    }

    if (action === "post_cards") {
      const items = Array.isArray(body.items) ? body.items : [];
      if (!items.length) {
        return jsonResponse({ ok: true, posted: 0 });
      }
      const adminClient = createClient(supabaseUrl, serviceRoleKey);
      const postedIds: string[] = [];
      const failedIds: number[] = [];
      let failed = false;
      for (const raw of items) {
        const item = (raw || {}) as Record<string, unknown>;
        const listingId = Number(item.listing_id);
        if (failed) {
          if (Number.isFinite(listingId)) failedIds.push(listingId);
          continue;
        }
        try {
          const content = String(item.content || "").replace(/\s+/g, " ").trim();
          const embed =
            item.embed && typeof item.embed === "object"
              ? { ...(item.embed as Record<string, unknown>) }
              : null;
          const cardUrl = await ensurePlayerCard(adminClient, String(item.card_id || ""));
          if (embed && cardUrl) embed.image = { url: cardUrl };
          if (!content && !embed) throw new Error("Empty listing post");
          const posted = await postChannelMessage(botToken, channelId, content, embed);
          postedIds.push(posted.message_id);
          await sleep(1200);
        } catch {
          failed = true;
          if (Number.isFinite(listingId)) failedIds.push(listingId);
        }
      }
      if (failedIds.length) {
        try {
          await adminClient.rpc("gpsl_listing_gossip_unmark", { p_ids: failedIds });
        } catch {
          /* the SQL re-run posts anything still unmarked */
        }
      }
      return jsonResponse({
        ok: true,
        posted: postedIds.length,
        failed: failedIds.length,
        message_ids: postedIds,
      });
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const messages = await fetchChannelMessages(
      botToken,
      channelId,
      Number(body.limit) > 0 ? Number(body.limit) : 40
    );

    const ordered = [...messages].reverse();
    const results: Record<string, unknown>[] = [];
    const samples: string[] = [];
    let scanned = 0;
    let rumours = 0;
    let ignored = 0;
    let duplicates = 0;
    let empty_content = 0;
    let skipped_format = 0;

    for (const msg of ordered) {
      if (!msg?.id || !msg.author) continue;
      const raw = String(msg.content || "");
      const content = cleanContent(raw);
      // Human lines only, plus a GPSL bot line in the gossip sentence.
      // That sentence is how a site "Show interest" reaches this reader.
      if (msg.author.bot && !looksLikeGossip(content)) continue;
      if (samples.length < 5) {
        samples.push(
          (content || raw || "(empty)").replace(/\s+/g, " ").slice(0, 100)
        );
      }
      if (!raw.trim()) {
        empty_content += 1;
        continue;
      }
      if (!content || !looksLikeGossip(content)) {
        skipped_format += 1;
        continue;
      }
      scanned += 1;

      const { data, error } = await adminClient.rpc(
        "gpsl_transfer_gossip_ingest_post",
        {
          p_discord_message_id: msg.id,
          p_discord_user_id: msg.author.id,
          p_content: content,
          p_posted_at: msg.timestamp || new Date().toISOString(),
        }
      );

      if (error) {
        results.push({
          message_id: msg.id,
          status: "error",
          reason: error.message,
          content,
        });
        continue;
      }

      const row = (data || {}) as Record<string, unknown>;
      const status = String(row.status || "");
      if (status === "rumour") {
        rumours += 1;
        await addReaction(botToken, channelId, msg.id, "📰");
      } else if (status === "duplicate") {
        duplicates += 1;
      } else {
        ignored += 1;
      }

      results.push({ message_id: msg.id, content, ...row });
    }

    let hint: string | null = null;
    if (messages.length === 0) {
      hint =
        "No messages returned — wrong DISCORD_TRANSFER_GOSSIP_CHANNEL_ID or bot still can't read the channel";
    } else if (empty_content > 0 && scanned === 0) {
      hint =
        "Messages found but content empty — enable Message Content Intent, then restart/redeploy the bot function";
    } else if (scanned === 0) {
      hint =
        "Messages found but none matched: 'Club are interested in Player' or 'Player is interested in Club'";
    }

    return jsonResponse({
      ok: true,
      messages_fetched: messages.length,
      scanned,
      rumours,
      ignored,
      duplicates,
      empty_content,
      skipped_format,
      channel_id_tail: String(channelId).slice(-6),
      samples,
      hint,
      results: results.slice(-30),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
