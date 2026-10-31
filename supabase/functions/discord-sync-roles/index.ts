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
  for (let attempt = 0; attempt < 6; attempt++) {
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
    if (res.status === 429) {
      const retryAfter =
        Number((json as { retry_after?: number })?.retry_after) ||
        Number(res.headers.get("retry-after")) ||
        1;
      await sleep(Math.min(Math.ceil(retryAfter * 1000) + 150, 5000));
      continue;
    }
    return { ok: res.ok, status: res.status, json, text };
  }
  return {
    ok: false,
    status: 429,
    json: null,
    text: "rate_limited_exhausted",
  };
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
        // First-time Visitor → welcome pack DM (idempotent edge)
        if (roles.visitor && roleId === roles.visitor && tier === "visitor") {
          try {
            const welcomeUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/discord-welcome-pack`;
            const feedKey =
              Deno.env.get("DISCORD_FEED_INVOKE_KEY") ||
              Deno.env.get("CRON_API_KEY") ||
              Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
              "";
            if (feedKey) {
              await fetch(welcomeUrl, {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  Authorization: `Bearer ${feedKey}`,
                  "x-discord-feed-key": feedKey,
                },
                body: JSON.stringify({
                  action: "welcome_one",
                  discord_user_id: discordUserId,
                  assign_visitor: false,
                  source: "discord-sync-roles",
                }),
              });
            }
          } catch {
            /* non-fatal */
          }
        }
      } else if (put.status !== 404) {
        result.error = `add_${roleId}_${put.status}: ${put.text.slice(0, 160)}`;
        return result;
      }
      await sleep(400);
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
      await sleep(400);
    }
  }

  return result;
}

function normalizeTag(s: string): string {
  return String(s || "")
    .trim()
    .toLowerCase();
}

function memberLookupTags(m: {
  nick?: string | null;
  user?: {
    username?: string;
    global_name?: string | null;
    discriminator?: string;
  };
}): string[] {
  const u = m.user;
  const username = u?.username
    ? u.discriminator && u.discriminator !== "0"
      ? `${u.username}#${u.discriminator}`
      : u.username
    : "";
  return [m.nick || "", u?.global_name || "", username, u?.username || ""]
    .map(normalizeTag)
    .filter(Boolean);
}

async function ownerHasClub(
  // deno-lint-ignore no-explicit-any
  admin: any,
  ownerId: string
): Promise<boolean> {
  const { data: club } = await admin
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", ownerId)
    .limit(1)
    .maybeSingle();
  const short = String(club?.ShortName || "").trim();
  return !!(short && short.toUpperCase() !== "FOREIGN");
}

async function resolveTier(
  // deno-lint-ignore no-explicit-any
  admin: any,
  opts: {
    owner_id?: string | null;
    discord_user_id?: string | null;
    lookup_tags?: string[];
    auto_link?: boolean;
  }
): Promise<
  | { discord_user_id: string; tier: Tier; linked_owner_id?: string | null }
  | { error: string }
> {
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

    return {
      discord_user_id: discordUserId,
      tier: (await ownerHasClub(admin, ownerId)) ? "owner" : "member",
    };
  }

  if (!discordUserId) return { error: "missing_owner_or_discord_id" };

  const { data: byDiscord } = await admin
    .from("gpsl_owner_registry")
    .select("owner_id")
    .eq("discord_user_id", discordUserId)
    .maybeSingle();
  if (byDiscord?.owner_id) {
    return {
      discord_user_id: discordUserId,
      tier: (await ownerHasClub(admin, String(byDiscord.owner_id)))
        ? "owner"
        : "member",
    };
  }

  // Tag match → link snowflake so Owner/Member roles can apply
  const tags = (opts.lookup_tags || []).map(normalizeTag).filter(Boolean);
  if (tags.length) {
    const { data: registryRows } = await admin
      .from("gpsl_owner_registry")
      .select("owner_id, owner_tag, discord_user_id");

    let matched: { owner_id: string; owner_tag: string } | null = null;
    for (const row of registryRows || []) {
      const tag = normalizeTag(row.owner_tag || "");
      if (!tag || !tags.includes(tag)) continue;
      const existing = String(row.discord_user_id || "").trim();
      if (existing && existing !== discordUserId) continue; // taken by someone else
      matched = {
        owner_id: String(row.owner_id),
        owner_tag: String(row.owner_tag || ""),
      };
      break;
    }

    if (matched?.owner_id) {
      const matchedRow = (registryRows || []).find(
        (r: { owner_id: string; discord_user_id?: string | null }) =>
          String(r.owner_id) === matched!.owner_id
      ) as { discord_user_id?: string | null } | undefined;
      const existing = String(matchedRow?.discord_user_id || "").trim();
      if (opts.auto_link !== false && !existing) {
        const { error: linkErr } = await admin
          .from("gpsl_owner_registry")
          .update({ discord_user_id: discordUserId })
          .eq("owner_id", matched.owner_id);
        if (linkErr) {
          const { data: again } = await admin
            .from("gpsl_owner_registry")
            .select("owner_id")
            .eq("discord_user_id", discordUserId)
            .maybeSingle();
          if (!again?.owner_id) {
            return { error: `auto_link_failed: ${linkErr.message}` };
          }
        }
      }
      return {
        discord_user_id: discordUserId,
        tier: (await ownerHasClub(admin, matched.owner_id)) ? "owner" : "member",
        linked_owner_id: matched.owner_id,
      };
    }

    // Clubs.owner text match when registry tag missing/mismatched
    const { data: clubRows } = await admin
      .from("Clubs")
      .select("ShortName, owner, owner_id, is_archived");
    for (const row of clubRows || []) {
      if (row.is_archived === true) continue;
      const short = String(row.ShortName || "").trim();
      if (!short || short.toUpperCase() === "FOREIGN") continue;
      const clubTag = normalizeTag(row.owner || "");
      if (!clubTag || !tags.includes(clubTag) || !row.owner_id) continue;
      const oid = String(row.owner_id);
      if (opts.auto_link !== false) {
        const { data: regForClub } = await admin
          .from("gpsl_owner_registry")
          .select("discord_user_id")
          .eq("owner_id", oid)
          .maybeSingle();
        if (!String(regForClub?.discord_user_id || "").trim()) {
          await admin
            .from("gpsl_owner_registry")
            .update({ discord_user_id: discordUserId })
            .eq("owner_id", oid);
        }
      }
      return {
        discord_user_id: discordUserId,
        tier: "owner",
        linked_owner_id: oid,
      };
    }
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
      // Allows feed key / service role / admin JWT (needed for SQL catch-up).
      // Also tag-matches unlinked GPSL registry rows and writes discord_user_id.
      const limitRaw = Number(body.limit);
      const limit = Math.min(
        Math.max(Number.isFinite(limitRaw) ? limitRaw : 100, 1),
        isAdminJwt ? 200 : 100
      );
      const after = String(body.after || "").trim() || null;
      const autoLink = body.auto_link !== false;

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
        nick?: string | null;
        user?: {
          id?: string;
          bot?: boolean;
          username?: string;
          global_name?: string | null;
          discriminator?: string;
        };
      }>;
      if (!Array.isArray(batch)) {
        return jsonResponse({ error: "Unexpected Discord members payload" }, 500);
      }

      const results: Array<SyncResult & { linked_owner_id?: string | null }> =
        [];
      let lastId: string | null = null;
      let linked = 0;

      for (const m of batch) {
        const uid = m.user?.id ? String(m.user.id) : "";
        if (!uid) continue;
        lastId = uid;
        if (m.user?.bot) continue;

        const resolved = await resolveTier(admin, {
          discord_user_id: uid,
          lookup_tags: memberLookupTags(m),
          auto_link: autoLink,
        });
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
        if (resolved.linked_owner_id) linked += 1;
        const sync = await syncDiscordUser(
          botToken,
          guildId,
          resolved.discord_user_id,
          resolved.tier,
          roles
        );
        results.push({ ...sync, linked_owner_id: resolved.linked_owner_id || null });
        await sleep(350);
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
        linked,
        errors,
        next_after: done ? null : lastId,
        done,
        results: results.slice(0, 40),
      });
    }

    if (action === "audit_guild") {
      // Count people who currently hold the three managed roles (bots excluded).
      const members: Array<{ user?: { bot?: boolean }; roles?: string[] }> = [];
      let afterAudit: string | null = null;
      for (let page = 0; page < 20; page++) {
        const url = new URL(`${DISCORD_API}/guilds/${guildId}/members`);
        url.searchParams.set("limit", "1000");
        if (afterAudit) url.searchParams.set("after", afterAudit);
        const listRes = await fetch(url.toString(), {
          headers: {
            Authorization: `Bot ${botToken}`,
            "Content-Type": "application/json",
          },
        });
        if (!listRes.ok) {
          const text = await listRes.text();
          return jsonResponse(
            { error: `Discord members ${listRes.status}: ${text.slice(0, 200)}` },
            500
          );
        }
        const batch = (await listRes.json()) as typeof members;
        if (!Array.isArray(batch) || batch.length === 0) break;
        members.push(...batch);
        const last = batch[batch.length - 1]?.user
          ? String((batch[batch.length - 1] as { user?: { id?: string } }).user?.id || "")
          : "";
        // deno-lint-ignore no-explicit-any
        const lastId = String((batch[batch.length - 1] as any)?.user?.id || "");
        if (!lastId || batch.length < 1000) break;
        afterAudit = lastId;
        void last;
      }

      const people = members.filter((m) => m.user && !m.user.bot);
      let owner = 0;
      let member = 0;
      let visitor = 0;
      let none = 0;
      let bothOwnerMember = 0;
      for (const m of people) {
        const ids = Array.isArray(m.roles) ? m.roles.map(String) : [];
        const hasO = !!(roles.owner && ids.includes(roles.owner));
        const hasM = !!(roles.member && ids.includes(roles.member));
        const hasV = !!(roles.visitor && ids.includes(roles.visitor));
        if (hasO) owner += 1;
        if (hasM) member += 1;
        if (hasV) visitor += 1;
        if (hasO && hasM) bothOwnerMember += 1;
        if (!hasO && !hasM && !hasV) none += 1;
      }

      return jsonResponse({
        ok: true,
        action: "audit_guild",
        humans: people.length,
        discord_role_counts: {
          owner,
          member,
          visitor,
          none_of_three: none,
          owner_and_member: bothOwnerMember,
        },
        exclusive_buckets: {
          owner: owner,
          member_only: Math.max(member - bothOwnerMember, 0),
          visitor,
          unsynced: none,
          sum:
            owner +
            Math.max(member - bothOwnerMember, 0) +
            visitor +
            none,
        },
      });
    }

    return jsonResponse(
      {
        error:
          "Unknown action — use sync_one, sync_linked, sync_guild, or audit_guild",
      },
      400
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: message }, 500);
  }
});
