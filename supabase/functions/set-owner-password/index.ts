import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

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

async function findUserByEmail(
  adminClient: SupabaseClient,
  email: string
): Promise<{ id: string; email: string | undefined } | null> {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await adminClient.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) throw error;
    const existing = data.users.find(
      (u) => (u.email || "").toLowerCase() === email
    );
    if (existing?.id) {
      return { id: existing.id, email: existing.email };
    }
    if (data.users.length < 1000) break;
  }
  return null;
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

    const body = await req.json();
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "").trim();

    if (!email) {
      return jsonResponse({ error: "Email is required" }, 400);
    }
    if (!password || password.length < 8) {
      return jsonResponse(
        {
          error:
            "Password must be at least 8 characters (Supabase Auth policy — use letters and numbers)",
        },
        400
      );
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const existing = await findUserByEmail(adminClient, email);

    if (!existing?.id) {
      return jsonResponse({ error: `No auth account found for ${email}` }, 404);
    }

    const { error: updateError } = await adminClient.auth.admin.updateUserById(
      existing.id,
      { password, email_confirm: true }
    );

    if (updateError) {
      return jsonResponse({ error: updateError.message }, 400);
    }

    return jsonResponse({
      ok: true,
      email,
      user_id: existing.id,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
