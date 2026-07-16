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
      data: { user: adminUser },
      error: adminUserError,
    } = await userClient.auth.getUser();

    if (adminUserError || !adminUser) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    if ((adminUser.email || "").toLowerCase() !== GPSL_ADMIN_EMAIL) {
      return jsonResponse({ error: "Admin only" }, 403);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const users: Array<{ id: string; email: string }> = [];

    for (let page = 1; page <= 50; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({
        page,
        perPage: 1000,
      });
      if (error) {
        return jsonResponse({ error: error.message }, 500);
      }
      for (const u of data.users || []) {
        if (u?.id && u?.email) {
          users.push({ id: u.id, email: u.email });
        }
      }
      if ((data.users || []).length < 1000) break;
    }

    users.sort((a, b) => a.email.localeCompare(b.email));

    return jsonResponse({ ok: true, users, count: users.length });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
