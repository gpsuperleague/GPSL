import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";

/**
 * Sync Discord guild roles from GPSL status.
 *
 * Mapping (only these three roles are added/removed — nothing else is touched):
 *   • GPSL owner registry (any status, incl. archived / on_break) → Member
 *   • Owns a club (Clubs.owner_id) → Owner + Member
 *   • No registry (visitor / Discord-only) → Visitor
 *
 * Auth (any one):
 *   • Admin/mod JWT
 *   • SUPABASE_SERVICE_ROLE_KEY bearer
 *   • DISCORD_FEED_INVOKE_KEY / CRON_API_KEY (SQL pg_net / cron)
 *
 * Secrets:
 *   DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
 *   DISCORD_ROLE_MEMBER_ID, DISCORD_ROLE_OWNER_ID, DISCORD_ROLE_VISITOR_ID
 *   DISCORD_FEED_INVOKE_KEY (or CRON_API_KEY) for SQL invokes
 *
 * If role IDs are missing, returns ok:false reason=roles_not_configured (no crash).
 */

const DISCORD_API = "https://discord.com/api/v10";
const ADMIN_EMAIL = "rotavator66@outlook.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discord-feed-key",
};

type Tier = "owner" | "member" | "visitor";

type SyncResult = {
  discord_user_id: string;
  tier: Tier;
  added: string[];
  removed: string[];
  skipped?: string;
  error?: string;
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function roleConfig() {
  const member = (Deno.env.get("DISCORD_ROLE_MEMBER_ID") || "").trim();
  const owner = (Deno.env.get("DISCORD_ROLE_OWNER_ID") || "").trim();
  const visitor = (Deno.env.get("DISCORD_ROLE_VISITOR_ID") || "").trim();
  return { member, owner, visitor };
}

function desiredRoleIds(tier: Tier, roles: ReturnType<typeof roleConfig>): Set<string> {
  const want = new Set<string>();
  if (tier === "visitor") {
    if (roles.visitor) want.add(roles.visitor);
  } else if (tier === "member") {
    if (roles.member) want.add(roles.member);
  } else {
    if (roles.member) want.add(roles.member);
    if (roles.owner) want.add(roles.owner);
  }
  return want;
}

function managedRoleIds(roles: ReturnType<typeof roleConfig>): Set<string> {
  return new Set(
    [roles.member, roles.owner, roles.visitor].filter(Boolean)
  );
}

async function discordJson(
  botToken: string,
  path: string,
  init?: RequestInit
): Promise<{ ok: boolean; status: number; json: unknown; text: string }> {
  const res = await fetch(`${DISCORD_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bot ${botToken}`,
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { ok: res.ok, status: res.status, json, text };
}

async function syncDiscordUser(
  botToken: string,
  guildId: string,
  discordUserId: string,
  tier: Tier,
  roles: ReturnType<typeof roleConfig>
): Promise<SyncResult> {
  const managed = managedRoleIds(roles);
  const want = desiredRoleIds(tier, roles);
  const result: SyncResult = {
    discord_user_id: discordUserId,
    tier,
    added: [],
    removed: [],
  };

  const member = await discordJson(
    botToken,
    `/guilds/${guildId}/members/${discordUserId}`
  );
  if (member.status === 404) {
    result.skipped = "not_in_guild";
    return result;
  }
  if (!member.ok) {
    result.error = `member_lookup_${member.status}: ${member.text.slice(0, 160)}`;
    return result;
  }

  const current = new Set<string>(
    Array.isArray((member.json as { roles?: string[] })?.roles)
      ? ((member.json as { roles: string[] }).roles || [])
      : []
  );

  for (const roleId of managed) {
    const shouldHave = want.has(roleId);
    const has = current.has(roleId);
    if (shouldHave && !has) {
      const put = await discordJson(
        botToken,
        `/guilds/${guildId}/members/${discordUserId}/roles/${roleId}`,
        { method: "PUT" }
      );
      // 204 No Content = success; 404 role/member missing
      if (put.ok || put.status === 204) {
        result.added.push(roleId);
      } else if (put.status !== 404) {
        result.error = `add_${roleId}_${put.status}: ${put.text.slice(0, 160)}`;
        return result;
      }
      await sleep(250);
    } else if (!shouldHave && has) {
      const del = await discordJson(
        botToken,
        `/guilds/${guildId}/members/${discordUserId}/roles/${roleId}`,
        { method: "DELETE" }
      );
      if (del.ok || del.status === 204) {
        result.removed.push(roleId);
      } else if (del.status !== 404) {
        result.error = `remove_${roleId}_${del.status}: ${del.text.slice(0, 160)}`;
        return result;
      }
      await sleep(250);
    }
  }

  return result;
}

async function resolveTier(
  // deno-lint-ignore no-explicit-any
  admin: any,
  opts: { owner_id?: string | null; discord_user_id?: string | null }
): Promise<{ discord_user_id: string; tier: Tier } | { error: string }> {
  let ownerId = opts.owner_id ? String(opts.owner_id).trim() : "";
  let discordUserId = opts.discord_user_id
    ? String(opts.discord_user_id).trim()
    : "";

  if (ownerId) {
    const { data: reg, error } = await admin
      .from("gpsl_owner_registry")
      .select("owner_id, discord_user_id")
      .eq("owner_id", ownerId)
      .maybeSingle();
    if (error) return { error: error.message };
    if (!reg) return { error: "owner_not_in_registry" };
    discordUserId = String(reg.discord_user_id || "").trim();
    if (!discordUserId) return { error: "no_discord_user_id" };

    const { data: club } = await admin
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", ownerId)
      .limit(1)
      .maybeSingle();
    return {
      discord_user_id: discordUserId,
      tier: club?.ShortName ? "owner" : "member",
    };
  }

  if (!discordUserId) return { error: "missing_owner_or_discord_id" };

  const { data: byDiscord } = await admin
    .from("gpsl_owner_registry")
    .select("owner_id")
    .eq("discord_user_id", discordUserId)
    .maybeSingle();
  if (byDiscord?.owner_id) {
    const { data: club } = await admin
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", byDiscord.owner_id)
      .limit(1)
      .maybeSingle();
    return {
      discord_user_id: discordUserId,
      tier: club?.ShortName ? "owner" : "member",
    };
  }

  // Site visitor or Discord-only → Visitor
  return { discord_user_id: discordUserId, tier: "visitor" };
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
    const feedKey =
      Deno.env.get("DISCORD_FEED_INVOKE_KEY") ||
      Deno.env.get("CRON_API_KEY") ||
      "";
    const roles = roleConfig();

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }

    const invokeHeader = (
      req.headers.get("x-discord-feed-key") ||
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
    if (!roles.member || !roles.owner || !roles.visitor) {
      return jsonResponse(
        {
          ok: false,
          reason: "roles_not_configured",
          error:
            "Set DISCORD_ROLE_MEMBER_ID, DISCORD_ROLE_OWNER_ID, DISCORD_ROLE_VISITOR_ID secrets",
          have: {
            member: !!roles.member,
            owner: !!roles.owner,
            visitor: !!roles.visitor,
          },
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

    const action = String(body.action || "sync_one").trim();
    const admin = createClient(supabaseUrl, serviceRoleKey);

    if (action === "sync_one") {
      const resolved = await resolveTier(admin, {
        owner_id: (body.owner_id as string) || null,
        discord_user_id: (body.discord_user_id as string) || null,
      });
      if ("error" in resolved) {
        return jsonResponse({
          ok: false,
          reason: resolved.error,
          owner_id: body.owner_id || null,
          discord_user_id: body.discord_user_id || null,
        });
      }
      const result = await syncDiscordUser(
        botToken,
        guildId,
        resolved.discord_user_id,
        resolved.tier,
        roles
      );
      return jsonResponse({
        ok: !result.error,
        ...result,
        owner_id: body.owner_id || null,
      });
    }

    if (action === "sync_linked") {
      // Admin JWT only for bulk — cron key may call with small limit for catch-up
      const limitRaw = Number(body.limit);
      const limit = Math.min(
        Math.max(Number.isFinite(limitRaw) ? limitRaw : 40, 1),
        isAdminJwt ? 200 : 40
      );
      const results: SyncResult[] = [];
      let scanned = 0;

      const { data: registryRows, error: regErr } = await admin
        .from("gpsl_owner_registry")
        .select("owner_id, discord_user_id")
        .not("discord_user_id", "is", null)
        .limit(limit);
      if (regErr) return jsonResponse({ error: regErr.message }, 500);

      for (const row of registryRows || []) {
        if (scanned >= limit) break;
        const discordId = String(row.discord_user_id || "").trim();
        if (!discordId) continue;
        scanned += 1;
        const resolved = await resolveTier(admin, {
          owner_id: row.owner_id,
          discord_user_id: discordId,
        });
        if ("error" in resolved) {
          results.push({
            discord_user_id: discordId,
            tier: "member",
            added: [],
            removed: [],
            error: resolved.error,
          });
          continue;
        }
        results.push(
          await syncDiscordUser(
            botToken,
            guildId,
            resolved.discord_user_id,
            resolved.tier,
            roles
          )
        );
      }

      const remaining = limit - scanned;
      if (remaining > 0) {
        const { data: visitors } = await admin
          .from("gpsl_visitors")
          .select("discord_user_id")
          .not("discord_user_id", "is", null)
          .limit(remaining);
        for (const v of visitors || []) {
          const discordId = String(v.discord_user_id || "").trim();
          if (!discordId) continue;
          // Skip if already a registry owner
          const { data: reg } = await admin
            .from("gpsl_owner_registry")
            .select("owner_id")
            .eq("discord_user_id", discordId)
            .maybeSingle();
          if (reg?.owner_id) continue;
          results.push(
            await syncDiscordUser(
              botToken,
              guildId,
              discordId,
              "visitor",
              roles
            )
          );
        }
      }

      const errors = results.filter((r) => r.error).length;
      const changed = results.filter(
        (r) => r.added.length || r.removed.length
      ).length;
      return jsonResponse({
        ok: true,
        action: "sync_linked",
        scanned: results.length,
        changed,
        errors,
        results: results.slice(0, 50),
      });
    }

    if (action === "sync_guild") {
      // Walk Discord guild members and apply Owner / Member / Visitor.
      // Needed so Discord-only people get Visitor (sync_linked never sees them).
      if (!isAdminJwt) {
        return jsonResponse(
          { error: "sync_guild requires admin JWT" },
          403
        );
      }

      const limitRaw = Number(body.limit);
      const limit = Math.min(
        Math.max(Number.isFinite(limitRaw) ? limitRaw : 80, 1),
        150
      );
      const after = String(body.after || "").trim() || null;

      const url = new URL(`${DISCORD_API}/guilds/${guildId}/members`);
      url.searchParams.set("limit", String(Math.min(limit, 1000)));
      if (after) url.searchParams.set("after", after);

      const listRes = await fetch(url.toString(), {
        headers: {
          Authorization: `Bot ${botToken}`,
          "Content-Type": "application/json",
        },
      });
      if (!listRes.ok) {
        const text = await listRes.text();
        return jsonResponse(
          {
            error: `Discord members ${listRes.status}: ${text.slice(0, 200)}`,
          },
          500
        );
      }

      const batch = (await listRes.json()) as Array<{
        user?: { id?: string; bot?: boolean };
      }>;
      if (!Array.isArray(batch)) {
        return jsonResponse({ error: "Unexpected Discord members payload" }, 500);
      }

      const results: SyncResult[] = [];
      let lastId: string | null = null;

      for (const m of batch) {
        const uid = m.user?.id ? String(m.user.id) : "";
        if (!uid) continue;
        lastId = uid;
        if (m.user?.bot) continue;

        const resolved = await resolveTier(admin, { discord_user_id: uid });
        if ("error" in resolved) {
          results.push({
            discord_user_id: uid,
            tier: "visitor",
            added: [],
            removed: [],
            error: resolved.error,
          });
          continue;
        }
        results.push(
          await syncDiscordUser(
            botToken,
            guildId,
            resolved.discord_user_id,
            resolved.tier,
            roles
          )
        );
      }

      const errors = results.filter((r) => r.error).length;
      const changed = results.filter(
        (r) => r.added.length || r.removed.length
      ).length;
      const done = batch.length < Math.min(limit, 1000);

      return jsonResponse({
        ok: true,
        action: "sync_guild",
        scanned: results.length,
        changed,
        errors,
        next_after: done ? null : lastId,
        done,
        results: results.slice(0, 40),
      });
    }

    return jsonResponse(
      {
        error:
          "Unknown action — use sync_one, sync_linked, or sync_guild",
      },
      400
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
