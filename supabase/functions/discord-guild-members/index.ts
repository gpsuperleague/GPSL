import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { isGpslAdminOrMod } from "../_shared/gpsl_staff.ts";

const GPSL_ADMIN_EMAIL = "rotavator66@outlook.com";
const DISCORD_API = "https://discord.com/api/v10";

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

type DiscordUser = {
  id: string;
  username?: string;
  global_name?: string | null;
  discriminator?: string;
  bot?: boolean;
  avatar?: string | null;
};

type DiscordMember = {
  user?: DiscordUser;
  nick?: string | null;
  joined_at?: string;
  roles?: string[];
};

type GpslMatch = {
  owner_id: string | null;
  status: string | null;
  club_short_name: string | null;
  club_name: string | null;
  waiting_list_tier: string | null;
  matched_tag: string;
  email: string | null;
  match_via: "discord_user_id" | "tag";
};

type Tier = "owner" | "member" | "visitor";

function displayName(m: DiscordMember): string {
  const u = m.user;
  if (!u) return "Unknown";
  return (
    (m.nick && m.nick.trim()) ||
    (u.global_name && String(u.global_name).trim()) ||
    u.username ||
    u.id
  );
}

function usernameTag(u: DiscordUser | undefined): string {
  if (!u?.username) return "";
  if (u.discriminator && u.discriminator !== "0") {
    return `${u.username}#${u.discriminator}`;
  }
  return u.username;
}

function roleConfig() {
  return {
    member: (Deno.env.get("DISCORD_ROLE_MEMBER_ID") || "").trim(),
    owner: (Deno.env.get("DISCORD_ROLE_OWNER_ID") || "").trim(),
    visitor: (Deno.env.get("DISCORD_ROLE_VISITOR_ID") || "").trim(),
  };
}

function expectedTier(gpsl: GpslMatch | null): Tier {
  if (gpsl?.club_short_name) return "owner";
  if (gpsl?.owner_id) return "member";
  return "visitor";
}

function actualTier(
  roleIds: string[],
  roles: ReturnType<typeof roleConfig>
): Tier | "none" | "mixed" {
  const hasOwner = !!(roles.owner && roleIds.includes(roles.owner));
  const hasMember = !!(roles.member && roleIds.includes(roles.member));
  const hasVisitor = !!(roles.visitor && roleIds.includes(roles.visitor));
  if (hasOwner && hasMember && !hasVisitor) return "owner";
  if (hasMember && !hasOwner && !hasVisitor) return "member";
  if (hasVisitor && !hasOwner && !hasMember) return "visitor";
  if (!hasOwner && !hasMember && !hasVisitor) return "none";
  return "mixed";
}

