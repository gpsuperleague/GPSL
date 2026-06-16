/**
 * GPSL International football — World Cup, nations, squads
 */
import { supabase } from "./supabase_client.js";
import { normalizeNation } from "./squad_rules.js";

export const NATIONAL_SQUAD_MAX = 23;
export const NATIONAL_SQUAD_MIN_GK = 2;
export const NATION_POOL_MIN_PLAYERS = 24;

/** Min GPDB players per band to support one GPSL club on this nation. */
export const NATION_HEALTHY_CLUB_REQUIREMENTS = [
  { key: "r79_plus", min: 1, label: "79+ star" },
  { key: "r76_78", min: 1, label: "76–78" },
  { key: "r73_75", min: 5, label: "73–75" },
  { key: "r70_72", min: 10, label: "70–72" },
  { key: "r66_69", min: 10, label: "66–69" },
  { key: "le_65", min: 5, label: "≤65" },
  { key: "u21", min: 8, label: "U21" },
];

export function nationPoolSection(row, key) {
  return row?.pool?.[key] || { total: 0, gk: 0, def: 0, mid: 0, fwd: 0 };
}

export function nationPoolStatus(row) {
  const all = nationPoolSection(row, "all");
  if (all.total === 0) return { key: "bad", label: "No GPDB match" };
  if (all.total >= NATION_POOL_MIN_PLAYERS && all.gk >= NATIONAL_SQUAD_MIN_GK) {
    return { key: "ok", label: "OK" };
  }
  if (all.total >= 23 && all.gk >= NATIONAL_SQUAD_MIN_GK) {
    return { key: "warn", label: "Tight" };
  }
  return { key: "bad", label: "Short" };
}

export function nationHealthyClubCapacity(row) {
  const caps = NATION_HEALTHY_CLUB_REQUIREMENTS.map(({ key, min }) => {
    const available = nationPoolSection(row, key).total;
    return Math.floor(available / min);
  });
  return caps.length ? Math.min(...caps) : 0;
}

export function nationHasViableSquad(row) {
  return nationPoolStatus(row).key === "ok";
}

export function nationCanSupportAnyClub(row) {
  return nationHealthyClubCapacity(row) > 0;
}

/** True when pool is too thin for a full squad and/or cannot support any club. */
export function nationPoolIsFaint(row) {
  if (!row?.pool) return false;
  return !nationHasViableSquad(row) || !nationCanSupportAnyClub(row);
}

/** Nations owners may claim during nation selection. */
export function nationPoolIsSelectable(row) {
  if (!row?.pool) return true;
  return !nationPoolIsFaint(row);
}

export function nationPoolFaintTitle(row) {
  if (!row?.pool || !nationPoolIsFaint(row)) return "";
  const parts = [];
  if (!nationHasViableSquad(row)) {
    parts.push(
      `Needs ≥${NATION_POOL_MIN_PLAYERS} GPDB players and ≥${NATIONAL_SQUAD_MIN_GK} GKs for a 23-man squad`
    );
  }
  if (!nationCanSupportAnyClub(row)) {
    parts.push("Pool too thin to support a GPSL club");
  }
  return parts.join(" · ");
}

export const WC_QUAL_GROUPS = 12;
export const WC_QUAL_GROUP_SIZE = 5;
export const WC_FINALS_GROUPS = 8;
export const WC_FINALS_GROUP_SIZE = 4;
export const WC_FINALS_TEAMS = 32;

export async function loadInternationalNations(client = supabase) {
  const { data, error } = await client
    .from("international_nations_public")
    .select("*")
    .order("seed_rank", { ascending: true });
  if (error) {
    console.error("loadInternationalNations:", error);
    return [];
  }
  return data || [];
}

export async function loadMyNation(client = supabase) {
  const { data, error } = await client
    .from("international_my_nation_public")
    .select("*")
    .maybeSingle();
  if (error) {
    console.error("loadMyNation:", error);
    return null;
  }
  return data;
}

export async function loadOwnerDraftOrder(client = supabase) {
  const { data, error } = await client
    .from("international_owner_rank_public")
    .select("*")
    .order("pick_order", { ascending: true });
  if (error) {
    console.error("loadOwnerDraftOrder:", error);
    return [];
  }
  return data || [];
}

export async function loadSelectionWindow(client = supabase) {
  const { data, error } = await client
    .from("international_selection_public")
    .select("*")
    .maybeSingle();
  if (error) {
    console.error("loadSelectionWindow:", error);
    return null;
  }
  return data;
}

export async function loadWcCycles(client = supabase) {
  const { data, error } = await client
    .from("international_wc_cycle_public")
    .select("*")
    .order("cycle_no", { ascending: false });
  if (error) {
    console.error("loadWcCycles:", error);
    return [];
  }
  return data || [];
}

export async function loadQualStandings(cycleNo, client = supabase) {
  let query = client
    .from("international_qual_standings_public")
    .select("*")
    .order("group_code", { ascending: true })
    .order("points", { ascending: false });
  if (cycleNo != null) query = query.eq("cycle_no", cycleNo);
  const { data, error } = await query;
  if (error) {
    console.error("loadQualStandings:", error);
    return [];
  }
  return data || [];
}

