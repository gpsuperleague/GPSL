/**
 * Seasonal wage bill for a club (players + manager).
 * Primary: competition_club_upkeep_preview RPC.
 * Fallback: sum Players.contract_wage + Managers.weekly_wage × 52.
 */

import { formatMoney } from "./competition.js";

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @returns {Promise<{ players: number, manager: number, total: number, source: string }>}
 */
export async function loadClubWageBillSummary(supabase, clubShortName) {
  const club = String(clubShortName || "").trim();
  if (!club) {
    return { players: 0, manager: 0, total: 0, source: "none" };
  }

  const { data, error } = await supabase.rpc("competition_club_upkeep_preview", {
    p_club_short_name: club,
  });

  if (!error && data) {
    const players = Number(data.player_wage_bill ?? data.wage_bill ?? 0) || 0;
    const manager = Number(data.manager_salary ?? 0) || 0;
    const total =
      Number(data.total_wage_bill) ||
      Math.round(players + manager);
    return { players, manager, total, source: "rpc" };
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
    total: playerTotal + manager,
    source: "fallback",
  };
}

/** @param {{ players: number, manager: number, total: number }} bill */
export function wageBillSummaryHtml(bill, { linkFinances = false } = {}) {
  const p = formatMoney(bill?.players ?? 0);
  const m = formatMoney(bill?.manager ?? 0);
  const t = formatMoney(bill?.total ?? 0);
  const finLink = linkFinances
    ? ` <a href="finances.html" class="squad-wage-fin-link">Finances →</a>`
    : "";
  return `
    <div class="wage-bill-grid">
      <div class="wage-bill-stat gpsl-has-tip" data-gpsl-tip="Sum of contracted player wages for the season. Posted when finances are closed for the GPSL month / season step." tabindex="0">
        <div class="wage-bill-label">Player wages (season)</div>
        <div class="wage-bill-value">${p}</div>
      </div>
      <div class="wage-bill-stat gpsl-has-tip" data-gpsl-tip="Your manager’s seasonal salary (weekly wage × 52). Included in the total wage bill on Finances." tabindex="0">
        <div class="wage-bill-label">Manager salary (season)</div>
        <div class="wage-bill-value">${m}</div>
      </div>
      <div class="wage-bill-stat wage-bill-stat--total gpsl-has-tip" data-gpsl-tip="Player wages + manager salary. Plan signings against this — wages hit the books at Close Finances." tabindex="0">
        <div class="wage-bill-label">Total wage bill</div>
        <div class="wage-bill-value">${t}</div>
      </div>
    </div>
    <p class="wage-bill-note gpsl-has-tip" data-gpsl-tip="Estimated seasonal wage bill for Close Finances — player contract wages plus manager salary (weekly × 52)." tabindex="0">Seasonal amounts posted at Close Finances (player contract wages + manager weekly × 52).${finLink}</p>
  `;
}
