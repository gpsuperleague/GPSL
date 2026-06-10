import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadSelectionWindow,
  loadOwnerDraftOrder,
} from "./international.js";

primeAdminPageChrome();

async function refreshSelectionLive() {
  const liveEl = document.getElementById("selectionLive");
  const skipBtn = document.getElementById("skipCurrentPickBtn");
  const skipHint = document.getElementById("skipPickHint");
  if (!liveEl) return;

  const windowState = await loadSelectionWindow(supabase);
  if (!windowState?.is_open) {
    liveEl.textContent = "Nation selection is closed.";
    if (skipBtn) skipBtn.hidden = true;
    if (skipHint) skipHint.hidden = true;
    return;
  }

  const draft = await loadOwnerDraftOrder(supabase);
  const current = draft.find((d) => d.pick_order === windowState.current_pick_rank);
  const waiting = draft.filter((d) => !d.nation_code).length;
  liveEl.innerHTML = `
    <b>Nation selection</b> is open ·
    On the clock: <b>#${windowState.current_pick_rank}</b>
    ${current ? `— ${current.owner_tag || current.owner_name || "Owner"} (${current.club_name || current.club_short_name})` : ""}
    · ${windowState.nations_assigned || 0} assigned · ${waiting} still to pick
  `;

  if (skipBtn) skipBtn.hidden = waiting <= 1;
  if (skipHint) skipHint.hidden = waiting <= 1;
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await refreshSelectionLive();

  document.getElementById("seedNationsBtn")?.addEventListener("click", async () => {
    setStatus("setupStatus", "Seeding…");
    const { data, error } = await supabase.rpc("international_seed_nations");
    setStatus(
      "setupStatus",
      error ? `❌ ${error.message}` : `✅ Seeded/updated nations (${data})`,
      !error
    );
  });

  document.getElementById("recomputeRanksBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Recompute owner ranking points for all archived seasons?\n\nSafe to re-run after competition_owner_ranking.sql changes."
      )
    ) {
      return;
    }
    setStatus("rankStatus", "Recomputing…");
    const { data, error } = await supabase.rpc("competition_owner_ranking_recompute_all");
    setStatus(
      "rankStatus",
      error
        ? `❌ ${error.message}`
        : `✅ Recomputed ${data ?? 0} club-season rows`,
      !error
    );
  });

  document.getElementById("assignBtn")?.addEventListener("click", async () => {
    const club = document.getElementById("assignClub")?.value?.trim();
    const nation = document.getElementById("assignNation")?.value?.trim().toUpperCase();
    if (!club || !nation) {
      setStatus("assignStatus", "Enter club and nation code.", false);
      return;
    }
    setStatus("assignStatus", "Assigning…");
    const { error } = await supabase.rpc("international_admin_assign_nation", {
      p_club: club,
      p_nation_code: nation,
    });
    setStatus(
      "assignStatus",
      error ? `❌ ${error.message}` : `✅ ${nation} → ${club}`,
      !error
    );
  });

  document.getElementById("openInitialBtn")?.addEventListener("click", () =>
    openSelection("initial")
  );
  document.getElementById("clearAssignmentsBtn")?.addEventListener("click", clearAssignments);
  document.getElementById("closeSelectionBtn")?.addEventListener("click", closeSelection);

  document.getElementById("skipCurrentPickBtn")?.addEventListener("click", async () => {
    const liveEl = document.getElementById("selectionLive");
    const onClock = liveEl?.textContent || "";
    if (
      !confirm(
        `Skip the current nation picker?\n\n${onClock}\n\nThe next owner without a nation will be on the clock.`
      )
    ) {
      return;
    }
    setStatus("selectionStatus", "Skipping…");
    const { data, error } = await supabase.rpc("international_admin_skip_current_pick");
    if (error) {
      setStatus("selectionStatus", `❌ ${error.message}`, false);
      return;
    }
    const skipped = data?.skipped_club_name || data?.skipped_club || "owner";
    const next = data?.next_pick;
    setStatus(
      "selectionStatus",
      `✅ Skipped ${skipped} (pick #${data?.skipped_pick}) → now on pick #${next}`,
      true
    );
    await refreshSelectionLive();
  });
});

async function openSelection(phase) {
  setStatus("selectionStatus", "Opening…");
  const { data, error } = await supabase.rpc("international_admin_open_selection", {
    p_phase: phase,
  });
  setStatus(
    "selectionStatus",
    error ? `❌ ${error.message}` : `✅ Selection open (window #${data})`,
    !error
  );
  if (!error) await refreshSelectionLive();
}

async function closeSelection() {
  setStatus("selectionStatus", "Closing…");
  const { error } = await supabase.rpc("international_admin_close_selection");
  setStatus("selectionStatus", error ? `❌ ${error.message}` : "✅ Selection closed", !error);
  if (!error) await refreshSelectionLive();
}

async function clearAssignments() {
  if (
    !confirm(
      "Clear ALL nation assignments?\n\nEvery club loses their national team. Any open selection window will close.\n\nThen use Open selection to start a fresh draft."
    )
  ) {
    return;
  }
  setStatus("selectionStatus", "Clearing…");
  const { data, error } = await supabase.rpc("international_admin_clear_nation_assignments");
  setStatus(
    "selectionStatus",
    error ? `❌ ${error.message}` : `✅ Cleared ${data ?? 0} nation assignment(s)`,
    !error
  );
  if (!error) await refreshSelectionLive();
}
