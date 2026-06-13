import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";

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
    const startingBalance = Number(body?.startingBalance ?? 600000000);

    if (!email) {
      return jsonResponse({ error: "Email is required" }, 400);
    }

    if (!password || password.length < 6) {
      return jsonResponse({ error: "Password must be at least 6 characters" }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    let createdAuth = false;
    let existingUserId: string | null = null;

    const { data: created, error: createError } =
      await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

    if (createError) {
      const msg = createError.message.toLowerCase();
      const alreadyExists =
        msg.includes("already") ||
        msg.includes("registered") ||
        msg.includes("duplicate");

      if (!alreadyExists) {
        return jsonResponse({ error: createError.message }, 400);
      }

      const { data: listData, error: listError } =
        await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });

      if (listError) {
        return jsonResponse({ error: listError.message }, 400);
      }

      const existing = listData.users.find(
        (u) => (u.email || "").toLowerCase() === email
      );

      if (!existing?.id) {
        return jsonResponse(
          { error: "Account exists but could not be looked up" },
          400
        );
      }

      existingUserId = existing.id;

      const { error: updateError } = await adminClient.auth.admin.updateUserById(
        existingUserId,
        { password, email_confirm: true }
      );

      if (updateError) {
        return jsonResponse({ error: updateError.message }, 400);
      }
    } else {
      createdAuth = true;
      existingUserId = created.user?.id ?? null;
    }

    const { data: registry, error: registryError } = await userClient.rpc(
      "admin_owner_register_for_club_auction",
      {
        p_owner_email: email,
        p_starting_balance: startingBalance,
      }
    );

    if (registryError) {
      return jsonResponse(
        {
          error: registryError.message,
          auth_created: createdAuth,
          user_id: existingUserId,
        },
        400
      );
    }

    return jsonResponse({
      ok: true,
      email,
      auth_created: createdAuth,
      password_updated: !createdAuth,
      user_id: existingUserId,
      registry,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
