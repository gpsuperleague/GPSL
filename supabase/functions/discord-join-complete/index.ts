import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

/**
 * Complete Discord-gated GPSL join: create auth user + waiting-list registry row.
 * Requires a valid unused ticket from discord-join-callback.
 */

const FAIRPLAY_VERSION = "2026-07-fairplay-v1";
const DEFAULT_STARTING_BALANCE = 600000000;

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
): Promise<{ id: string } | null> {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await adminClient.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) throw error;
    const existing = data.users.find(
      (u) => (u.email || "").toLowerCase() === email
    );
    if (existing?.id) return { id: existing.id };
    if (data.users.length < 1000) break;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const body = await req.json().catch(() => ({}));
    const ticket = String(body?.ticket || "").trim();
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "").trim();
    const ownerTag = String(body?.ownerTag || "").trim().slice(0, 64);
    const fairplayAccepted = body?.fairplayAccepted === true;

    if (!ticket) return jsonResponse({ error: "Missing join ticket" }, 400);
    if (!email || !email.includes("@")) {
      return jsonResponse({ error: "Valid email is required" }, 400);
    }
    if (!password || password.length < 6) {
      return jsonResponse(
        { error: "Password must be at least 6 characters" },
        400
      );
    }
    if (!ownerTag) {
      return jsonResponse({ error: "Owner tag is required" }, 400);
    }
    if (!fairplayAccepted) {
      return jsonResponse(
        { error: "You must accept the GPSL fair-play agreement" },
        400
      );
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: ticketRow, error: ticketErr } = await admin
      .from("discord_join_tickets")
      .select("*")
      .eq("ticket_token", ticket)
      .maybeSingle();

    if (ticketErr) return jsonResponse({ error: ticketErr.message }, 500);
    if (!ticketRow) {
      return jsonResponse(
        { error: "Invalid or expired join ticket — start again from Discord" },
        400
      );
    }
    if (ticketRow.consumed_at) {
      return jsonResponse(
        { error: "This join ticket was already used" },
        400
      );
    }
    if (new Date(ticketRow.expires_at).getTime() < Date.now()) {
      return jsonResponse(
        { error: "Join ticket expired — connect Discord again" },
        400
      );
    }

    const discordUserId = String(ticketRow.discord_user_id);

    const { data: byDiscord } = await admin
      .from("gpsl_owner_registry")
      .select("owner_id")
      .eq("discord_user_id", discordUserId)
      .maybeSingle();
    if (byDiscord?.owner_id) {
      return jsonResponse(
        { error: "This Discord account is already linked to GPSL" },
        409
      );
    }

    const existingEmail = await findUserByEmail(admin, email);
    if (existingEmail?.id) {
      return jsonResponse(
        {
          error:
            "That email already has a GPSL account. Log in instead, or use a different email.",
        },
        409
      );
    }

    let startingBalance = DEFAULT_STARTING_BALANCE;
    try {
      const { data: cfg } = await admin.rpc("club_auction_get_config");
      if (cfg?.starting_balance > 0) {
        startingBalance = Math.round(Number(cfg.starting_balance));
      }
    } catch {
      /* default */
    }

    const { data: created, error: createError } =
      await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          discord_user_id: discordUserId,
          owner_tag: ownerTag,
        },
      });

    if (createError || !created.user?.id) {
      return jsonResponse(
        { error: createError?.message || "Could not create account" },
        400
      );
    }

    const userId = created.user.id;
    const nowIso = new Date().toISOString();

    const { error: regErr } = await admin.from("gpsl_owner_registry").upsert(
      {
        owner_id: userId,
        status: "member",
        waiting_list_tier: "new",
        waiting_list_admin_sort: null,
        waiting_list_use_admin_sort: false,
        pending_starting_balance: startingBalance,
        owner_tag: ownerTag,
        discord_user_id: discordUserId,
        discord_joined_at: ticketRow.discord_joined_at || null,
        fairplay_accepted_at: nowIso,
        fairplay_version: FAIRPLAY_VERSION,
        status_changed_at: nowIso,
      },
      { onConflict: "owner_id" }
    );

    if (regErr) {
      // Best-effort: account exists; surface error for admin cleanup
      return jsonResponse(
        {
          error: regErr.message,
          auth_created: true,
          user_id: userId,
          hint: "Auth user created but registry failed — contact admin",
        },
        500
      );
    }

    await admin
      .from("discord_join_tickets")
      .update({ consumed_at: nowIso })
      .eq("ticket_token", ticket);

    return jsonResponse({
      ok: true,
      email,
      owner_tag: ownerTag,
      discord_joined_at: ticketRow.discord_joined_at || null,
      fairplay_version: FAIRPLAY_VERSION,
      message:
        "Account created. You are on the waiting list (ordered by Discord join date). You can log in now.",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
