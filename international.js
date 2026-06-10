/**
 * GPSL International football — World Cup, nations, squads
 */
import { supabase } from "./supabase_client.js";
import { normalizeNation } from "./squad_rules.js";

export const NATIONAL_SQUAD_MAX = 23;
export const NATIONAL_SQUAD_MIN_GK = 2;

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
