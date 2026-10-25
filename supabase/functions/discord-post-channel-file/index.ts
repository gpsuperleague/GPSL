/**
 * One-shot / admin: post a public image (+ caption) to a Discord channel by name.
 *
 * Secrets: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
 *
 * Body:
 *   {
 *     "channel_name": "gpsl-announcements",
 *     "content": "optional caption",
 *     "image_url": "https://…/poster.jpg",
 *     "filename": "gpsl-match-arrangement-systems.jpg"
 *   }
 */
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const DISCORD_API = "https://discord.com/api/v10";

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cors(req: Request) {
  const origin = req.headers.get("Origin") || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

serve(async (req) => {
  const headers = cors(req);
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }
  if (req.method !== "POST") {
    return json({ error: "POST only" }, 405);
  }

  try {
    const botToken = Deno.env.get("DISCORD_BOT_TOKEN") || "";
    const guildId = Deno.env.get("DISCORD_GUILD_ID") || "";
    if (!botToken || !guildId) {
      return json(
        { error: "Missing DISCORD_BOT_TOKEN or DISCORD_GUILD_ID" },
        500
      );
    }

    const body = await req.json().catch(() => ({}));
    const channelName = String(body.channel_name || "gpsl-announcements")
      .trim()
      .replace(/^#/, "")
      .toLowerCase();
    const content = String(body.content || "").slice(0, 1900);
    const imageUrl = String(body.image_url || "").trim();
    const filename = String(
      body.filename || "gpsl-match-arrangement-systems.jpg"
    ).replace(/[^\w.\-]+/g, "_");

    if (!imageUrl || !/^https?:\/\//i.test(imageUrl)) {
      return json({ error: "image_url must be an http(s) URL" }, 400);
    }

    const chRes = await fetch(`${DISCORD_API}/guilds/${guildId}/channels`, {
      headers: { Authorization: `Bot ${botToken}` },
    });
    if (!chRes.ok) {
      const t = await chRes.text();
      return json(
        { error: `List channels ${chRes.status}: ${t.slice(0, 200)}` },
        502
      );
    }
    const channels = (await chRes.json()) as Array<{
      id: string;
      name?: string;
      type?: number;
    }>;
    const channel = channels.find(
      (c) => String(c.name || "").toLowerCase() === channelName
    );
    if (!channel?.id) {
      return json(
        {
          error: `Channel #${channelName} not found`,
          names: channels
            .filter((c) => c.type === 0)
            .map((c) => c.name)
            .slice(0, 40),
        },
        404
      );
    }

    const imgRes = await fetch(imageUrl);
    if (!imgRes.ok) {
      return json(
        { error: `Fetch image ${imgRes.status}` },
        502
      );
    }
    const bytes = new Uint8Array(await imgRes.arrayBuffer());
    if (bytes.byteLength < 1000) {
      return json({ error: "Image too small / empty" }, 400);
    }

    const form = new FormData();
    form.append(
      "payload_json",
      JSON.stringify({
        content: content || undefined,
        allowed_mentions: { parse: [] },
      })
    );
    form.append(
      "files[0]",
      new Blob([bytes], { type: "image/jpeg" }),
      filename
    );

    const postRes = await fetch(
      `${DISCORD_API}/channels/${channel.id}/messages`,
      {
        method: "POST",
        headers: { Authorization: `Bot ${botToken}` },
        body: form,
      }
    );
    const postText = await postRes.text();
    if (!postRes.ok) {
      return json(
        { error: `Discord post ${postRes.status}: ${postText.slice(0, 400)}` },
        502
      );
    }

    let messageId: string | null = null;
    try {
      messageId = JSON.parse(postText)?.id ?? null;
    } catch {
      /* ignore */
    }

    return json({
      ok: true,
      channel_id: channel.id,
      channel_name: channelName,
      message_id: messageId,
      bytes: bytes.byteLength,
    });
  } catch (e) {
    return json(
      { error: e instanceof Error ? e.message : String(e) },
      500
    );
  }
});
