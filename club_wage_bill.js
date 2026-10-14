/**
 * Seasonal wage bill for a club (players + manager).
 * Primary: competition_club_upkeep_preview RPC.
 * Fallback: sum Players.contract_wage + Managers.weekly_wage × 52.
 * Fan Favourite: club is charged full wages, Central Bank credits 50% back.
 */

import { formatMoney } from "./competition.js";

/**
 * @returns {Promise<{ playerId: string, playerName: string, fullWage: number, subsidy: number } | null>}
 */
export async function loadFanFavouriteSubsidy(supabase, clubShortName) {
  const club = String(clubShortName || "").trim();
  if (!club) return null;
  const { data, error } = await supabase.rpc("club_squad_fan_favourite_wage_half", {
    p_club_short_name: club,
  });
  if (error) {
    console.warn("club_squad_fan_favourite_wage_half:", error.message);
    return null;
  }
  const row = Array.isArray(data) ? data[0] : data;
  const subsidy = Number(row?.subsidy_half) || 0;
  if (!row?.player_id || subsidy <= 0) return null;
  return {
    playerId: String(row.player_id),
    playerName: row.player_name || "",
    fullWage: Number(row.full_wage) || 0,
    subsidy,
  };
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @returns {Promise<{ players: number, manager: number, total: number, fanFavourite: object | null, source: string }>}
 */
export async function loadClubWageBillSummary(supabase, clubShortName) {
  const club = String(clubShortName || "").trim();
  if (!club) {
    return { players: 0, manager: 0, total: 0, fanFavourite: null, source: "none" };
  }

  const [{ data, error }, fanFavourite] = await Promise.all([
    supabase.rpc("competition_club_upkeep_preview", { p_club_short_name: club }),
    loadFanFavouriteSubsidy(supabase, club),
  ]);
  const ffSubsidy = fanFavourite?.subsidy || 0;

  if (!error && data) {
    const players = Number(data.player_wage_bill ?? data.wage_bill ?? 0) || 0;
    const manager = Number(data.manager_salary ?? 0) || 0;
    const gross =
      Number(data.total_wage_bill) ||
      Math.round(players + manager);
    return { players, manager, total: gross - ffSubsidy, fanFavourite, source: "rpc" };
  }

  if (error) {
    console.warn("competition_club_upkeep_preview:", error.message);
  }

  const [{ data: players }, { data: mgrRows }] = await Promise.all([
    supabase.from("Players").select("contract_wage").eq("Contracted_Team", club),
    supabase
      .from("Managers")
      .select("weekly_wage")
      .eq("contracted_club", club)
      .limit(1),
  ]);

  let playerTotal = (players || []).reduce(
    (s, p) => s + (Number(p.contract_wage) || 0),
    0
  );

  let weekly = Number(mgrRows?.[0]?.weekly_wage) || 0;
  if (!weekly) {
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("manager_id")
      .eq("ShortName", club)
      .maybeSingle();
    if (clubRow?.manager_id != null) {
      const { data: m } = await supabase
        .from("Managers")
        .select("weekly_wage")
        .eq("id", clubRow.manager_id)
        .maybeSingle();
      weekly = Number(m?.weekly_wage) || 0;
    }
  }

  const manager = Math.round(weekly * 52);
  playerTotal = Math.round(playerTotal);
  return {
    players: playerTotal,
    manager,
    total: playerTotal + manager - ffSubsidy,
    fanFavourite,
    source: "fallback",
  };
}

function escapeWageHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** @param {{ players: number, manager: number, total: number, fanFavourite?: object | null }} bill */
export function wageBillSummaryHtml(bill, { linkFinances = false } = {}) {
  const p = formatMoney(bill?.players ?? 0);
  const m = formatMoney(bill?.manager ?? 0);
  const t = formatMoney(bill?.total ?? 0);
  const finLink = linkFinances
    ? ` <a href="finances.html" class="squad-wage-fin-link">Finances →</a>`
    : "";
  const ff = bill?.fanFavourite;
  const ffStat = ff
    ? `
      <div class="wage-bill-stat gpsl-has-tip" data-gpsl-tip="Central Bank pays 50% of your Fan Favourite’s wage. You are charged full wages at Close Finances, then this is credited back as a separate line." tabindex="0">
        <div class="wage-bill-label">Fan Favourite subsidy${ff.playerName ? ` (${escapeWageHtml(ff.playerName)})` : ""}</div>
        <div class="wage-bill-value">−${formatMoney(ff.subsidy)}</div>
      </div>`
    : "";
  const totalTip = ff
    ? "Player wages + manager salary, minus the Fan Favourite subsidy. Plan signings against this — wages hit the books at Close Finances."
    : "Player wages + manager salary. Plan signings against this — wages hit the books at Close Finances.";
  return `
    <div class="wage-bill-grid">
      <div class="wage-bill-stat gpsl-has-tip" data-gpsl-tip="Sum of contracted player wages for the season (full wages, before any Fan Favourite subsidy). Posted when finances are closed for the GPSL month / season step." tabindex="0">
        <div class="wage-bill-label">Player wages (season)</div>
        <div class="wage-bill-value">${p}</div>
      </div>${ffStat}
      <div class="wage-bill-stat gpsl-has-tip" data-gpsl-tip="Your manager’s seasonal salary (weekly wage × 52). Included in the total wage bill on Finances." tabindex="0">
        <div class="wage-bill-label">Manager salary (season)</div>
        <div class="wage-bill-value">${m}</div>
      </div>
      <div class="wage-bill-stat wage-bill-stat--total gpsl-has-tip" data-gpsl-tip="${totalTip}" tabindex="0">
        <div class="wage-bill-label">${ff ? "Net wage bill" : "Total wage bill"}</div>
        <div class="wage-bill-value">${t}</div>
      </div>
    </div>
    <p class="wage-bill-note gpsl-has-tip" data-gpsl-tip="Estimated seasonal wage bill for Close Finances — player contract wages plus manager salary (weekly × 52)." tabindex="0">Seasonal amounts posted at Close Finances (player contract wages + manager weekly × 52${ff ? "; Fan Favourite 50% credited back by the Central Bank" : ""}).${finLink}</p>
  `;
}
