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

    // Destructive — league admin only (not mods).
    const email = (adminUser.email || "").toLowerCase();
    if (email !== GPSL_ADMIN_EMAIL.toLowerCase()) {
      const { data: isAdmin, error: adminRpcErr } = await userClient.rpc(
        "is_gpsl_admin"
      );
      if (adminRpcErr || isAdmin !== true) {
        return jsonResponse({ error: "Admin only" }, 403);
      }
    }

    const body = await req.json().catch(() => ({}));
    const ownerId = String(body?.ownerId || body?.owner_id || "").trim();
    if (!ownerId) {
      return jsonResponse({ error: "ownerId required" }, 400);
    }

    const { data: assertData, error: assertErr } = await userClient.rpc(
      "admin_owner_assert_deletable_archived",
      { p_owner_id: ownerId }
    );

    if (assertErr) {
      return jsonResponse({ error: assertErr.message }, 400);
    }

    const targetEmail = String(assertData?.email || "").toLowerCase();
    if (targetEmail === GPSL_ADMIN_EMAIL.toLowerCase()) {
      return jsonResponse({ error: "Cannot delete the primary admin account" }, 403);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { error: deleteErr } = await adminClient.auth.admin.deleteUser(ownerId);

    if (deleteErr) {
      return jsonResponse({ error: deleteErr.message }, 400);
    }

    return jsonResponse({
      ok: true,
      owner_id: ownerId,
      email: assertData?.email || null,
      owner_tag: assertData?.owner_tag || null,
      deleted: true,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
