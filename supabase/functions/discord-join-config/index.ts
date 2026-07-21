import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/**
 * Public config for Discord-gated GPSL join (client id is public by design).
 * Secrets: DISCORD_CLIENT_ID, DISCORD_JOIN_REDIRECT_URI (optional override).
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const DEFAULT_REDIRECT =
  "https://gpsuperleague.github.io/GPSL/join_gpsl.html";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const clientId = Deno.env.get("DISCORD_CLIENT_ID");
  const redirectUri =
    Deno.env.get("DISCORD_JOIN_REDIRECT_URI") || DEFAULT_REDIRECT;
  const guildId = Deno.env.get("DISCORD_GUILD_ID");

  if (!clientId) {
    return new Response(
      JSON.stringify({
        error:
          "DISCORD_CLIENT_ID not set — create a Discord Application OAuth2 client and add the secret in Edge Function secrets.",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  return new Response(
    JSON.stringify({
      ok: true,
      client_id: clientId,
      redirect_uri: redirectUri,
      guild_configured: Boolean(guildId),
      scopes: "identify",
    }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
});
