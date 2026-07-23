/**
 * Squad designations: Star player & One of our own
 */

import { isHomeGrownPlayer } from "./squad_rules.js";

export const DESIGNATION_STAR = "star";
export const DESIGNATION_OOO = "one_of_our_own";

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
  // Must be home-grown (Nation matches club) AND a star (rated minRating+).
  return (
    isHomeGrownPlayer(player, clubNation) && playerEligibleStar(player, minRating)
  );
}

export function designationForPlayer(state, playerId) {
  const id = String(playerId ?? "");
  return state?.designations?.[id] || null;
}

export function squadDesignationOptionsHtml(player, state, clubNation) {
  if (!state) {
    return '<option value="" selected>Role unavailable</option>';
  }
  const pid = String(player.Konami_ID);
  const current = designationForPlayer(state, pid);
  const minRating = Number(state?.star_min_rating ?? 79);
  const starCap = Number(state?.star_cap ?? 2);
  const starCount = Number(state?.star_count ?? 0);
  const oooId = state?.one_of_our_own_player_id
    ? String(state.one_of_our_own_player_id)
    : null;

  const canStar =
    playerEligibleStar(player, minRating) &&
    (current === DESIGNATION_STAR || starCount < starCap);
  const canOoo =
    playerEligibleOoo(player, clubNation) &&
    (!oooId || oooId === pid);

  const starDisabled = !canStar && current !== DESIGNATION_STAR;
  const oooDisabled = !canOoo && current !== DESIGNATION_OOO;

  const starHint = starDisabled
    ? current === DESIGNATION_STAR
      ? ""
      : starCount >= starCap
        ? ` — limit ${starCap} reached`
        : ` — need ${minRating}+ rating`
    : "";
  const oooHint = oooDisabled
    ? current === DESIGNATION_OOO
      ? ""
      : oooId && oooId !== pid
        ? " — club already has One of our own"
        : " — home-grown only"
    : "";

  return `
    <option value=""${current ? "" : " selected"}>Normal</option>
    <option value="${DESIGNATION_STAR}"${current === DESIGNATION_STAR ? " selected" : ""}${starDisabled ? " disabled" : ""}>★ Star player${starHint}</option>
    <option value="${DESIGNATION_OOO}"${current === DESIGNATION_OOO ? " selected" : ""}${oooDisabled ? " disabled" : ""}>🏠 One of our own${oooHint}</option>
  `;
}

/**
 * Role options for the per-player Action dropdown (Squad page).
 * Stars are automatic (rating-based) and are NOT set here. The only manual role
 * is "One of our own": the owner nominates ONE home-grown star (Nation matches
 * club, rated minRating+). The option only appears for eligible players and only
 * while the club's single OOO slot is free (or already this player).
 * Values are prefixed "role:" so the action handler can route them.
 */
export function squadRoleActionOptionsHtml(player, state, clubNation) {
  if (!state) return "";
  const pid = String(player.Konami_ID);
  const current = designationForPlayer(state, pid);
  const minRating = Number(state?.star_min_rating ?? 79);
  const oooId = state?.one_of_our_own_player_id
    ? String(state.one_of_our_own_player_id)
    : null;

  if (current === DESIGNATION_OOO) {
    return `<option value="role:">✕ Remove One of our own</option>`;
  }

  const canOoo =
    playerEligibleOoo(player, clubNation, minRating) && (!oooId || oooId === pid);
  if (canOoo) {
    return `<option value="role:${DESIGNATION_OOO}">🏠 Set as One of our own</option>`;
  }
  return "";
}

export function designationRoleBadge(designation) {
  if (designation === DESIGNATION_STAR) {
    return `<span class="squad-role-badge squad-role-star" title="Star player">★</span>`;
  }
  if (designation === DESIGNATION_OOO) {
    return `<span class="squad-role-badge squad-role-ooo" title="One of our own">OOO</span>`;
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

export function oooComplianceRow(state) {
  const has = !!state?.one_of_our_own_player_id;
  return {
    rule: "One of our own",
    whoCounts: "Home-grown talisman — set via the Action menu",
    requirement: "1 recommended",
    note: "Does not count toward star limit",
    count: has ? 1 : 0,
    ok: has,
    status: has ? "Assigned" : "Not assigned",
  };
}
