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
      if (!msg?.id || !msg.author || msg.author.bot) continue;
      const raw = String(msg.content || "");
      const content = cleanContent(raw);
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
