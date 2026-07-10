/**
 * GPSL International football — World Cup, nations, squads
 */
import { supabase } from "./supabase_client.js";
import { normalizeNation } from "./squad_rules.js";
import { nationFlagSrc, renderNationFlag } from "./international_flags.js";

export { nationFlagSrc, renderNationFlag };

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

/** True when pool is too thin for a full national squad. */
export function nationPoolIsFaint(row) {
  if (!row?.pool) return false;
  return !nationHasViableSquad(row);
}

/** Nations owners may claim during nation selection (23-man squad bar only). */
export function nationPoolIsSelectable(row) {
  if (!row?.pool) return true;
  return nationHasViableSquad(row);
}

export function nationPoolFaintTitle(row) {
  if (!row?.pool || !nationPoolIsFaint(row)) return "";
  if (!nationHasViableSquad(row)) {
    return `Needs ≥${NATION_POOL_MIN_PLAYERS} GPDB players and ≥${NATIONAL_SQUAD_MIN_GK} GKs for a 23-man squad`;
  }
  return "";
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
    .order("points", { ascending: false })
    .order("seed_rank", { ascending: true });
  if (cycleNo != null) query = query.eq("cycle_no", cycleNo);
  const { data, error } = await query;
  if (error) {
    // Older view without seed_rank — retry without that order
    if (/seed_rank/i.test(error.message || "")) {
      let q2 = client
        .from("international_qual_standings_public")
        .select("*")
        .order("group_code", { ascending: true })
        .order("points", { ascending: false });
      if (cycleNo != null) q2 = q2.eq("cycle_no", cycleNo);
      const retry = await q2;
      if (retry.error) {
        console.error("loadQualStandings:", retry.error);
        return [];
      }
      return retry.data || [];
    }
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
    .order("points", { ascending: false })
    .order("seed_rank", { ascending: true });
  if (cycleNo != null) query = query.eq("cycle_no", cycleNo);
  const { data, error } = await query;
  if (error) {
    if (/seed_rank/i.test(error.message || "")) {
      let q2 = client
        .from("international_finals_standings_public")
        .select("*")
        .order("group_code", { ascending: true })
        .order("points", { ascending: false });
      if (cycleNo != null) q2 = q2.eq("cycle_no", cycleNo);
      const retry = await q2;
      if (retry.error) {
        console.error("loadFinalsStandings:", retry.error);
        return [];
      }
      return retry.data || [];
    }
    console.error("loadFinalsStandings:", error);
    return [];
  }
  return data || [];
}

export async function loadInternationalFixtures(cycleNo, phase = null, client = supabase) {
  let query = client
    .from("international_fixtures_public")
    .select("*")
    .order("match_no", { ascending: true })
    .order("group_code", { ascending: true })
    .order("id", { ascending: true });
  if (cycleNo != null) query = query.eq("cycle_no", cycleNo);
  if (phase) query = query.eq("phase", phase);
  const { data, error } = await query;
  if (error) {
    console.error("loadInternationalFixtures:", error);
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

/**
 * Overall international career stats keyed by Konami ID.
 * Caps / G / A / POTM / CS / avg — not season-split.
 */
export async function loadInternationalCareerMap(playerIds, client = supabase) {
  const ids = [...new Set((playerIds || []).map((id) => String(id).trim()).filter(Boolean))];
  const map = new Map();
  if (!ids.length) return map;

  const chunkSize = 200;
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const { data, error } = await client
      .from("international_player_career_public")
      .select("player_id, caps, goals, assists, potm, clean_sheets, avg_rating")
      .in("player_id", chunk);
    if (error) {
      console.error("loadInternationalCareerMap:", error);
      continue;
    }
    for (const row of data || []) {
      map.set(String(row.player_id), {
        caps: row.caps ?? 0,
        goals: row.goals ?? 0,
        assists: row.assists ?? 0,
        potm: row.potm ?? 0,
        clean_sheets: row.clean_sheets ?? 0,
        avg_rating: row.avg_rating != null ? Number(row.avg_rating) : null,
      });
    }
  }
  return map;
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

export function groupStandingsTable(rows, groupCode) {
  const groupRows = rows
    .filter((r) => r.group_code === groupCode)
    .slice()
    .sort((a, b) => {
      const pts = Number(b.points || 0) - Number(a.points || 0);
      if (pts) return pts;
      const gd =
        Number(b.goal_diff ?? (b.goals_for || 0) - (b.goals_against || 0)) -
        Number(a.goal_diff ?? (a.goals_for || 0) - (a.goals_against || 0));
      if (gd) return gd;
      const gf = Number(b.goals_for || 0) - Number(a.goals_for || 0);
      if (gf) return gf;
      // At equal table (e.g. all 0 before kickoff): strongest seed first
      return (Number(a.seed_rank) || 9999) - (Number(b.seed_rank) || 9999);
    });
  if (!groupRows.length) {
    return `<p class="empty">Group ${groupCode} — not drawn yet.</p>`;
  }
  const body = groupRows
    .map(
      (r, i) => `
      <tr>
        <td>${i + 1}</td>
        <td>
          <span class="intl-nation-cell">
            ${renderNationFlag(r, "sm")}
            ${nationLink(r.nation_code, r.nation_name)}
            ${
              r.seed_rank != null
                ? `<span class="intl-seed" title="Seed rank">#${Number(r.seed_rank)}</span>`
                : ""
            }
          </span>
        </td>
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
      <colgroup>
        <col class="intl-col-pos">
        <col class="intl-col-nation">
        <col class="intl-col-stat"><col class="intl-col-stat"><col class="intl-col-stat"><col class="intl-col-stat">
        <col class="intl-col-fa">
        <col class="intl-col-pts">
      </colgroup>
      <thead>
        <tr>
          <th>#</th><th>Nation</th><th>P</th><th>W</th><th>D</th><th>L</th><th>F:A</th><th>Pts</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}
