import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";
import {
  welcomePackBody,
  welcomePackWithMention,
  ensureVisitorRole,
  listGreatHallCandidates,
  sendWelcomeChannel,
  sendWelcomeDm,
  type WelcomePackAudience,
  type WelcomeIntakeMode,
  type WelcomePackContext,
} from "../_shared/discord_welcome_pack.ts";

/** Live season → mid_season (claim vacant); otherwise auction / pre_season. */
async function resolveWelcomeIntake(
  // deno-lint-ignore no-explicit-any
  admin: any
): Promise<{ intakeMode: WelcomeIntakeMode; seasonLabel: string | null }> {
  try {
    const { data } = await admin
      .from("competition_seasons")
      .select("status, label")
      .eq("is_current", true)
      .order("id", { ascending: false })
      .limit(1)
      .maybeSingle();
    const status = String(data?.status || "")
      .trim()
      .toLowerCase();
    const seasonLabel = data?.label ? String(data.label).trim() : null;
    return {
      intakeMode: status === "active" ? "mid_season" : "pre_season",
      seasonLabel,
    };
  } catch {
    return { intakeMode: "pre_season", seasonLabel: null };
  }
}

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

type GuildHuman = {
  id: string;
  roles: string[];
  username?: string;
  display_name?: string;
  joined_at?: string | null;
};

type WelcomeTarget = GuildHuman & {
  audience: WelcomePackAudience;
  bucket: "member_not_owner" | "visitor_week_plus";
};

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
      nick?: string | null;
      joined_at?: string | null;
      user?: {
        id?: string;
        bot?: boolean;
        username?: string;
        global_name?: string | null;
      };
      roles?: string[];
    }>;
    if (!Array.isArray(batch) || batch.length === 0) break;
    for (const m of batch) {
      const id = m.user?.id ? String(m.user.id) : "";
      if (!id || m.user?.bot) continue;
      const username = m.user?.username ? String(m.user.username) : undefined;
      const display =
        (m.nick && String(m.nick).trim()) ||
        (m.user?.global_name && String(m.user.global_name).trim()) ||
        username;
      out.push({
        id,
        roles: Array.isArray(m.roles) ? m.roles.map(String) : [],
        username,
        display_name: display,
        joined_at: m.joined_at || null,
      });
      after = id;
    }
    if (batch.length < 1000) break;
  }
  return out;
}

