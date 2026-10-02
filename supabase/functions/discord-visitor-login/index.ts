import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/**
 * Discord OAuth code → verify GPSL guild membership → sign in as a read-only
 * visitor. One auth user per Discord account (app_metadata.gpsl_visitor) plus a
 * public.gpsl_visitors row; returns a one-time magic-link token hash that the
 * browser exchanges with supabase.auth.verifyOtp for a session.
 *
 * Uses the same Discord application + redirect URI as discord-join-callback.
 *
 * Secrets:
 *   DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
 *   DISCORD_JOIN_REDIRECT_URI (optional)
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */

const DISCORD_API = "https://discord.com/api/v10";
const DEFAULT_REDIRECT = "https://gpsuperleague.github.io/GPSL/join_gpsl.html";
const VISITOR_EMAIL_DOMAIN = "visitor.gpsl.invalid";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
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
    const redirectUri = Deno.env.get("DISCORD_JOIN_REDIRECT_URI") || DEFAULT_REDIRECT;

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }
    if (!clientId || !clientSecret || !botToken || !guildId) {
      return jsonResponse({ error: "Discord secrets missing on the server" }, 500);
    }

    const body = await req.json().catch(() => ({}));
    const code = String(body?.code || "").trim();
    if (!code) return jsonResponse({ error: "Missing OAuth code" }, 400);

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
        { error: `Discord sign-in failed (${tokenRes.status})`, detail: text.slice(0, 200) },
        400
      );
    }
    const tokenJson = (await tokenRes.json()) as { access_token?: string };
    if (!tokenJson.access_token) {
      return jsonResponse({ error: "No access token from Discord" }, 400);
    }

    const meRes = await fetch(`${DISCORD_API}/users/@me`, {
      headers: { Authorization: `Bearer ${tokenJson.access_token}` },
    });
    if (!meRes.ok) return jsonResponse({ error: "Could not load Discord profile" }, 400);
    const me = (await meRes.json()) as {
      id: string;
      username?: string;
      global_name?: string | null;
    };
    if (!me?.id) return jsonResponse({ error: "Invalid Discord profile" }, 400);

    const memberRes = await fetch(`${DISCORD_API}/guilds/${guildId}/members/${me.id}`, {
      headers: { Authorization: `Bot ${botToken}` },
    });
    if (memberRes.status === 404) {
      return jsonResponse(
        {
          error: "Visitor access is for members of the GPSL Discord server. Join the server, then try again.",
          not_in_guild: true,
        },
        403
      );
    }
    if (!memberRes.ok) {
      return jsonResponse({ error: `Discord membership check failed (${memberRes.status})` }, 500);
    }
    const member = (await memberRes.json()) as { nick?: string | null };
    const displayName =
      String(member.nick || me.global_name || me.username || "Visitor").trim().slice(0, 64) ||
      "Visitor";

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: ownerRow } = await admin
      .from("gpsl_owner_registry")
      .select("owner_id")
      .eq("discord_user_id", me.id)
      .maybeSingle();
    if (ownerRow?.owner_id) {
      return jsonResponse(
        {
          error: "This Discord account is linked to a GPSL owner account. Log in with your email and password instead.",
          is_owner: true,
        },
        409
      );
    }

    const { data: visitor } = await admin
      .from("gpsl_visitors")
      .select("user_id, is_blocked, login_count")
      .eq("discord_user_id", me.id)
      .maybeSingle();
    if (visitor?.is_blocked) {
      return jsonResponse({ error: "Visitor access has been removed for this Discord account." }, 403);
    }

    const email = `discord-${me.id}@${VISITOR_EMAIL_DOMAIN}`;
    const appMetadata = { gpsl_visitor: true, discord_user_id: me.id };
    const userMetadata = { display_name: displayName, discord_username: me.username || null };

    if (!visitor?.user_id) {
      const { error: createErr } = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        app_metadata: appMetadata,
        user_metadata: userMetadata,
      });
      if (createErr && !/already|registered|exists/i.test(createErr.message)) {
        return jsonResponse({ error: `Could not create visitor account: ${createErr.message}` }, 500);
      }
    }

    const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    const tokenHash = link?.properties?.hashed_token;
    const userId = link?.user?.id;
    if (linkErr || !tokenHash || !userId) {
      return jsonResponse(
        { error: `Could not start visitor session: ${linkErr?.message || "no token"}` },
        500
      );
    }

    await admin.auth.admin.updateUserById(userId, {
      app_metadata: appMetadata,
      user_metadata: userMetadata,
    });

    const { error: upsertErr } = await admin.from("gpsl_visitors").upsert(
      {
        user_id: userId,
        discord_user_id: me.id,
        discord_username: me.username || null,
        display_name: displayName,
        last_login_at: new Date().toISOString(),
        login_count: (visitor?.login_count || 0) + 1,
      },
      { onConflict: "user_id" }
    );
    if (upsertErr) {
      return jsonResponse(
        {
          error: `Visitor record failed: ${upsertErr.message}. Run gpsl_visitors_discord_20261002.sql in Supabase.`,
        },
        500
      );
    }

    return jsonResponse({
      ok: true,
      token_hash: tokenHash,
      email,
      display_name: displayName,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
