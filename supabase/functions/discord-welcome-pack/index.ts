import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";
import {
  WELCOME_PACK_BODY,
  ensureVisitorRole,
  sendWelcomeChannel,
  sendWelcomeDm,
} from "../_shared/discord_welcome_pack.ts";

/**
 * Welcome pack for new Discord Visitors: DM + Great Hall channel, both with <@tag>.
 *
 * Actions:
 *   welcome_newcomers — cron/poll (no VPS bot needed)
 *   welcome_members — Members role, exclude Owners (backfill new pack)
 *   on_join / welcome_one — single user
 *
 * Secrets: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_ROLE_*,
 *   DISCORD_GREAT_HALL_CHANNEL_ID (optional — else looks for #great-hall),
 *   DISCORD_FEED_INVOKE_KEY or CRON_API_KEY
 */

type GuildHuman = { id: string; roles: string[] };

async function fetchGuildHumans(
  botToken: string,
  guildId: string
): Promise<GuildHuman[]> {
  const out: GuildHuman[] = [];
  let after: string | null = null;
  for (let page = 0; page < 20; page++) {
    const url = new URL(`https://discord.com/api/v10/guilds/${guildId}/members`);
    url.searchParams.set("limit", "1000");
    if (after) url.searchParams.set("after", after);
    const res = await fetch(url.toString(), {
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Type": "application/json",
      },
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Discord members ${res.status}: ${text.slice(0, 200)}`);
    }
    const batch = (await res.json()) as Array<{
      user?: { id?: string; bot?: boolean };
      roles?: string[];
    }>;
    if (!Array.isArray(batch) || batch.length === 0) break;
    for (const m of batch) {
      const id = m.user?.id ? String(m.user.id) : "";
      if (!id || m.user?.bot) continue;
      out.push({
        id,
        roles: Array.isArray(m.roles) ? m.roles.map(String) : [],
      });
      after = id;
    }
    if (batch.length < 1000) break;
  }
  return out;
}

async function fetchGuildHumanIds(
  botToken: string,
  guildId: string
): Promise<string[]> {
  const humans = await fetchGuildHumans(botToken, guildId);
  return humans.map((h) => h.id);
}

async function welcomeOneUser(opts: {
  // deno-lint-ignore no-explicit-any
  admin: any;
  botToken: string;
  guildId: string;
  discordUserId: string;
  visitorRole: string;
  memberRole: string;
  ownerRole: string;
  assignVisitor: boolean;
  force: boolean;
  via: string;
}): Promise<Record<string, unknown>> {
  const {
    admin,
    botToken,
    guildId,
    discordUserId,
    visitorRole,
    memberRole,
    ownerRole,
    assignVisitor,
    force,
    via,
  } = opts;

  const { data: reg } = await admin
    .from("gpsl_owner_registry")
    .select("owner_id, status")
    .eq("discord_user_id", discordUserId)
    .maybeSingle();
  if (reg?.owner_id && !force) {
    return {
      ok: true,
      skipped: "already_gpsl_owner",
      discord_user_id: discordUserId,
      status: reg.status,
    };
  }

  if (!force) {
    const { data: prior } = await admin
      .from("gpsl_discord_welcome_sent")
      .select("discord_user_id, sent_at")
      .eq("discord_user_id", discordUserId)
      .maybeSingle();
    if (prior?.discord_user_id) {
      return {
        ok: true,
        skipped: "already_sent",
        discord_user_id: discordUserId,
        sent_at: prior.sent_at,
      };
    }
  }

  let roleResult: Awaited<ReturnType<typeof ensureVisitorRole>> | null = null;
  if (assignVisitor) {
    roleResult = await ensureVisitorRole(
      botToken,
      guildId,
      discordUserId,
      visitorRole,
      memberRole,
      ownerRole
    );
  }

  const dm = await sendWelcomeDm(botToken, discordUserId);
  const hall = await sendWelcomeChannel(botToken, guildId, discordUserId);

  const ok = dm.ok || hall.ok;
  const errParts = [
    dm.error ? `dm:${dm.error}` : null,
    hall.error ? `hall:${hall.error}` : null,
    roleResult?.error ? `role:${roleResult.error}` : null,
  ].filter(Boolean);

  await admin.from("gpsl_discord_welcome_sent").upsert(
    {
      discord_user_id: discordUserId,
      sent_at: new Date().toISOString(),
      ok,
      via,
      dm_channel_id: dm.channel_id || null,
      hall_channel_id: hall.channel_id || null,
      hall_message_id: hall.message_id || null,
      error: errParts.length ? errParts.join(" | ") : null,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "discord_user_id" }
  );

  return {
    ok,
    discord_user_id: discordUserId,
    visitor_role: roleResult,
    dm,
    great_hall: hall,
  };
}

const ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-feed-key, x-discord-welcome-key",
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
    const botToken = (Deno.env.get("DISCORD_BOT_TOKEN") || "").trim();
    const guildId = (Deno.env.get("DISCORD_GUILD_ID") || "").trim();
    const visitorRole = (Deno.env.get("DISCORD_ROLE_VISITOR_ID") || "").trim();
    const memberRole = (Deno.env.get("DISCORD_ROLE_MEMBER_ID") || "").trim();
    const ownerRole = (Deno.env.get("DISCORD_ROLE_OWNER_ID") || "").trim();
    const feedKey =
      Deno.env.get("DISCORD_FEED_INVOKE_KEY") ||
      Deno.env.get("DISCORD_WELCOME_INVOKE_KEY") ||
      Deno.env.get("CRON_API_KEY") ||
      Deno.env.get("DISCORD_MATCH_VIDEOS_INVOKE_KEY") ||
      "";

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const invokeHeader = (
      req.headers.get("x-discord-feed-key") ||
      req.headers.get("x-discord-welcome-key") ||
      req.headers.get("apikey") ||
      ""
    ).trim();
    const authBearer = (req.headers.get("Authorization") || "")
      .replace(/^Bearer\s+/i, "")
      .trim();

    let authorized = false;
    let isAdminJwt = false;
    if (feedKey && (invokeHeader === feedKey || authBearer === feedKey)) {
      authorized = true;
    } else if (authBearer && authBearer === serviceRoleKey) {
      authorized = true;
    } else if (authBearer.startsWith("eyJ")) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: `Bearer ${authBearer}` } },
      });
      const {
        data: { user },
      } = await userClient.auth.getUser();
      if (user && (await isGpslAdminOrMod(userClient, user, ADMIN_EMAIL))) {
        authorized = true;
        isAdminJwt = true;
      }
    }

    if (!authorized) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    if (!botToken || !guildId) {
      return jsonResponse(
        {
          ok: false,
          reason: "discord_bot_not_configured",
          error: "DISCORD_BOT_TOKEN / DISCORD_GUILD_ID missing",
        },
        200
      );
    }

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch {
      body = {};
    }

    const action = String(body.action || "welcome_newcomers").trim();
    const discordUserId = String(body.discord_user_id || "").trim();
    const force = body.force === true && (isAdminJwt || authBearer === serviceRoleKey);
    const assignVisitor = body.assign_visitor !== false;
    const admin = createClient(supabaseUrl, serviceRoleKey);

    if (
      action === "seed_existing" ||
      action === "welcome_newcomers" ||
      action === "welcome_members"
    ) {
      const humans =
        action === "welcome_members"
          ? await fetchGuildHumans(botToken, guildId)
          : (await fetchGuildHumanIds(botToken, guildId)).map((id) => ({
              id,
              roles: [] as string[],
            }));
      const humanIds = humans.map((h) => h.id);
      const { data: sentRows } = await admin
        .from("gpsl_discord_welcome_sent")
        .select("discord_user_id");
      const sent = new Set(
        (sentRows || []).map((r: { discord_user_id: string }) =>
          String(r.discord_user_id)
        )
      );

      const { data: regRows } = await admin
        .from("gpsl_owner_registry")
        .select("discord_user_id")
        .not("discord_user_id", "is", null);
      const owners = new Set(
        (regRows || [])
          .map((r: { discord_user_id: string | null }) =>
            String(r.discord_user_id || "").trim()
          )
          .filter(Boolean)
      );

      // One-shot: mark everyone already in the server as "sent" so cron only
      // DMs people who join after this. Does not send messages.
      if (action === "seed_existing") {
        const toSeed = humanIds.filter((id) => !sent.has(id));
        const now = new Date().toISOString();
        let seeded = 0;
        for (let i = 0; i < toSeed.length; i += 50) {
          const chunk = toSeed.slice(i, i + 50).map((id) => ({
            discord_user_id: id,
            sent_at: now,
            ok: true,
            via: "seed_existing",
            dm_channel_id: null,
            error: null,
            updated_at: now,
          }));
          const { error } = await admin
            .from("gpsl_discord_welcome_sent")
            .upsert(chunk, { onConflict: "discord_user_id" });
          if (error) {
            return jsonResponse({ error: error.message, seeded }, 500);
          }
          seeded += chunk.length;
        }
        return jsonResponse({
          ok: true,
          action: "seed_existing",
          guild_humans: humanIds.length,
          seeded,
          note: "Existing members marked; cron will only welcome future joiners.",
        });
      }

      // Members role, exclude Owners role — backfill new pack (no Visitor assign).
      if (action === "welcome_members") {
        if (!memberRole) {
          return jsonResponse(
            {
              ok: false,
              reason: "member_role_not_configured",
              error: "DISCORD_ROLE_MEMBER_ID missing",
            },
            200
          );
        }
        const limitRaw = Number(body.limit);
        const limit = Math.min(
          Math.max(Number.isFinite(limitRaw) ? limitRaw : 12, 1),
          25
        );
        // Default: re-send new pack to Members∩¬Owners (even if seed_existing marked them).
        // Pass only_unsent:true to skip people already in gpsl_discord_welcome_sent.
        const onlyUnsent = body.only_unsent === true;
        const memberOnly = humans.filter((h) => {
          const roles = new Set(h.roles);
          if (!roles.has(memberRole)) return false;
          if (ownerRole && roles.has(ownerRole)) return false;
          if (onlyUnsent && sent.has(h.id)) return false;
          return true;
        });
        const batch = memberOnly.slice(0, limit);
        const results: Record<string, unknown>[] = [];
        let welcomed = 0;
        let errors = 0;
        let skipped = 0;

        for (const h of batch) {
          const r = await welcomeOneUser({
            admin,
            botToken,
            guildId,
            discordUserId: h.id,
            visitorRole,
            memberRole,
            ownerRole,
            assignVisitor: false,
            // Re-send past welcome_sent / registry skip — audience already role-filtered
            force: true,
            via: "welcome_members",
          });
          results.push(r);
          if (r.ok && !r.skipped) welcomed += 1;
          else if (r.skipped) skipped += 1;
          if (r.ok === false) errors += 1;
          await new Promise((res) => setTimeout(res, 400));
        }

        return jsonResponse({
          ok: true,
          action: "welcome_members",
          guild_humans: humans.length,
          member_not_owner: memberOnly.length,
          processed: batch.length,
          welcomed,
          skipped,
          errors,
          remaining: Math.max(memberOnly.length - batch.length, 0),
          only_unsent: onlyUnsent,
          note:
            "Discord Members role only; Owners role excluded. No Visitor assign. Re-run until remaining=0.",
          results: results.slice(0, 20),
        });
      }

      // Poll guild for people who never got the welcome pack (Supabase-only; no VPS).
      const limitRaw = Number(body.limit);
      const limit = Math.min(
        Math.max(Number.isFinite(limitRaw) ? limitRaw : 12, 1),
        25
      );

      const pending = humanIds.filter((id) => !sent.has(id) && !owners.has(id));
      const batch = pending.slice(0, limit);
      const results: Record<string, unknown>[] = [];
      let welcomed = 0;
      let errors = 0;

      for (const id of batch) {
        const r = await welcomeOneUser({
          admin,
          botToken,
          guildId,
          discordUserId: id,
          visitorRole,
          memberRole,
          ownerRole,
          assignVisitor: true,
          force: false,
          via: "welcome_newcomers",
        });
        results.push(r);
        if (r.ok && !r.skipped) welcomed += 1;
        if (r.ok === false) errors += 1;
        await new Promise((res) => setTimeout(res, 400));
      }

      return jsonResponse({
        ok: true,
        action: "welcome_newcomers",
        guild_humans: humanIds.length,
        pending: pending.length,
        processed: batch.length,
        welcomed,
        errors,
        remaining: Math.max(pending.length - batch.length, 0),
        results: results.slice(0, 20),
      });
    }

    if (action !== "welcome_one" && action !== "on_join") {
      return jsonResponse(
        {
          error:
            "Unknown action — use welcome_newcomers, welcome_members, on_join, or welcome_one",
        },
        400
      );
    }

    if (!discordUserId) {
      return jsonResponse({ error: "discord_user_id required" }, 400);
    }

    const one = await welcomeOneUser({
      admin,
      botToken,
      guildId,
      discordUserId,
      visitorRole,
      memberRole,
      ownerRole,
      assignVisitor,
      force,
      via: action,
    });

    return jsonResponse({
      ...one,
      action,
      content_preview: WELCOME_PACK_BODY.slice(0, 120) + "…",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
