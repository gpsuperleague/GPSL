/**
 * Season loans — August minimum squad fill-ins (HG, ≤72 rating).
 */

export const MIN_SQUAD_SIZE = 24;
export const SQUAD_MINIMUM_FINE = 5_000_000;
export const SQUAD_MINIMUM_LOAN_FEE = 5_000_000;
export const TERMINATE_SEASON_LOAN_ACTION = "terminate-season-loan";

export function seasonLoanTerminateOptionLabel(canTerminate) {
  if (!canTerminate) {
    return "Terminate season loan (squad must be above 24)";
  }
  return "Terminate season loan (50% fee refund)";
}

export function seasonLoanTerminateOptionHtml(canTerminate) {
  const label = seasonLoanTerminateOptionLabel(canTerminate);
  if (!canTerminate) {
    return `<option value="" disabled>${label}</option>`;
  }
  return `<option value="${TERMINATE_SEASON_LOAN_ACTION}">${label}</option>`;
}

export function seasonLoanBadgeHtml() {
  return '<span class="squad-loan-badge" title="Drawn home-grown loan (August minimum squad)">Season loan</span>';
}

/** @param {import("@supabase/supabase-js").SupabaseClient} supabase */
export async function loadClubSquadMinimumStatus(supabase, clubShort) {
  if (!clubShort) return null;
  const { data, error } = await supabase.rpc("club_squad_minimum_status", {
    p_club_short_name: clubShort,
  });
  if (error) {
    console.warn("club_squad_minimum_status:", error);
    return null;
  }
  return data;
}

/** @returns {Promise<Set<string>>} */
export async function loadActiveSeasonLoanPlayerIds(supabase, clubShort) {
  if (!clubShort) return new Set();
  const { data, error } = await supabase
    .from("club_season_loans")
    .select("player_id")
    .eq("club_short_name", clubShort)
    .eq("status", "active");
  if (error) {
    console.warn("club_season_loans:", error);
    return new Set();
  }
  return new Set((data || []).map((row) => String(row.player_id)));
}

export async function terminateSeasonLoan(supabase, playerId) {
  return supabase.rpc("player_terminate_season_loan", {
    p_player_id: String(playerId),
  });
}
