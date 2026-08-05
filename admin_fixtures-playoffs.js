import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("genPlayoffsBtn").onclick = () =>
    runGen(false).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  document.getElementById("forcePlayoffsBtn").onclick = () => {
    if (!confirm("Delete existing playoff ties/fixtures and regenerate?")) return;
    runGen(true).catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));
  };
  document.getElementById("applyMovementsBtn").onclick = () =>
    runApply().catch((e) => setStatus("genPlayoffStatus", e.message || String(e), false));

  document.getElementById("compRebuildSbBtn").onclick = rebuildChSbFromTable;
  document.getElementById("compLoadSbOptsBtn").onclick = loadChSbOptions;
  document.getElementById("compSaveSbWinnersBtn").onclick = saveChSbWinners;
});

function fillWinnerSelect(sel, tie) {
  if (!sel || !tie) return;
  const home = tie.home;
  const away = tie.away;
  sel.innerHTML = `
    <option value="">— pick Shield winner —</option>
    <option value="${home}">${tie.home_name || home} (16th)</option>
    <option value="${away}">${tie.away_name || away} (17th)</option>
  `;
  if (tie.winner) sel.value = tie.winner;
}

async function loadChSbOptions() {
  setStatus("compSyncSbQualStatus", "Loading 16v17 pairs…");
  const { data, error } = await supabase.rpc("competition_admin_ch_sb_tie_options", {
    p_season_id: null,
  });
  if (error?.message?.includes("competition_admin_ch_sb_tie_options")) {
    setStatus(
      "compSyncSbQualStatus",
      "❌ Run patches/shield_bowl_rebuild_16v17_from_table.sql in Supabase, then retry.",
      false
    );
    return null;
  }
  if (error) {
    setStatus("compSyncSbQualStatus", "❌ " + error.message, false);
    return null;
  }
  if (!data?.ok) {
    setStatus("compSyncSbQualStatus", `❌ ${data?.reason || "Load failed"}`, false);
    return null;
  }

  const ties = Array.isArray(data.ties) ? data.ties : [];
  const a = ties.find((t) => t.division === "championship_a" || t.bracket === "ch_sb_a");
  const b = ties.find((t) => t.division === "championship_b" || t.bracket === "ch_sb_b");
  fillWinnerSelect(document.getElementById("compSbWinnerA"), a);
  fillWinnerSelect(document.getElementById("compSbWinnerB"), b);

  const line = ties
    .map((t) => `${t.division}: ${t.home_name || t.home} vs ${t.away_name || t.away}`)
    .join(" | ");
  setStatus(
    "compSyncSbQualStatus",
    `✅ Season ${data.season_id}. ${line || "No ties — rebuild first."}`,
    true
  );
  return data;
}

async function rebuildChSbFromTable() {
  if (
    !confirm(
      "Rebuild Championship Shield/Bowl ties from the FINAL Season 2 table (16th vs 17th)?\n\n" +
        "Wrong mid-table results are cleared. Correct pairs are set (e.g. Marseille vs Man City).\n\n" +
        "You will NOT play matchdays — next you pick each winner in the dropdowns."
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

  await loadChSbOptions();
  setStatus(
    "compSyncSbQualStatus",
    `✅ Rebuilt season ${data.season_id}. Pick Champ A + Champ B winners below, then Save.`,
    true
  );
}

async function saveChSbWinners() {
  const a = document.getElementById("compSbWinnerA")?.value?.trim();
  const b = document.getElementById("compSbWinnerB")?.value?.trim();
  if (!a || !b) {
    setStatus(
      "compSyncSbQualStatus",
      "Pick both Champ A and Champ B Shield winners first.",
      false
    );
    return;
  }

  if (
    !confirm(
      `Award Shield playoff winners (no matchday)?\n\n` +
        `Champ A → Shield: ${a} (other → Bowl)\n` +
        `Champ B → Shield: ${b} (other → Bowl)\n\n` +
        `Then open Cups → Shield → reload byes → re-draw.`
    )
  ) {
    return;
  }

  setStatus("compSyncSbQualStatus", "Saving winners and writing qualifiers…");

  const r1 = await supabase.rpc("competition_admin_set_ch_sb_winner", {
    p_division: "championship_a",
    p_winner_club: a,
    p_season_id: null,
  });
  if (r1.error?.message?.includes("competition_admin_set_ch_sb_winner")) {
    setStatus(
      "compSyncSbQualStatus",
      "❌ Run patches/shield_bowl_rebuild_16v17_from_table.sql in Supabase, then retry.",
      false
    );
    return;
  }
  if (r1.error) {
    setStatus("compSyncSbQualStatus", "❌ Champ A: " + r1.error.message, false);
    return;
  }

  const r2 = await supabase.rpc("competition_admin_set_ch_sb_winner", {
    p_division: "championship_b",
    p_winner_club: b,
    p_season_id: null,
  });
  if (r2.error) {
    setStatus("compSyncSbQualStatus", "❌ Champ B: " + r2.error.message, false);
    return;
  }

  const d1 = r1.data;
  const d2 = r2.data;
  setStatus(
    "compSyncSbQualStatus",
    `✅ Done. Shield: ${d1?.shield_winner_name || a} + ${d2?.shield_winner_name || b}. ` +
      `Bowl: ${d1?.bowl_loser_name || "?"} + ${d2?.bowl_loser_name || "?"}. ` +
      `Next: Admin Cups → Shield → reload byes → re-draw.`,
    true
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
        `❌ Missing 16th/17th standings (${missing}).`,
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
