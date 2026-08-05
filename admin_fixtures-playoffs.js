import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadCurrentSeason } from "./competition.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("compSavePlayoffBtn").onclick = saveCompetitionPlayoffQualifier;
  const syncSbBtn = document.getElementById("compSyncSbQualBtn");
  if (syncSbBtn) syncSbBtn.onclick = fixShieldBowlQualifiers;
  const rebuildSbBtn = document.getElementById("compRebuildSbBtn");
  if (rebuildSbBtn) rebuildSbBtn.onclick = rebuildChSbFromTable;
  document.getElementById("genPlayoffsBtn").onclick = () =>
    runGen(false).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  document.getElementById("forcePlayoffsBtn").onclick = () => {
    if (!confirm("Delete existing playoff ties/fixtures and regenerate?")) return;
    runGen(true).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  };
  document.getElementById("applyMovementsBtn").onclick = () =>
    runApply().catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
});

async function rebuildChSbFromTable() {
  if (
    !confirm(
      "Rebuild Championship Shield/Bowl ties from the FINAL table (16th vs 17th)?\n\n" +
        "This deletes the wrong mid-table “16v17” fixtures/results and creates the correct ties " +
        "(e.g. Marseille vs Man City / Atletico Nacional vs Celtic).\n\n" +
        "You must then PLAY those two matches before writing Shield qualifiers."
    )
  ) {
    return;
  }

  setStatus("compSyncSbQualStatus", "Rebuilding 16v17 ties from final table…");
  const { data, error } = await supabase.rpc(
    "competition_admin_rebuild_ch_sb_ties_from_table",
    { p_season_id: null }
  );

  if (error?.message?.includes("competition_admin_rebuild_ch_sb_ties_from_table")) {
    setStatus(
      "compSyncSbQualStatus",
      "❌ Run patches/shield_bowl_rebuild_16v17_from_table.sql in Supabase, then retry.",
      false
    );
    return;
  }
  if (error) {
    setStatus("compSyncSbQualStatus", "❌ " + error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus(
      "compSyncSbQualStatus",
      `❌ ${data?.reason || "Rebuild failed"} ${data?.hint || ""}`,
      false
    );
    return;
  }

  const ties = Array.isArray(data.ties) ? data.ties : [];
  const line = ties
    .map((t) => `${t.division}: ${t.home_16} vs ${t.away_17}`)
    .join(" | ");
  setStatus(
    "compSyncSbQualStatus",
    `✅ Rebuilt. ${line}. ${data.message || "Play those fixtures next."}`,
    true
  );
}

/**
 * After correct 16v17 results exist: rewrite Shield/Bowl qualifier rows.
 */
async function fixShieldBowlQualifiers() {
  setStatus(
    "compSyncSbQualStatus",
    "Looking up Championship 16th vs 17th results and fixing Shield/Bowl qualifiers…"
  );

  let { data, error } = await supabase.rpc(
    "competition_admin_fix_shield_bowl_qualifiers"
  );

  // Fallback if newer one-click RPC not deployed yet
  if (error?.message?.includes("competition_admin_fix_shield_bowl_qualifiers")) {
    ({ data, error } = await supabase.rpc(
      "competition_sync_shield_bowl_qualifiers_from_playoffs",
      { p_season_id: null }
    ));
    if (error?.message?.includes("competition_sync_shield_bowl_qualifiers_from_playoffs")) {
      setStatus(
        "compSyncSbQualStatus",
        "❌ Run patches/shield_bowl_playoff_qualifier_fix.sql in Supabase SQL Editor, then click again.",
        false
      );
      return;
    }
    if (error) {
      setStatus("compSyncSbQualStatus", "❌ " + error.message, false);
      return;
    }
    setStatus(
      "compSyncSbQualStatus",
      data?.ok
        ? `✅ Synced ${data.rows_upserted ?? 0} row(s). Re-run the full patch for named winners, then open Cups → Shield.`
        : `❌ ${data?.reason || "Failed"}`,
      !!data?.ok
    );
    return;
  }

  if (error) {
    setStatus("compSyncSbQualStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.ok && data?.reason === "no_ch_sb_ties") {
    setStatus("compSyncSbQualStatus", `❌ ${data.message}`, false);
    return;
  }

  const lines = Array.isArray(data?.summary_lines) ? data.summary_lines : [];
  const header = data?.season_label
    ? `Season: ${data.season_label}`
    : `Season id: ${data?.season_id ?? "?"}`;
  const body = lines.length ? lines.join(" | ") : "No 16v17 ties found.";
  const next = data?.message || "";

  setStatus(
    "compSyncSbQualStatus",
    `${data?.ok ? "✅" : "⚠"} ${header}. ${body} ${next}`,
    !!data?.ok
  );
}

async function runGen(force) {
  setStatus("genPlayoffStatus", force ? "Force regenerating…" : "Generating…");
  const { data, error } = await supabase.rpc("admin_competition_generate_playoffs", {
    p_season_id: null,
    p_force: !!force,
  });
  if (error) {
    setStatus(
      "genPlayoffStatus",
      error.message.includes("admin_competition_generate_playoffs")
        ? "❌ Run competition_phase7_playoffs.sql (+ gpsl_playoffs_week_calendar.sql) first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  if (!data?.ok) {
    if (data?.reason === "missing_standings_16_17") {
      const missing = Array.isArray(data.missing) ? data.missing.join(", ") : "";
      setStatus(
        "genPlayoffStatus",
        `❌ Missing 16th/17th standings (${missing}). Shield/Bowl playoffs need those places filled first.`,
        false
      );
      return;
    }
    setStatus("genPlayoffStatus", data?.reason || data?.error || "Failed", false);
    return;
  }
  setStatus(
    "genPlayoffStatus",
    data.already
      ? `✅ Already generated · scheduled ${data.scheduled_now ?? 0} ready fixture(s).`
      : `✅ Created ${data.ties_created ?? 0} ties, scheduled ${data.fixtures_scheduled ?? 0} fixtures.`
  );
}

async function runApply() {
  setStatus("genPlayoffStatus", "Applying movements…");
  const { data, error } = await supabase.rpc("admin_competition_apply_playoff_movements", {
    p_season_id: null,
  });
  if (error) {
    setStatus("genPlayoffStatus", "❌ " + error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus(
      "genPlayoffStatus",
      data?.reason === "sl_final_not_played"
        ? "❌ SuperLeague playoff final not played yet."
        : "❌ " + (data?.reason || "Failed"),
      false
    );
    return;
  }
  setStatus("genPlayoffStatus", `✅ Recorded ${data.movements ?? 0} movement(s).`);
}

async function saveCompetitionPlayoffQualifier() {
  const active = await loadCurrentSeason(supabase);
  if (!active?.id) {
    setStatus("compPlayoffStatus", "No active season.", false);
    return;
  }

  const cup =
    document.getElementById("compPlayoffRole").value === "shield_playoff_winner"
      ? "shield"
      : "bowl";

  const { error } = await supabase.rpc("competition_admin_set_playoff_qualifier", {
    p_season_id: active.id,
    p_cup_code: cup,
    p_division: document.getElementById("compPlayoffDiv").value,
    p_club_short_name: document.getElementById("compPlayoffClub").value.trim(),
    p_role: document.getElementById("compPlayoffRole").value,
  });

  setStatus(
    "compPlayoffStatus",
    error ? "❌ " + error.message : "✅ Playoff qualifier saved.",
    !error
  );
}
