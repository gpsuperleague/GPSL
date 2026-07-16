import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

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

async function registerOwnerForClubAuction(
  adminClient: SupabaseClient,
  userId: string,
  startingBalance: number,
  ownerTag: string | null = null
) {
  const { data: club, error: clubErr } = await adminClient
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", userId)
    .maybeSingle();

  if (clubErr) {
    throw new Error(clubErr.message);
  }
  if (club?.ShortName) {
    throw new Error(`Owner already has a club (${club.ShortName})`);
  }

  const { data: existing, error: regReadErr } = await adminClient
    .from("gpsl_owner_registry")
    .select("status")
    .eq("owner_id", userId)
    .maybeSingle();

  if (regReadErr) {
    throw new Error(regReadErr.message);
  }
  if (existing?.status === "archived") {
    throw new Error("Owner is archived — unarchive before club auction registration");
  }

  const balance = Math.max(Number(startingBalance) || 0, 0);
  const tag = ownerTag ? String(ownerTag).trim().slice(0, 64) : null;
  const upsertRow: Record<string, unknown> = {
    owner_id: userId,
    status: "member",
    pending_starting_balance: balance,
    waiting_list_tier: "new",
    status_changed_at: new Date().toISOString(),
  };
  if (tag) {
    upsertRow.owner_tag = tag;
  }

  const { data: row, error: upsertErr } = await adminClient
    .from("gpsl_owner_registry")
    .upsert(upsertRow, { onConflict: "owner_id" })
    .select("owner_id, status, pending_starting_balance, owner_tag")
    .single();

  if (upsertErr) {
    throw new Error(upsertErr.message);
  }

  return row;
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
    const registerOnly = body?.registerOnly === true;
    const ownerTag = body?.ownerTag != null ? String(body.ownerTag).trim() : "";

    if (!email) {
      return jsonResponse({ error: "Email is required" }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    let createdAuth = false;
    let passwordUpdated = false;
    let userId: string | null = null;

    if (registerOnly) {
      const existing = await findUserByEmail(adminClient, email);
      if (!existing?.id) {
        return jsonResponse(
          { error: `No auth account found for ${email}` },
          400
        );
      }
      userId = existing.id;
    } else {
      if (!password || password.length < 6) {
        return jsonResponse(
          { error: "Password must be at least 6 characters" },
          400
        );
      }

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

        const existing = await findUserByEmail(adminClient, email);
        if (!existing?.id) {
          return jsonResponse(
            {
              error:
                "Account exists but could not be looked up — use “Register existing account only” or run the SQL fix in Supabase",
            },
            400
          );
        }

        userId = existing.id;

        const { error: updateError } =
          await adminClient.auth.admin.updateUserById(userId, {
            password,
            email_confirm: true,
          });

        if (updateError) {
          return jsonResponse({ error: updateError.message }, 400);
        }
        passwordUpdated = true;
      } else {
        createdAuth = true;
        userId = created.user?.id ?? null;
      }
    }

    if (!userId) {
      return jsonResponse({ error: "Could not resolve owner user id" }, 400);
    }

    let registry;
    try {
      registry = await registerOwnerForClubAuction(
        adminClient,
        userId,
        startingBalance,
        ownerTag || null
      );
    } catch (regErr) {
      const message =
        regErr instanceof Error ? regErr.message : "Registry update failed";
      return jsonResponse(
        {
          error: message,
          auth_created: createdAuth,
          password_updated: passwordUpdated,
          user_id: userId,
        },
        400
      );
    }

    return jsonResponse({
      ok: true,
      email,
      auth_created: createdAuth,
      password_updated: passwordUpdated,
      register_only: registerOnly,
      user_id: userId,
      registry,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
