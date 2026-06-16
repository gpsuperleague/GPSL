/**
 * When club assignment debited balance but infra_purchase ledger line is missing,
 * synthesize a ledger row for season accounts (until repair_club_assignment_ledger_only runs).
 */

function parseMetadata(raw) {
  if (!raw) return {};
  if (typeof raw === "object") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @param {Array<object>} ledger
 * @returns {Promise<Array<object>>}
 */
export async function appendAssignmentInfraPurchaseLedger(supabase, clubShortName, ledger) {
  const rows = Array.isArray(ledger) ? [...ledger] : [];
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

  if (!data?.show_in_accounts || Number(data.total_debit) <= 0) {
    return rows;
  }

  if (data.ledger_posted) {
    return rows;
  }

  const stadiumName = String(data.stadium_name || data.club_name || "Stadium purchase").trim();
  const amount = -Math.abs(Number(data.total_debit));

  rows.push({
    entry_type: "infra_purchase",
    amount,
    description:
      data.ledger_description || `Stadium purchase — ${stadiumName}`,
    metadata: {
      stadium_name: stadiumName,
      source: "club_assignment",
      synthetic: true,
    },
    club_name: data.club_name || clubShortName,
    club_short_name: clubShortName,
    created_at: data.settled_at || new Date().toISOString(),
  });

  return rows;
}
