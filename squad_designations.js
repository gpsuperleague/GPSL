/**
 * Squad designations: Star (automatic), One of our own, Fan Favourite
 */

import { isHomeGrownPlayer } from "./squad_rules.js";

export const DESIGNATION_STAR = "star";
export const DESIGNATION_OOO = "one_of_our_own";
export const DESIGNATION_FF = "fan_favourite";

export function parsePlayerRating(player) {
  const raw = String(player?.Rating ?? "").replace(/[^0-9]/g, "");
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : null;
}

export function playerEligibleStar(player, minRating = 79) {
  const r = parsePlayerRating(player);
  return r != null && r >= minRating;
}

export function playerEligibleOoo(player, clubNation, minRating = 79) {
  return (
    isHomeGrownPlayer(player, clubNation) && playerEligibleStar(player, minRating)
  );
}

export function playerEligibleFanFavourite(player) {
  const r = parsePlayerRating(player);
  return r != null && r >= 76 && r <= 78;
}

export function designationForPlayer(state, playerId) {
  const id = String(playerId ?? "");
  return state?.designations?.[id] || null;
}

export function designationEditOpen(state) {
  return state?.designation_edit_open !== false;
}

/**
 * Role options for the per-player Action dropdown (Squad page).
 * Stars are automatic. Manual: One of our own XOR Fan Favourite.
 */
export function squadRoleActionOptionsHtml(player, state, clubNation) {
  if (!state) return "";
  const pid = String(player.Konami_ID);
  const current = designationForPlayer(state, pid);
  const minRating = Number(state?.star_min_rating ?? 79);
  const oooId = state?.one_of_our_own_player_id
    ? String(state.one_of_our_own_player_id)
    : null;
  const ffId = state?.fan_favourite_player_id
    ? String(state.fan_favourite_player_id)
    : null;
  const oooAllowed = state?.ooo_allowed !== false;
  const editOpen = designationEditOpen(state);

  if (current === DESIGNATION_OOO) {
    if (!editOpen) return "";
    return `<option value="role:">Remove One of our own</option>`;
  }
  if (current === DESIGNATION_FF) {
    if (!editOpen) return "";
    return `<option value="role:">Remove Fan Favourite</option>`;
  }

  if (!editOpen) return "";

  const parts = [];

  const canOoo =
    oooAllowed &&
    playerEligibleOoo(player, clubNation, minRating) &&
    !ffId &&
    (!oooId || oooId === pid);
  if (canOoo) {
    parts.push(
      `<option value="role:${DESIGNATION_OOO}">Set as One of our own</option>`
    );
  }

  const canFf =
    playerEligibleFanFavourite(player) &&
    !oooId &&
    (!ffId || ffId === pid);
  if (canFf) {
    parts.push(
      `<option value="role:${DESIGNATION_FF}">Set as Fan Favourite (50% wage)</option>`
    );
  }

  return parts.join("");
}

/** @deprecated Prefer squadRoleActionOptionsHtml — kept for older callers */
export function squadDesignationOptionsHtml(player, state, clubNation) {
  return squadRoleActionOptionsHtml(player, state, clubNation);
}

export function designationRoleBadge(designation) {
  if (designation === DESIGNATION_STAR) {
    return `<span class="squad-role-badge squad-role-star" title="Star player">★</span>`;
  }
  if (designation === DESIGNATION_OOO) {
    return `<span class="squad-role-badge squad-role-ooo" title="One of our own">OOO</span>`;
  }
  if (designation === DESIGNATION_FF) {
    return `<span class="squad-role-badge squad-role-ff" title="Fan Favourite — Central Bank pays 50% wage">FF</span>`;
  }
  return "";
}

export async function loadSquadDesignationsState(client, clubShort) {
  const { data, error } = await client.rpc("club_squad_designations_state", {
    p_club_short_name: clubShort,
  });
  if (error) {
    console.warn("club_squad_designations_state:", error);
    return null;
  }
  return data;
}

export async function setSquadDesignation(client, playerId, designation) {
  const { data, error } = await client.rpc("club_squad_set_designation", {
    p_player_id: String(playerId),
    p_designation: designation || null,
  });
  if (error) throw error;
  return data;
}

export function starComplianceRow(state) {
  const cap = Number(state?.star_cap ?? 2);
  const count = Number(state?.star_count ?? 0);
  const tier = state?.division_tier === "superleague" ? "Super League" : "Championship";
  const minRating = Number(state?.star_min_rating ?? 79);
  return {
    rule: "Star players",
    whoCounts: `All players rated ${minRating}+ (automatic; ${tier})`,
    requirement: `Up to ${cap}`,
    note: "OooO excused. August over-cap: lowest stars released @ 125% MV + ₿2.5m fine each",
    count: `${count} / ${cap}`,
    ok: count <= cap,
    status: count <= cap ? "Within limit" : "Over limit",
  };
}

export function projectedStarCount(state, ghostPlayers = []) {
  const owned = Number(state?.star_count ?? 0);
  const minRating = Number(state?.star_min_rating ?? 79);
  const oooId =
    state?.one_of_our_own_player_id != null
      ? String(state.one_of_our_own_player_id)
      : null;
  let add = 0;
  for (const p of ghostPlayers || []) {
    if (!p) continue;
    if (oooId && String(p.Konami_ID) === oooId) continue;
    if (playerEligibleStar(p, minRating)) add += 1;
  }
  return owned + add;
}

export function projectedStarComplianceRow(state, ghostPlayers = []) {
  const cap = Number(state?.star_cap ?? 2);
  const count = projectedStarCount(state, ghostPlayers);
  const base = starComplianceRow(state);
  return {
    ...base,
    count,
    ok: count <= cap,
    status: count <= cap ? "Within limit" : "Over limit",
  };
}

export function oooComplianceRow(state) {
  const has = !!state?.one_of_our_own_player_id;
  const oooAllowed = state?.ooo_allowed !== false;
  const editOpen = designationEditOpen(state);
  if (!oooAllowed) {
    return {
      rule: "One of our own",
      whoCounts: "Nation has no 79+ in GPDB pool",
      requirement: "Not available",
      note: "Use Fan Favourite instead (76–78, 50% wage paid by Central Bank)",
      count: 0,
      ok: true,
      status: "N/A — Fan Favourite only",
    };
  }
  return {
    rule: "One of our own",
    whoCounts: "Home-grown star — Action menu (XOR Fan Favourite)",
    requirement: "Optional (1 slot)",
    note: editOpen
      ? "Excused from star cap/tax. Editable Jun / Jul / Jan only."
      : "Excused from star cap/tax. Locked until Jun / Jul / Jan.",
    count: has ? 1 : 0,
    ok: true,
    status: has ? "Assigned" : "Not assigned",
  };
}

export function fanFavouriteComplianceRow(state) {
  const has = !!state?.fan_favourite_player_id;
  const oooAllowed = state?.ooo_allowed !== false;
  const editOpen = designationEditOpen(state);
  return {
    rule: "Fan Favourite",
    whoCounts: oooAllowed
      ? "Any nationality rated 76–78 — XOR One of our own"
      : "Any nationality rated 76–78 (only option — no nation stars)",
    requirement: "Optional (1 slot)",
    note: editOpen
      ? "Central Bank pays 50% of their wage. Editable Jun / Jul / Jan only."
      : "Central Bank pays 50% of their wage. Locked until Jun / Jul / Jan.",
    count: has ? 1 : 0,
    ok: true,
    status: has ? "Assigned" : "Not assigned",
  };
}
