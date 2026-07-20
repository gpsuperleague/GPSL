/**
 * When club assignment debited balance but infra_purchase ledger line is missing,
 * synthesize a ledger row for season accounts (first season only).
 *
 * Continuing clubs (prior finance season / prior club_seasons / prior infra)
 * must never show or invent a stadium purchase again on Season 2+.
 */

export function parseLedgerMetadata(raw) {
  if (!raw) return {};
  if (typeof raw === "object") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function isAssignmentStadiumInfraRow(row) {
  if (!row || row.entry_type !== "infra_purchase") return false;
  const md = parseLedgerMetadata(row.metadata);
  if (md.synthetic) return true;
  const src = String(md.source || "club_assignment").toLowerCase();
  // Treat unscoped infra_purchase as assignment stadium buy (historical rows)
  if (!md.source) return true;
  return src === "club_assignment" || src === "club_auction" || src === "assignment";
}

/**
 * GPSL starting budget from club-assignment infra_purchase metadata (pre-auction cash).
 * @param {Array<{ entry_type?: string, metadata?: unknown, created_at?: string }>} ledger
 * @returns {number | null}
 */
export function ledgerStartingBudget(ledger) {
  if (!Array.isArray(ledger) || !ledger.length) return null;

  const infraRows = ledger
    .filter((r) => r.entry_type === "infra_purchase")
    .sort(
      (a, b) =>
        new Date(a.created_at || 0).getTime() - new Date(b.created_at || 0).getTime()
    );

  for (const row of infraRows) {
    const md = parseLedgerMetadata(row.metadata);
    const value = Number(md.starting_budget);
    if (Number.isFinite(value) && value > 0) return value;
  }

  return null;
}

/**
 * Drop assignment stadium purchase lines for clubs that already had a prior season.
 * @param {Array<object>} ledger
 * @param {boolean} continuingClub
 */
export function stripRepeatAssignmentInfraPurchases(ledger, continuingClub) {
  if (!continuingClub || !Array.isArray(ledger)) return Array.isArray(ledger) ? [...ledger] : [];
  return ledger.filter((r) => !isAssignmentStadiumInfraRow(r));
}

/**
 * True if this club has a prior finance season (archive / prior infra / prior club_seasons).
 * Prefers security-definer RPC when available.
 */
export async function clubHadPriorFinanceSeason(supabase, clubShortName, currentSeasonId) {
  if (!clubShortName || !supabase) return false;

  try {
    const { data, error } = await supabase.rpc("club_had_prior_finance_season", {
      p_club_short_name: clubShortName,
      p_current_season_id: currentSeasonId ?? null,
    });
    if (!error && typeof data === "boolean") return data;
    if (error) console.warn("club_had_prior_finance_season rpc:", error);
  } catch (e) {
    console.warn("club_had_prior_finance_season rpc:", e);
  }

  // Fallback: archive table (pre-RPC deploy)
  let query = supabase
    .from("competition_club_finance_season_archive_public")
    .select("season_id")
    .eq("club_short_name", clubShortName)
    .order("season_id", { ascending: false })
    .limit(1);

  if (currentSeasonId) {
    query = query.lt("season_id", currentSeasonId);
  }

  const { data, error } = await query.maybeSingle();
  if (error) {
    console.warn("clubHadPriorFinanceSeason:", error);
    return false;
  }
  if (data?.season_id != null) return true;

  // Fallback: prior competition_club_seasons row
  try {
    let csQuery = supabase
      .from("competition_club_seasons")
      .select("season_id")
      .eq("club_short_name", clubShortName)
      .limit(1);
    if (currentSeasonId) {
      csQuery = csQuery.lt("season_id", currentSeasonId);
    }
    const { data: cs, error: csErr } = await csQuery.maybeSingle();
    if (!csErr && cs?.season_id != null) return true;
  } catch {
    /* view may be restricted */
  }

  return false;
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @param {Array<object>} ledger
 * @param {{ continuingClub?: boolean, currentSeasonId?: number|null }} [options]
 * @returns {Promise<Array<object>>}
 */
export async function appendAssignmentInfraPurchaseLedger(
  supabase,
  clubShortName,
  ledger,
  options = {}
) {
  let rows = Array.isArray(ledger) ? [...ledger] : [];
  let continuingClub = Boolean(options.continuingClub);

  if (!continuingClub && options.currentSeasonId) {
    continuingClub = await clubHadPriorFinanceSeason(
      supabase,
      clubShortName,
      options.currentSeasonId
    );
  }

  // Continuing clubs: never keep or invent assignment stadium buys this season
  if (continuingClub) {
    return stripRepeatAssignmentInfraPurchases(rows, true);
  }

  const hasInfra = rows.some(
    (r) => r.entry_type === "infra_purchase" && Math.abs(Number(r.amount) || 0) > 0.5
  );
  if (hasInfra) return rows;

  const { data, error } = await supabase.rpc("club_assignment_finance_display", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    console.warn("club_assignment_finance_display:", error);
    return rows;
  }

  if (data?.ledger_posted || data?.continuing_club) {
    return data?.continuing_club ? stripRepeatAssignmentInfraPurchases(rows, true) : rows;
  }
  if (!data?.show_in_accounts || Number(data.total_debit) <= 0) return rows;

  const stadiumName = String(data.stadium_name || data.club_name || "Stadium purchase").trim();
  const amount = -Math.abs(Number(data.total_debit));

  rows.push({
    entry_type: "infra_purchase",
    amount,
    description: data.ledger_description || `Stadium purchase — ${stadiumName}`,
    metadata: {
      stadium_name: stadiumName,
      source: "club_assignment",
      synthetic: true,
      starting_budget: Number(data.starting_budget) > 0 ? Number(data.starting_budget) : undefined,
    },
    club_name: data.club_name || clubShortName,
    club_short_name: clubShortName,
    created_at: data.settled_at || new Date().toISOString(),
  });

  return rows;
}
