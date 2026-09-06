import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

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

function normalizeIp(raw: string | null | undefined): string | null {
  const ip = String(raw || "").trim().toLowerCase();
  return ip || null;
}

async function lookupCountryFromIp(ip: string | null): Promise<string | null> {
  const value = String(ip || "").trim();
  if (!value) return null;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const res = await fetch(`https://ipwho.is/${encodeURIComponent(value)}`, {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    clearTimeout(timer);
    if (!res.ok) return null;
    const data = (await res.json()) as { success?: boolean; country_code?: string };
    if (data?.success === false) return null;
    const code = String(data?.country_code || "").trim().toUpperCase();
    return code || null;
  } catch {
    return null;
  }
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

    let isAdmin = false;
    try {
      const { data } = await userClient.rpc("is_gpsl_admin");
      isAdmin = data === true;
    } catch {
      isAdmin = false;
    }
    if (!isAdmin && (user.email || "").toLowerCase() === GPSL_ADMIN_EMAIL) {
      isAdmin = true;
    }
    if (!isAdmin) {
      return jsonResponse({ error: "Admin only" }, 403);
    }

    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      try {
        body = (await req.json()) as Record<string, unknown>;
      } catch {
        body = {};
      }
    }
    const force = body.force === true;

    const { data: security, error: secErr } = await userClient.rpc(
      "admin_owner_login_security_map",
      { p_recent_days: 30 }
    );
    if (secErr) {
      return jsonResponse({ error: secErr.message }, 500);
    }

    const owners = Array.isArray(security?.owners) ? security.owners : [];
    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const cache = new Map<string, string | null>();
    let lookedUp = 0;
    let updated = 0;
    let skipped = 0;

    for (const row of owners) {
      const ownerId = String(row?.owner_id || "").trim();
      const ipAddress = String(row?.last_ip_address || "").trim();
      const ipNorm = normalizeIp(ipAddress);
      const existingCountry = String(row?.last_country_code || "").trim().toUpperCase();
      if (!ownerId || !ipNorm) {
        skipped += 1;
        continue;
      }
      if (existingCountry && !force) {
        skipped += 1;
        continue;
      }

      let country = cache.get(ipNorm);
      if (country === undefined) {
        country = await lookupCountryFromIp(ipNorm);
        cache.set(ipNorm, country);
        lookedUp += 1;
      }
      if (!country) {
        skipped += 1;
        continue;
      }

      const { error: insertErr } = await adminClient
        .from("owner_login_origin_events")
        .insert({
          owner_id: ownerId,
          logged_in_at: new Date().toISOString(),
          ip_address: ipAddress,
          ip_address_norm: ipNorm,
          country_code: country,
          user_agent: null,
          source: "admin_backfill_country",
        });
      if (insertErr) {
        return jsonResponse({ error: insertErr.message }, 500);
      }
      updated += 1;
    }

    return jsonResponse({
      ok: true,
      force,
      looked_up: lookedUp,
      updated,
      skipped,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
