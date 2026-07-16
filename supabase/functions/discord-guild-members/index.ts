import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

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
  // New usernames have discriminator "0"
  if (u.discriminator && u.discriminator !== "0") {
    return `${u.username}#${u.discriminator}`;
  }
  return u.username;
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

    if ((adminUser.email || "").toLowerCase() !== GPSL_ADMIN_EMAIL) {
      return jsonResponse({ error: "Admin only" }, 403);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const rawMembers = await fetchAllGuildMembers(botToken, guildId);
    const people = rawMembers.filter((m) => m.user && !m.user.bot);

    // Match GPSL registry / clubs by owner tag (case-insensitive)
    const { data: registryRows } = await adminClient
      .from("gpsl_owner_registry")
      .select("owner_id, status, owner_tag, waiting_list_tier");

    const { data: clubRows } = await adminClient
      .from("Clubs")
      .select('ShortName, owner, owner_id');

    // Resolve emails for matched GPSL owners (for Set tag)
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

    const byTag = new Map<
      string,
      {
        owner_id: string | null;
        status: string | null;
        club_short_name: string | null;
        waiting_list_tier: string | null;
        matched_tag: string;
        email: string | null;
      }
    >();

    for (const row of registryRows || []) {
      const tag = String(row.owner_tag || "")
        .trim()
        .toLowerCase();
      if (!tag) continue;
      const oid = row.owner_id ? String(row.owner_id) : null;
      byTag.set(tag, {
        owner_id: oid,
        status: row.status,
        club_short_name: null,
        waiting_list_tier: row.waiting_list_tier ?? null,
        matched_tag: String(row.owner_tag || "").trim(),
        email: oid ? emailByOwnerId.get(oid) || null : null,
      });
    }

    for (const row of clubRows || []) {
      const tag = String(row.owner || "")
        .trim()
        .toLowerCase();
      if (!tag) continue;
      const oid = row.owner_id ? String(row.owner_id) : null;
      const prev = byTag.get(tag);
      byTag.set(tag, {
        owner_id: oid || prev?.owner_id || null,
        status: prev?.status || (row.owner_id ? "active" : null),
        club_short_name: row.ShortName,
        waiting_list_tier: prev?.waiting_list_tier ?? null,
        matched_tag: String(row.owner || "").trim(),
        email:
          (oid && emailByOwnerId.get(oid)) ||
          prev?.email ||
          null,
      });
    }

    const members = people
      .map((m) => {
        const u = m.user!;
        const username = usernameTag(u);
        const nick = (m.nick || "").trim();
        const globalName = (u.global_name || "").trim();
        const lookupKeys = [username, nick, globalName, u.username || ""]
          .map((s) => s.trim().toLowerCase())
          .filter(Boolean);

        let gpsl = null as null | {
          owner_id: string | null;
          status: string | null;
          club_short_name: string | null;
          waiting_list_tier: string | null;
          matched_tag: string;
          email: string | null;
        };

        for (const key of lookupKeys) {
          if (byTag.has(key)) {
            gpsl = byTag.get(key)!;
            break;
          }
        }

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
          gpsl_status: gpsl?.status ?? null,
          gpsl_club: gpsl?.club_short_name ?? null,
          gpsl_owner_id: gpsl?.owner_id ?? null,
          gpsl_email: gpsl?.email ?? null,
          gpsl_matched_tag: gpsl?.matched_tag ?? null,
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

    return jsonResponse({
      ok: true,
      guild_id: guildId,
      count: members.length,
      members,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
