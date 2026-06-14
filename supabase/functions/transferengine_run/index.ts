import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const cronApiKey = Deno.env.get("CRON_API_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    // When Verify JWT is off (sb_secret_ cron calls): require matching apikey header.
    const incomingKey = (req.headers.get("apikey") || "").trim();
    const authBearer = (req.headers.get("Authorization") || "")
      .replace(/^Bearer\s+/i, "")
      .trim();
    const allowedCronKeys = [cronApiKey, serviceRoleKey].filter(Boolean) as string[];

    if (!authBearer.startsWith("eyJ")) {
      const matched =
        incomingKey &&
        allowedCronKeys.some((k) => k === incomingKey || k === authBearer);
      if (!matched) {
        return jsonResponse({ error: "Unauthorized — invalid apikey" }, 401);
      }
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data, error } = await adminClient.rpc("transferengine_run_report");

    if (error) {
      return jsonResponse(
        {
          error: error.message,
          code: error.code,
          details: error.details,
          hint: error.hint,
        },
        500
      );
    }

    return jsonResponse({ ok: true, report: data ?? null });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
