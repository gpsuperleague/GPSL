import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  document.getElementById("closeFinancesBtn").onclick = closeFinances;
  document.getElementById("postWageBillsBtn").onclick = postSeasonWageBills;
});

async function loadCurrentSeasonId() {
  const { data } = await supabase
    .from("competition_seasons")
    .select("id")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  currentSeasonId = data?.id ?? null;
}

async function postSeasonWageBills() {
  setStatus("wageBillsStatus", "Posting wage bills…");
  const { data, error } = await supabase.rpc("competition_admin_post_season_wage_bills", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("wageBillsStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "wageBillsStatus",
    `✅ Posted ${data?.charge_lines ?? 0} wage line(s) for ${data?.clubs_charged ?? 0} club(s). Skips already posted.`,
    true
  );
}

async function closeFinances() {
  if (
    !confirm(
      "Close Finances for the current season?\n\n" +
        "This posts wage bills, stadium maintenance, debt interest, " +
        "FFP (₿50M + MV player releases until above −₿99,999,999 + next-window buy embargo), " +
        "and 0.5% interest on positive balances.\n\n" +
        "Already-posted lines are skipped."
    )
  ) {
    return;
  }

  setStatus("wageBillsStatus", "Closing finances…");
  const { data, error } = await supabase.rpc("competition_admin_close_finances", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus(
      "wageBillsStatus",
      "❌ " +
        error.message +
        " — run supabase/sql/patches/ffp_50m_mv_release_embargo.sql (and stadium/maintenance patches) in Supabase.",
      false
    );
    return;
  }

  const wages = data?.wages || {};
  setStatus(
    "wageBillsStatus",
    `✅ Close Finances complete (season ${data?.season_id ?? "—"}). ` +
      `Wages: ${wages.charge_lines ?? 0} line(s) / ${wages.clubs_charged ?? 0} club(s). ` +
      `Maintenance: ${data?.infra_maintenance_clubs ?? 0}. ` +
      `Debt interest: ${data?.debt_interest_clubs ?? 0}. ` +
      `FFP: ${data?.ffp_clubs ?? 0}. ` +
      `Balance interest: ${data?.balance_interest_clubs ?? 0}.`,
    true
  );
}