export async function loadFinalsStandings(cycleNo, client = supabase) {
  let query = client
    .from("international_finals_standings_public")
    .select("*")
    .order("group_code", { ascending: true })
    .order("points", { ascending: false });
  if (cycleNo != null) query = query.eq("cycle_no", cycleNo);
  const { data, error } = await query;
  if (error) {
    console.error("loadFinalsStandings:", error);
    return [];
  }
  return data || [];
}

export function isGoalkeeper(position) {
  return String(position ?? "").trim().toUpperCase() === "GK";
}

/** Player Players.Nation matches an international_nations row (name or code). */
export function playerBelongsToNation(player, nation) {
  if (!player || !nation) return false;
  const pn = normalizeNation(player.Nation ?? player.nation ?? player.player_nation);
  if (!pn) return false;
  const nameNorm = normalizeNation(nation.name);
  const codeNorm = normalizeNation(nation.code);
  return pn === nameNorm || pn === codeNorm;
}

export function summarizeNationalSquad(rows) {
  const squad = rows || [];
  const gkCount = squad.filter((r) => isGoalkeeper(r.player_position)).length;
  return {
    total: squad.length,
    gkCount,
    max: NATIONAL_SQUAD_MAX,
    minGk: NATIONAL_SQUAD_MIN_GK,
    gkOk: gkCount >= NATIONAL_SQUAD_MIN_GK,
    full: squad.length >= NATIONAL_SQUAD_MAX,
  };
}

/** Nation filter values in GPDB that match the owner's international nation. */
export function gpdbNationFilterValues(nation, nationFilterOptions = []) {
  if (!nation) return [];
  return (nationFilterOptions || [])
    .filter((opt) => playerBelongsToNation({ Nation: opt.value }, nation))
    .map((opt) => opt.value);
}

/** Admin: GPDB pool counts by nation (rating bands, U21, position). Reads precomputed cache. */
export async function loadNationPlayerPoolReport(client = supabase) {
  const { data, error } = await client.rpc("international_nation_player_pool_report");
  if (error) {
    console.error("loadNationPlayerPoolReport:", error);
    throw error;
  }
  return data || [];
}

/** When pool counts were last scanned from GPDB Players (cache meta). */
export async function loadNationPlayerPoolCacheMeta(client = supabase) {
  const { data, error } = await client.rpc("international_nation_player_pool_cache_meta");
  if (error) {
    console.error("loadNationPlayerPoolCacheMeta:", error);
    return null;
  }
  return data;
}

/** Admin: rescan GPDB Players into nation pool cache (~30–90s). Run after GPDB import or nation sync. */
export async function refreshNationPlayerPoolCache(client = supabase) {
  const { data, error } = await client.rpc("international_refresh_nation_player_pool_cache");
  if (error) {
    console.error("refreshNationPlayerPoolCache:", error);
    throw error;
  }
  return data;
}

export async function loadNationalSquad(nationCode, client = supabase) {
  const { data, error } = await client
    .from("international_squad_public")
    .select("*")
    .eq("nation_code", nationCode)
    .order("player_name", { ascending: true });
  if (error) {
    console.error("loadNationalSquad:", error);
    return [];
  }
  return data || [];
}

export async function claimNation(nationCode, client = supabase) {
  const { data, error } = await client.rpc("international_claim_nation", {
    p_nation_code: nationCode,
  });
  if (error) return { error: error.message };
  return { data };
}

export async function callUpPlayer(playerId, client = supabase) {
  const { error } = await client.rpc("international_call_up_player", {
    p_player_id: playerId,
  });
  if (error) return { error: error.message };
  return { ok: true };
}

export async function releaseCallup(playerId, client = supabase) {
  const { error } = await client.rpc("international_release_callup", {
    p_player_id: playerId,
  });
  if (error) return { error: error.message };
  return { ok: true };
}

export function nationLink(code, label) {
  const text = label || code;
  return `<a href="national_team.html?nation=${encodeURIComponent(code)}">${text}</a>`;
}

export { nationFlagSrc, renderNationFlag } from "./international_flags.js";

export function groupStandingsTable(rows, groupCode) {
  const groupRows = rows.filter((r) => r.group_code === groupCode);
  if (!groupRows.length) {
    return `<p class="empty">Group ${groupCode} — not drawn yet.</p>`;
  }
  const body = groupRows
    .map(
      (r, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>${renderNationFlag(r, "sm")} ${nationLink(r.nation_code, r.nation_name)}</td>
        <td>${r.played}</td>
        <td>${r.won}</td>
        <td>${r.drawn}</td>
        <td>${r.lost}</td>
        <td>${r.goals_for}:${r.goals_against}</td>
        <td><b>${r.points}</b></td>
      </tr>`
    )
    .join("");
  return `
    <table class="intl-table">
      <thead>
        <tr>
          <th>#</th><th>Nation</th><th>P</th><th>W</th><th>D</th><th>L</th><th>F:A</th><th>Pts</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}
