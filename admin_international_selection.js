import { setStatus, supabase } from "./admin_common.js";
import { loadSelectionWindow, loadOwnerDraftOrder } from "./international.js";

/**
 * Shared nation-selection window controls for focused admin pages
 * (open / close / clear) and optional use on the international hub.
 */

export async function refreshSelectionLive() {
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
  const waiting =
    windowState.waiting_count ?? draft.filter((d) => !d.nation_code).length;
  const isFfa = windowState.pick_mode === "free_for_all";

  if (isFfa) {
    liveEl.innerHTML = `
      <b>Nation selection</b> is open ·
      Mode: <b>free-for-all</b> (anyone without a nation can claim)
      · ${windowState.nations_assigned || 0} assigned · ${waiting} still to pick
    `;
    if (skipBtn) skipBtn.hidden = true;
    if (skipHint) skipHint.hidden = true;
    return;
  }

  const current = draft.find((d) => d.pick_order === windowState.current_pick_rank);
  liveEl.innerHTML = `
    <b>Nation selection</b> is open ·
    Mode: <b>draft order</b> ·
    On the clock: <b>#${windowState.current_pick_rank}</b>
    ${current ? `— ${current.owner_tag || current.owner_name || "Owner"} (${current.club_name || current.club_short_name})` : ""}
    · ${windowState.nations_assigned || 0} assigned · ${waiting} still to pick
  `;

  if (skipBtn) skipBtn.hidden = waiting <= 1;
  if (skipHint) skipHint.hidden = waiting <= 1;
}

async function openSelection(phase, pickMode = "ordered") {
  const modeLabel = pickMode === "free_for_all" ? "free-for-all" : "draft order";
  setStatus("selectionStatus", `Opening (${modeLabel})…`);
  const { data, error } = await supabase.rpc("international_admin_open_selection", {
    p_phase: phase,
    p_pick_mode: pickMode,
  });
  setStatus(
    "selectionStatus",
    error ? `❌ ${error.message}` : `✅ Selection open — ${modeLabel} (window #${data})`,
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
      "Clear ALL nation assignments?\n\nEvery club loses their national team. Any open selection window will close.\n\nThen use Open Nation Selection to start a fresh draft."
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

/** Wire whichever selection controls exist on the current page. */
export function wireNationSelectionControls() {
  document.getElementById("openInitialBtn")?.addEventListener("click", async () => {
    try {
      const draft = await loadOwnerDraftOrder(supabase);
      const waiting = (draft || []).filter((d) => !d.nation_code).length;
      if (waiting === 0 && draft?.length) {
        if (
          !confirm(
            "Every club already has a national team assigned.\n\nOpening selection will create a window then close it immediately (nothing left to pick).\n\nContinue anyway?"
          )
        ) {
          return;
        }
      }
    } catch (_) {
      /* ignore */
    }
    openSelection("initial", "ordered");
  });

  document.getElementById("openFfaBtn")?.addEventListener("click", async () => {
    try {
      const draft = await loadOwnerDraftOrder(supabase);
      const waiting = (draft || []).filter((d) => !d.nation_code).length;
      if (waiting === 0 && draft?.length) {
        setStatus(
          "selectionStatus",
          "Everyone already has a nation — nothing for free-for-all to do.",
          false
        );
        return;
      }
      if (
        !confirm(
          `Open free-for-all nation selection?\n\n${waiting} club(s) without a nation can claim immediately (no pick order).\n\nAny currently open draft window will close first.`
        )
      ) {
        return;
      }
    } catch (_) {
      /* ignore */
    }
    openSelection("initial", "free_for_all");
  });

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
}