function daysInGuild(joinedAt: string | null | undefined): number | null {
  if (!joinedAt) return null;
  const t = Date.parse(joinedAt);
  if (!Number.isFinite(t)) return null;
  return (Date.now() - t) / (1000 * 60 * 60 * 24);
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
  audience?: WelcomePackAudience;
  packCtx?: WelcomePackContext;
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
    audience = via === "welcome_members" ? "member" : "visitor",
    packCtx,
  } = opts;

  const intake =
    packCtx?.intakeMode != null
      ? {
          intakeMode: packCtx.intakeMode,
          seasonLabel: packCtx.seasonLabel ?? null,
        }
      : await resolveWelcomeIntake(admin);
  const welcomeCtx: WelcomePackContext = {
    audience,
    intakeMode: intake.intakeMode,
    seasonLabel: intake.seasonLabel,
  };

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
  // force=true is used for rejoins (joined_at after last sent_at) and admin resends.

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

  const dm = await sendWelcomeDm(botToken, discordUserId, undefined, welcomeCtx);
  const hall = await sendWelcomeChannel(
    botToken,
    guildId,
    discordUserId,
    null,
    welcomeCtx
  );

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
    audience,
    intake_mode: welcomeCtx.intakeMode,
    season_label: welcomeCtx.seasonLabel,
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
    // Allow force for admin JWT, service role, or invoke/feed key (cron/SQL kicks).
    const force =
      body.force === true &&
      (isAdminJwt ||
        authBearer === serviceRoleKey ||
        (!!feedKey &&
          (invokeHeader === feedKey || authBearer === feedKey)));
    const assignVisitor = body.assign_visitor !== false;
    const admin = createClient(supabaseUrl, serviceRoleKey);
    const intake = await resolveWelcomeIntake(admin);

    if (action === "diagnose_pending") {
      const humans = await fetchGuildHumans(botToken, guildId);
      const { data: sentRows } = await admin
        .from("gpsl_discord_welcome_sent")
        .select("discord_user_id, via, ok, sent_at, error");
      const sentMap = new Map(
        (sentRows || []).map(
          (r: {
            discord_user_id: string;
            via?: string;
            ok?: boolean;
            sent_at?: string;
            error?: string;
          }) => [String(r.discord_user_id), r]
        )
      );
      const { data: regRows } = await admin
        .from("gpsl_owner_registry")
        .select("discord_user_id, status")
        .not("discord_user_id", "is", null);
      const ownerMap = new Map(
        (regRows || [])
          .map((r: { discord_user_id: string | null; status?: string }) => [
            String(r.discord_user_id || "").trim(),
            String(r.status || ""),
          ])
          .filter((x: [string, string]) => x[0])
      );

      const newest = [...humans]
        .filter((h) => h.joined_at)
        .sort(
          (a, b) =>
            Date.parse(String(b.joined_at)) - Date.parse(String(a.joined_at))
        )
        .slice(0, 10)
        .map((h) => {
          const sent = sentMap.get(h.id);
          const regStatus = ownerMap.get(h.id);
          const roles = new Set(h.roles);
          return {
            discord_user_id: h.id,
            username: h.username || null,
            display_name: h.display_name || null,
            joined_at: h.joined_at,
            days_in_server:
              daysInGuild(h.joined_at) != null
                ? Math.floor(daysInGuild(h.joined_at) as number)
                : null,
            in_welcome_sent: !!sent,
            welcome_via: sent?.via || null,
            welcome_ok: sent?.ok ?? null,
            in_owner_registry: regStatus != null,
            registry_status: regStatus ?? null,
            has_visitor_role: !!(visitorRole && roles.has(visitorRole)),
            has_member_role: !!(memberRole && roles.has(memberRole)),
            has_owner_role: !!(ownerRole && roles.has(ownerRole)),
            would_be_pending: !sent && regStatus == null,
          };
        });

      const pendingCount = humans.filter(
        (h) => !sentMap.has(h.id) && !ownerMap.has(h.id)
      ).length;

      return jsonResponse({
        ok: true,
        action: "diagnose_pending",
        guild_humans: humans.length,
        welcome_sent_rows: sentMap.size,
        registry_discord_ids: ownerMap.size,
        pending_for_welcome_newcomers: pendingCount,
        newest_joiners: newest,
        great_hall_env: !!(
          Deno.env.get("DISCORD_GREAT_HALL_CHANNEL_ID") ||
          Deno.env.get("DISCORD_WELCOME_CHANNEL_ID")
        ),
      });
    }

    if (action === "resolve_great_hall") {
      const info = await listGreatHallCandidates(botToken, guildId);
      const hallish = info.text_channels.filter((c) => {
        const n = c.name.toLowerCase();
        return (
          n.includes("great") ||
          n.includes("hall") ||
          n.includes("welcome") ||
          n.includes("arrival")
        );
      });
      return jsonResponse({
        ok: true,
        action: "resolve_great_hall",
        resolved_id: info.resolved_id,
        from_env: info.from_env,
        hallish_channels: hallish,
        text_channels: info.text_channels,
        text_channel_count: info.text_channels.length,
        note: info.resolved_id
          ? "Resolved — set Edge secret DISCORD_GREAT_HALL_CHANNEL_ID to this id if from_env is null."
          : "No match — pick a text channel id from text_channels and set DISCORD_GREAT_HALL_CHANNEL_ID.",
      });
    }

    if (
      action === "seed_existing" ||
      action === "welcome_newcomers" ||
      action === "welcome_members"
    ) {
      const humans = await fetchGuildHumans(botToken, guildId);
      const humanIds = humans.map((h) => h.id);
      const { data: sentRows } = await admin
        .from("gpsl_discord_welcome_sent")
        .select("discord_user_id, sent_at");
      const sent = new Set(
        (sentRows || []).map((r: { discord_user_id: string }) =>
          String(r.discord_user_id)
        )
      );
      const sentAt = new Map(
        (sentRows || []).map(
          (r: { discord_user_id: string; sent_at?: string }) => [
            String(r.discord_user_id),
            r.sent_at ? String(r.sent_at) : "",
          ]
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

      // Members∩¬Owners + Visitors in server ≥7 days — backfill pack.
      if (action === "welcome_members") {
        if (!memberRole && !visitorRole) {
          return jsonResponse(
            {
              ok: false,
              reason: "roles_not_configured",
              error: "DISCORD_ROLE_MEMBER_ID / DISCORD_ROLE_VISITOR_ID missing",
            },
            200
          );
        }
        const limitRaw = Number(body.limit);
        const offsetRaw = Number(body.offset);
        const dryRun = body.dry_run === true || body.preview === true;
        // Dry run can list a larger set; live send stays batched.
        const limit = Math.min(
          Math.max(Number.isFinite(limitRaw) ? limitRaw : dryRun ? 100 : 12, 1),
          dryRun ? 150 : 25
        );
        const offset = Math.max(
          Number.isFinite(offsetRaw) ? Math.floor(offsetRaw) : 0,
          0
        );
        const onlyUnsent = body.only_unsent === true;
        const minVisitorDaysRaw = Number(body.min_visitor_days);
        const minVisitorDays = Number.isFinite(minVisitorDaysRaw)
          ? Math.max(minVisitorDaysRaw, 0)
          : 7;
        const includeVisitors = body.include_visitors !== false;

        const targets: WelcomeTarget[] = [];
        for (const h of humans) {
          if (onlyUnsent && sent.has(h.id)) continue;
          const roles = new Set(h.roles);
          if (ownerRole && roles.has(ownerRole)) continue;

          if (memberRole && roles.has(memberRole)) {
            targets.push({
              ...h,
              audience: "member",
              bucket: "member_not_owner",
            });
            continue;
          }

          if (
            includeVisitors &&
            visitorRole &&
            roles.has(visitorRole) &&
            !(memberRole && roles.has(memberRole))
          ) {
            const days = daysInGuild(h.joined_at);
            if (days != null && days >= minVisitorDays) {
              targets.push({
                ...h,
                audience: "visitor",
                bucket: "visitor_week_plus",
              });
            }
          }
        }

        const memberCount = targets.filter(
          (t) => t.bucket === "member_not_owner"
        ).length;
        const visitorCount = targets.filter(
          (t) => t.bucket === "visitor_week_plus"
        ).length;
        const batch = targets.slice(offset, offset + limit);

        // Preview only — no DMs, no Great Hall, no welcome_sent writes
        if (dryRun) {
          const memberSample =
            batch.find((t) => t.audience === "member")?.id ||
            "123456789012345678";
          const visitorSample =
            batch.find((t) => t.audience === "visitor")?.id ||
            "123456789012345678";
          return jsonResponse({
            ok: true,
            dry_run: true,
            action: "welcome_members",
            guild_humans: humans.length,
            member_not_owner: memberCount,
            visitors_week_plus: visitorCount,
            matching_total: targets.length,
            offset,
            would_send_this_batch: batch.length,
            remaining_after_batch: Math.max(
              targets.length - (offset + batch.length),
              0
            ),
            only_unsent: onlyUnsent,
            include_visitors: includeVisitors,
            min_visitor_days: minVisitorDays,
            delivers_to: ["discord_dm", "great_hall_channel"],
            recipients: batch.map((h) => ({
              discord_user_id: h.id,
              username: h.username || null,
              display_name: h.display_name || null,
              audience: h.audience,
              bucket: h.bucket,
              joined_at: h.joined_at || null,
              days_in_server:
                daysInGuild(h.joined_at) != null
                  ? Math.floor(daysInGuild(h.joined_at) as number)
                  : null,
              already_in_welcome_sent: sent.has(h.id),
              mention: `<@${h.id}>`,
            })),
            all_matching_ids: targets.map((h) => h.id),
            message_preview_member: welcomePackWithMention(memberSample, {
              audience: "member",
              ...intake,
            }),
            message_preview_visitor: welcomePackWithMention(visitorSample, {
              audience: "visitor",
              ...intake,
            }),
            intake_mode: intake.intakeMode,
            season_label: intake.seasonLabel,
            note:
              "Dry run — nothing sent. Members (no Owner) + Visitors in server ≥ min_visitor_days.",
          });
        }

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
            force: true,
            via: "welcome_members",
            audience: h.audience,
            packCtx: { audience: h.audience, ...intake },
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
          member_not_owner: memberCount,
          visitors_week_plus: visitorCount,
          matching_total: targets.length,
          offset,
          processed: batch.length,
          welcomed,
          skipped,
          errors,
          remaining: Math.max(targets.length - (offset + batch.length), 0),
          only_unsent: onlyUnsent,
          include_visitors: includeVisitors,
          min_visitor_days: minVisitorDays,
          note:
            "Members∩¬Owners + Visitors (≥7d by default). Next batch: pass offset += processed.",
          results: results.slice(0, 20),
        });
      }

      // Poll guild for people who never got the welcome pack (Supabase-only; no VPS).
      const limitRaw = Number(body.limit);
      const limit = Math.min(
        Math.max(Number.isFinite(limitRaw) ? limitRaw : 12, 1),
        25
      );

      // Never sent, or rejoined after last welcome (left + came back).
      const pendingHumans = humans.filter((h) => {
        if (owners.has(h.id)) return false;
        const prev = sentAt.get(h.id);
        if (!prev) return true;
        if (!h.joined_at) return false;
        const joinedMs = Date.parse(h.joined_at);
        const sentMs = Date.parse(prev);
        return (
          Number.isFinite(joinedMs) &&
          Number.isFinite(sentMs) &&
          joinedMs > sentMs
        );
      });
      const batch = pendingHumans.slice(0, limit);
      const results: Record<string, unknown>[] = [];
      let welcomed = 0;
      let errors = 0;
      let rejoins = 0;

      for (const h of batch) {
        const isRejoin = sent.has(h.id);
        if (isRejoin) rejoins += 1;
        const r = await welcomeOneUser({
          admin,
          botToken,
          guildId,
          discordUserId: h.id,
          visitorRole,
          memberRole,
          ownerRole,
          assignVisitor: true,
          force: isRejoin, // rejoin must bypass already_sent
          via: "welcome_newcomers",
          audience: "visitor",
          packCtx: { audience: "visitor", ...intake },
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
        pending: pendingHumans.length,
        rejoins,
        processed: batch.length,
        welcomed,
        errors,
        remaining: Math.max(pendingHumans.length - batch.length, 0),
        results: results.slice(0, 20),
      });
    }

    if (action !== "welcome_one" && action !== "on_join") {
      return jsonResponse(
        {
          error:
            "Unknown action — use welcome_newcomers, welcome_members, diagnose_pending, resolve_great_hall, on_join, or welcome_one",
        },
        400
      );
    }

    if (!discordUserId) {
      return jsonResponse({ error: "discord_user_id required" }, 400);
    }

    const oneAudience: WelcomePackAudience =
      action === "welcome_members" ? "member" : "visitor";
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
      audience: oneAudience,
      packCtx: { audience: oneAudience, ...intake },
    });

    return jsonResponse({
      ...one,
      action,
      content_preview:
        welcomePackBody({
          audience: oneAudience,
          ...intake,
        }).slice(0, 160) + "…",
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
