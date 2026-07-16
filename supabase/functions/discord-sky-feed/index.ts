import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-feed-key",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type FeedRow = {
  id: number;
  event_type: string;
  headline: string;
  body: string | null;
  color: number | null;
  metadata: Record<string, unknown> | null;
};

function embedFor(row: FeedRow) {
  const colors: Record<string, number> = {
    result: 0xe10600, // Sky-ish red
    transfer: 0x00a651, // green
    listing: 0xffcc00, // amber
    auction: 0x0057b8, // blue
    draft: 0x7b2cbf, // purple
    manager: 0x3498db,
    owner: 0xf1c40f,
    title: 0xffd700,
    cup: 0xffd700,
    relegation: 0x995533,
    playoff: 0x9b59b6,
    other: 0x111111,
  };
  const color =
    row.color ??
    colors[row.event_type] ??
    colors.other;

  return {
    title: row.headline.slice(0, 256),
    description: (row.body || "").slice(0, 4000) || undefined,
    color,
    footer: { text: "GPSL News" },
    timestamp: new Date().toISOString(),
  };
}

async function postWebhook(
  webhookUrl: string,
  embeds: Record<string, unknown>[]
) {
  const res = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      username: "GPSL News",
      embeds,
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Discord webhook ${res.status}: ${text.slice(0, 300)}`);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const webhookUrl = Deno.env.get("DISCORD_WEBHOOK_URL");
    const feedKey = Deno.env.get("DISCORD_FEED_INVOKE_KEY") ||
      Deno.env.get("CRON_API_KEY") ||
      "";
    const adminEmail = "rotavator66@outlook.com";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }
    if (!webhookUrl) {
      return jsonResponse(
        {
          error:
            "DISCORD_WEBHOOK_URL secret missing — add it under Edge Function secrets",
        },
        500
      );
    }

    // Auth: invoke key (cron/webhook/SQL) OR admin JWT
    const invokeHeader = (
      req.headers.get("x-discord-feed-key") ||
      req.headers.get("apikey") ||
      ""
    ).trim();
    const authBearer = (req.headers.get("Authorization") || "")
      .replace(/^Bearer\s+/i, "")
      .trim();

    let authorized = false;
    if (feedKey && (invokeHeader === feedKey || authBearer === feedKey)) {
      authorized = true;
    } else if (authBearer && authBearer === serviceRoleKey) {
      // Database Webhooks / server-side callers
      authorized = true;
    } else if (authBearer.startsWith("eyJ")) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: `Bearer ${authBearer}` } },
      });
      const {
        data: { user },
      } = await userClient.auth.getUser();
      if (user && (user.email || "").toLowerCase() === adminEmail) {
        authorized = true;
      }
    }

    if (!authorized) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch {
      body = {};
    }

    // Optional: post a one-off test embed
    if (body?.test === true) {
      await postWebhook(webhookUrl, [
        {
          title: "🚨 GPSL NEWS — TEST",
          description: "Discord feed is connected.",
          color: 0xe10600,
          footer: { text: "GPSL News" },
          timestamp: new Date().toISOString(),
        },
      ]);
      return jsonResponse({ ok: true, test: true });
    }

    // Optional: direct event (from SQL/webhook payload)
    if (body?.headline && body?.event_type) {
      await postWebhook(webhookUrl, [
        embedFor({
          id: 0,
          event_type: String(body.event_type),
          headline: String(body.headline),
          body: body.body != null ? String(body.body) : null,
          color: typeof body.color === "number" ? body.color : null,
          metadata: null,
        }),
      ]);
    }

    const { data: rows, error } = await adminClient
      .from("gpsl_discord_feed_queue")
      .select("id, event_type, headline, body, color, metadata, attempts")
      .eq("status", "pending")
      .order("id", { ascending: true })
      .limit(25);

    if (error) {
      return jsonResponse({ error: error.message }, 500);
    }

    const pending = (rows || []) as FeedRow[];
    let posted = 0;
    const errors: string[] = [];

    for (const row of pending) {
      try {
        await postWebhook(webhookUrl, [embedFor(row)]);
        const { error: updErr } = await adminClient
          .from("gpsl_discord_feed_queue")
          .update({
            status: "posted",
            posted_at: new Date().toISOString(),
            last_error: null,
          })
          .eq("id", row.id);
        if (updErr) throw new Error(updErr.message);
        posted += 1;
        // Discord rate limit soft pause
        await new Promise((r) => setTimeout(r, 350));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        errors.push(`#${row.id}: ${message}`);
        await adminClient
          .from("gpsl_discord_feed_queue")
          .update({
            status: "error",
            last_error: message.slice(0, 500),
            attempts: Number((row as { attempts?: number }).attempts || 0) + 1,
          })
          .eq("id", row.id);
      }
    }

    return jsonResponse({
      ok: true,
      pending: pending.length,
      posted,
      errors,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
