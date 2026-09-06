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
  let ip = String(raw || "").trim().toLowerCase();
  if (!ip) return null;
  if (ip.includes("/")) ip = ip.split("/")[0].trim();
  if (ip.startsWith("::ffff:")) ip = ip.slice(7);
  if (/^\d+\.\d+\.\d+\.\d+:\d+$/.test(ip)) ip = ip.replace(/:\d+$/, "");
  return ip || null;
}

function isProbablyPublicIp(ip: string | null): boolean {
  const value = String(ip || "").trim().toLowerCase();
  if (!value) return false;
  if (value === "::1" || value === "127.0.0.1") return false;
  if (value.startsWith("10.")) return false;
  if (value.startsWith("192.168.")) return false;
  if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(value)) return false;
  if (value.startsWith("fc") || value.startsWith("fd")) return false;
  return true;
}

async function lookupCountryFromIp(ip: string | null): Promise<string | null> {
  if (!isProbablyPublicIp(ip)) return null;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const res = await fetch(`https://ipwho.is/${encodeURIComponent(String(ip))}`, {
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

    const ip =
      firstHeaderIp(req.headers.get("cf-connecting-ip")) ||
      firstHeaderIp(req.headers.get("x-real-ip")) ||
      firstHeaderIp(req.headers.get("x-forwarded-for"));
    const headerCountry =
      String(
        req.headers.get("cf-ipcountry") ||
          req.headers.get("x-vercel-ip-country") ||
          ""
      )
        .trim()
        .toUpperCase() || null;
    const country = headerCountry || (await lookupCountryFromIp(ip));
    const userAgent =
      String(
        req.headers.get("x-forwarded-user-agent") ||
          req.headers.get("user-agent") ||
          ""
      ).trim() || null;

    console.log(
      JSON.stringify({
        event: "record-login-origin",
        owner_id: user.id,
        ip_captured: !!ip,
        header_country: headerCountry,
        final_country: country,
      })
    );

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
