import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * Exchange Discord OAuth code → verify guild membership via bot → issue join ticket.
 *
 * Secrets:
 *   DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
 *   DISCORD_JOIN_REDIRECT_URI (optional)
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */

const DISCORD_API = "https://discord.com/api/v10";
const DEFAULT_REDIRECT =
  "https://gpsuperleague.github.io/GPSL/join_gpsl.html";
const TICKET_TTL_MS = 20 * 60 * 1000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function suggestedTag(nick: string | null | undefined, username: string | undefined) {
  const n = (nick || "").trim();
  if (n) return n.slice(0, 64);
  return String(username || "").trim().slice(0, 64);
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId = Deno.env.get("DISCORD_CLIENT_ID");
    const clientSecret = Deno.env.get("DISCORD_CLIENT_SECRET");
    const botToken = Deno.env.get("DISCORD_BOT_TOKEN");
    const guildId = Deno.env.get("DISCORD_GUILD_ID");
    const redirectUri =
      Deno.env.get("DISCORD_JOIN_REDIRECT_URI") || DEFAULT_REDIRECT;

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }
    if (!clientId || !clientSecret) {
      return jsonResponse(
        {
          error:
            "Discord OAuth secrets missing — set DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET",
        },
        500
      );
    }
    if (!botToken || !guildId) {
      return jsonResponse(
        {
          error:
            "Discord guild secrets missing — set DISCORD_BOT_TOKEN and DISCORD_GUILD_ID",
        },
        500
      );
    }

    const body = await req.json().catch(() => ({}));
    const code = String(body?.code || "").trim();
    if (!code) {
      return jsonResponse({ error: "Missing OAuth code" }, 400);
    }

    const tokenRes = await fetch(`${DISCORD_API}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: "authorization_code",
        code,
        redirect_uri: redirectUri,
      }),
    });

    if (!tokenRes.ok) {
      const text = await tokenRes.text();
      return jsonResponse(
        {
          error: `Discord token exchange failed (${tokenRes.status})`,
          detail: text.slice(0, 200),
        },
        400
      );
    }

    const tokenJson = (await tokenRes.json()) as {
      access_token?: string;
    };
    if (!tokenJson.access_token) {
      return jsonResponse({ error: "No access token from Discord" }, 400);
    }

    const meRes = await fetch(`${DISCORD_API}/users/@me`, {
      headers: { Authorization: `Bearer ${tokenJson.access_token}` },
    });
    if (!meRes.ok) {
      return jsonResponse({ error: "Could not load Discord profile" }, 400);
    }
    const me = (await meRes.json()) as {
      id: string;
      username?: string;
      global_name?: string | null;
    };
    if (!me?.id) {
      return jsonResponse({ error: "Invalid Discord profile" }, 400);
    }

    const memberRes = await fetch(
      `${DISCORD_API}/guilds/${guildId}/members/${me.id}`,
      {
        headers: {
          Authorization: `Bot ${botToken}`,
          "Content-Type": "application/json",
        },
      }
    );

    if (memberRes.status === 404) {
      return jsonResponse(
        {
          error:
            "You are not a member of the GPSL Discord server. Join the server, then use the invite link from Discord again.",
          not_in_guild: true,
        },
        403
      );
    }
    if (!memberRes.ok) {
      const text = await memberRes.text();
      return jsonResponse(
        {
          error: `Guild membership check failed (${memberRes.status})`,
          detail: text.slice(0, 200),
        },
        500
      );
    }

    const member = (await memberRes.json()) as {
      nick?: string | null;
      joined_at?: string;
      user?: { username?: string; global_name?: string | null };
    };

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: existing } = await admin
      .from("gpsl_owner_registry")
      .select("owner_id, status")
      .eq("discord_user_id", me.id)
      .maybeSingle();

    if (existing?.owner_id) {
      return jsonResponse(
        {
          error:
            "This Discord account is already linked to a GPSL owner. Log in with your email instead.",
          already_registered: true,
        },
        409
      );
    }

    const tag = suggestedTag(
      member.nick || me.global_name,
      me.username || member.user?.username
    );
    const ticketToken = randomToken();
    const expiresAt = new Date(Date.now() + TICKET_TTL_MS).toISOString();

    // Drop prior unused tickets for this Discord user
    await admin
      .from("discord_join_tickets")
      .delete()
      .eq("discord_user_id", me.id)
      .is("consumed_at", null);

    const { error: insErr } = await admin.from("discord_join_tickets").insert({
      ticket_token: ticketToken,
      discord_user_id: me.id,
      discord_username: me.username || null,
      suggested_tag: tag || null,
      discord_joined_at: member.joined_at || null,
      expires_at: expiresAt,
    });

    if (insErr) {
      return jsonResponse({ error: insErr.message }, 500);
    }

    return jsonResponse({
      ok: true,
      ticket: ticketToken,
      expires_at: expiresAt,
      discord_user_id: me.id,
      discord_username: me.username || null,
      suggested_tag: tag,
      discord_joined_at: member.joined_at || null,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