async function fetchAllGuildMembers(
  botToken: string,
  guildId: string
): Promise<DiscordMember[]> {
  const members: DiscordMember[] = [];
  let after: string | null = null;

  for (let page = 0; page < 50; page++) {
    const url = new URL(`${DISCORD_API}/guilds/${guildId}/members`);
    url.searchParams.set("limit", "1000");
    if (after) url.searchParams.set("after", after);

    const res = await fetch(url, {
      headers: {
        Authorization: `Bot ${botToken}`,
        "Content-Type": "application/json",
      },
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(
        `Discord API ${res.status}: ${text.slice(0, 300) || res.statusText}`
      );
    }

    const batch = (await res.json()) as DiscordMember[];
    if (!Array.isArray(batch) || batch.length === 0) break;

    members.push(...batch);
    const last = batch[batch.length - 1]?.user?.id;
    if (!last || batch.length < 1000) break;
    after = last;
  }

  return members;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const botToken = Deno.env.get("DISCORD_BOT_TOKEN");
    const guildId = Deno.env.get("DISCORD_GUILD_ID");
    const roles = roleConfig();

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return jsonResponse({ error: "Server misconfigured" }, 500);
    }
    if (!botToken || !guildId) {
      return jsonResponse(
        {
          error:
            "Discord secrets missing — set DISCORD_BOT_TOKEN and DISCORD_GUILD_ID in Edge Function secrets",
        },
        500
      );
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

    if (!(await isGpslAdminOrMod(userClient, adminUser, GPSL_ADMIN_EMAIL))) {
      return jsonResponse({ error: "Admin or mod only" }, 403);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const rawMembers = await fetchAllGuildMembers(botToken, guildId);
    const people = rawMembers.filter((m) => m.user && !m.user.bot);

    const { data: registryRows } = await adminClient
      .from("gpsl_owner_registry")
      .select("owner_id, status, owner_tag, waiting_list_tier, discord_user_id");

    const { data: clubRows } = await adminClient
      .from("Clubs")
      .select('ShortName, Club, owner, owner_id, is_archived');

    const ownerIds = new Set<string>();
    for (const row of registryRows || []) {
      if (row.owner_id) ownerIds.add(String(row.owner_id));
    }
    for (const row of clubRows || []) {
      if (row.owner_id) ownerIds.add(String(row.owner_id));
    }

    const emailByOwnerId = new Map<string, string>();
    for (const oid of ownerIds) {
      try {
        const { data: userData, error: userErr } =
          await adminClient.auth.admin.getUserById(oid);
        if (!userErr && userData?.user?.email) {
          emailByOwnerId.set(oid, String(userData.user.email).toLowerCase());
        }
      } catch {
        /* skip */
      }
    }

    const clubByOwnerId = new Map<
      string,
      { short: string; name: string | null }
    >();
    for (const row of clubRows || []) {
      if (!row.owner_id) continue;
      if (row.is_archived === true) continue;
      const short = String(row.ShortName || "").trim();
      if (!short || short.toUpperCase() === "FOREIGN") continue;
      clubByOwnerId.set(String(row.owner_id), {
        short,
        name: String(row.Club || "").trim() || short,
      });
    }

    const byDiscordId = new Map<string, GpslMatch>();
    const byTag = new Map<string, GpslMatch>();

    for (const row of registryRows || []) {
      const oid = row.owner_id ? String(row.owner_id) : null;
      const club = oid ? clubByOwnerId.get(oid) : undefined;
      const base: GpslMatch = {
        owner_id: oid,
        status: row.status ?? null,
        club_short_name: club?.short ?? null,
        club_name: club?.name ?? null,
        waiting_list_tier: row.waiting_list_tier ?? null,
        matched_tag: String(row.owner_tag || "").trim(),
        email: oid ? emailByOwnerId.get(oid) || null : null,
        match_via: "discord_user_id",
      };

      const discordId = String(row.discord_user_id || "").trim();
      if (discordId) {
        byDiscordId.set(discordId, { ...base, match_via: "discord_user_id" });
      }

      const tag = String(row.owner_tag || "")
        .trim()
        .toLowerCase();
      if (tag) {
        byTag.set(tag, { ...base, match_via: "tag" });
      }
    }

    for (const row of clubRows || []) {
      if (row.is_archived === true) continue;
      const short = String(row.ShortName || "").trim();
      if (!short || short.toUpperCase() === "FOREIGN") continue;
      const tag = String(row.owner || "")
        .trim()
        .toLowerCase();
      if (!tag) continue;
      const oid = row.owner_id ? String(row.owner_id) : null;
      const prev = byTag.get(tag);
      const fullName = String(row.Club || "").trim() || null;
      byTag.set(tag, {
        owner_id: oid || prev?.owner_id || null,
        status: prev?.status || (row.owner_id ? "active" : null),
        club_short_name: short,
        club_name: fullName || short,
        waiting_list_tier: prev?.waiting_list_tier ?? null,
        matched_tag: String(row.owner || "").trim(),
        email:
          (oid && emailByOwnerId.get(oid)) ||
          prev?.email ||
          null,
        match_via: "tag",
      });
    }

    const members = people
      .map((m) => {
        const u = m.user!;
        const username = usernameTag(u);
        const nick = (m.nick || "").trim();
        const globalName = (u.global_name || "").trim();
        const roleIds = Array.isArray(m.roles) ? m.roles.map(String) : [];

        let gpsl: GpslMatch | null = byDiscordId.get(u.id) || null;
        if (!gpsl) {
          const lookupKeys = [username, nick, globalName, u.username || ""]
            .map((s) => s.trim().toLowerCase())
            .filter(Boolean);
          for (const key of lookupKeys) {
            if (byTag.has(key)) {
              gpsl = byTag.get(key)!;
              break;
            }
          }
        }

        // Prefer club from owner_id even when tag match lacked club fields
        if (gpsl?.owner_id && !gpsl.club_short_name) {
          const club = clubByOwnerId.get(gpsl.owner_id);
          if (club) {
            gpsl = {
              ...gpsl,
              club_short_name: club.short,
              club_name: club.name,
            };
          }
        }

        const expected = expectedTier(gpsl);
        const actual = actualTier(roleIds, roles);
        const rolesConfigured = !!(roles.member && roles.owner && roles.visitor);

        return {
          discord_user_id: u.id,
          username,
          display_name: displayName(m),
          global_name: globalName || null,
          nick: nick || null,
          joined_at: m.joined_at || null,
          avatar_url: u.avatar
            ? `https://cdn.discordapp.com/avatars/${u.id}/${u.avatar}.png?size=64`
            : null,
          discord_role_ids: roleIds,
          expected_tier: expected,
          actual_tier: rolesConfigured ? actual : null,
          role_mismatch: rolesConfigured
            ? actual !== expected &&
              !(expected === "owner" && actual === "owner")
            : null,
          gpsl_status: gpsl?.status ?? null,
          gpsl_club: gpsl?.club_name ?? gpsl?.club_short_name ?? null,
          gpsl_club_short: gpsl?.club_short_name ?? null,
          gpsl_owner_id: gpsl?.owner_id ?? null,
          gpsl_email: gpsl?.email ?? null,
          gpsl_matched_tag: gpsl?.matched_tag ?? null,
          gpsl_match_via: gpsl?.match_via ?? null,
          on_waiting_list:
            gpsl?.status === "member" || gpsl?.status === "on_absence",
          awaiting_club_auction: gpsl?.status === "awaiting_club_auction",
        };
      })
      .sort((a, b) => {
        const ta = a.joined_at ? Date.parse(a.joined_at) : Number.POSITIVE_INFINITY;
        const tb = b.joined_at ? Date.parse(b.joined_at) : Number.POSITIVE_INFINITY;
        if (ta !== tb) return ta - tb;
        return a.display_name.localeCompare(b.display_name);
      });

    const rolesConfigured = !!(roles.member && roles.owner && roles.visitor);
    const discordRoleCounts = {
      owner: 0,
      member: 0,
      visitor: 0,
      none_of_three: 0,
      mixed: 0,
    };
    const expectedCounts = { owner: 0, member: 0, visitor: 0 };
    let mismatches = 0;
    const sampleMismatches: Array<Record<string, unknown>> = [];

    for (const m of members) {
      expectedCounts[m.expected_tier as Tier] += 1;
      if (!rolesConfigured || m.actual_tier == null) continue;
      if (m.actual_tier === "owner") discordRoleCounts.owner += 1;
      else if (m.actual_tier === "member") discordRoleCounts.member += 1;
      else if (m.actual_tier === "visitor") discordRoleCounts.visitor += 1;
      else if (m.actual_tier === "none") discordRoleCounts.none_of_three += 1;
      else discordRoleCounts.mixed += 1;

      if (m.actual_tier !== m.expected_tier) {
        mismatches += 1;
        if (sampleMismatches.length < 25) {
          sampleMismatches.push({
            display_name: m.display_name,
            username: m.username,
            expected: m.expected_tier,
            actual: m.actual_tier,
            gpsl_club: m.gpsl_club,
            gpsl_status: m.gpsl_status,
            match_via: m.gpsl_match_via,
          });
        }
      }
    }

    // GPSL-side linkage (same universe as role sync)
    const registryLinked = (registryRows || []).filter(
      (r) => String(r.discord_user_id || "").trim()
    ).length;
    const clubOwners = [...clubByOwnerId.keys()];
    const clubOwnersLinked = clubOwners.filter((oid) => {
      const row = (registryRows || []).find((r) => String(r.owner_id) === oid);
      return !!(row && String(row.discord_user_id || "").trim());
    }).length;

    return jsonResponse({
      ok: true,
      guild_id: guildId,
      count: members.length,
      members,
      roles_configured: rolesConfigured,
      audit: {
        mapping: {
          owner: "Clubs.owner_id set → Discord Owner + Member",
          member: "gpsl_owner_registry row → Discord Member",
          visitor: "In Discord guild, no GPSL registry → Discord Visitor",
        },
        discord_role_counts: rolesConfigured ? discordRoleCounts : null,
        expected_from_guild_match: expectedCounts,
        role_mismatches: rolesConfigured ? mismatches : null,
        sample_mismatches: rolesConfigured ? sampleMismatches : [],
        gpsl_linkage: {
          registry_rows: (registryRows || []).length,
          registry_with_discord_id: registryLinked,
          club_owners: clubOwners.length,
          club_owners_with_discord_id: clubOwnersLinked,
          club_owners_missing_discord_id: clubOwners.length - clubOwnersLinked,
        },
        note:
          "“Sync roles now” only updates linked discord_user_id rows. Use Sync entire guild to assign Visitor (and fix roles) for everyone in Discord.",
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
