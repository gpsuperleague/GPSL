import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function firstHeaderIp(value: string | null): string | null {
  const raw = String(value || "").trim();
  if (!raw) return null;
  const first = raw.split(",")[0]?.trim() || "";
  return first || null;
}

function normalizeIp(raw: string | null): string | null {
  const ip = String(raw || "").trim();
  if (!ip) return null;
  return ip.toLowerCase();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: userErr,
    } = await userClient.auth.getUser();

    if (userErr || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const ip =
      firstHeaderIp(req.headers.get("cf-connecting-ip")) ||
      firstHeaderIp(req.headers.get("x-real-ip")) ||
      firstHeaderIp(req.headers.get("x-forwarded-for"));
    const country =
      String(
        req.headers.get("cf-ipcountry") ||
          req.headers.get("x-vercel-ip-country") ||
          ""
      )
        .trim()
        .toUpperCase() || null;
    const userAgent =
      String(
        req.headers.get("x-forwarded-user-agent") ||
          req.headers.get("user-agent") ||
          ""
      ).trim() || null;

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { error: insertErr } = await adminClient
      .from("owner_login_origin_events")
      .insert({
        owner_id: user.id,
        ip_address: ip,
        ip_address_norm: normalizeIp(ip),
        country_code: country,
        user_agent: userAgent,
        source: "edge_login",
      });

    if (insertErr) {
      return jsonResponse({ error: insertErr.message }, 500);
    }

    return jsonResponse({
      ok: true,
      owner_id: user.id,
      country_code: country,
      ip_captured: !!ip,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
