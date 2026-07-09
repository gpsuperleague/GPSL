import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadSelectionWindow,
  loadOwnerDraftOrder,
  refreshNationPlayerPoolCache,
} from "./international.js";

primeAdminPageChrome();

function hideTopSeeds() {
  const el = document.getElementById("topSeedsPreview");
  if (!el) return;
  el.style.display = "none";
  el.innerHTML = "";
}

function showTopSeeds(rows) {
  const el = document.getElementById("topSeedsPreview");
  if (!el) return;
  if (!Array.isArray(rows) || !rows.length) {
    hideTopSeeds();
    return;
  }
  const items = rows
    .map(
      (r) =>
        `<li>#${r.seed_rank} ${r.code} — ${r.name}` +
        (r.strength != null ? ` <span style="color:#888">(score ${Number(r.strength).toFixed(1)})</span>` : "") +
        `</li>`
    )
    .join("");
  el.innerHTML = `<b>Top seeds</b><ol>${items}</ol>`;
  el.style.display = "block";
}

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

  function rpcMissingHint(msg) {
    return /could not find|does not exist|PGRST202/i.test(msg || "")
      ? " — re-run supabase/sql/patches/international_refresh_selectable_and_seed_ranks.sql in Supabase."
      : /timeout|cancel|57014|statement timeout|upstream timeout/i.test(msg || "")
        ? " — timed out. Run the matching SELECT alone in the SQL Editor."
        : "";
  }

  document.getElementById("importLabelsBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Step 1 — Import missing GPDB nationality labels into international_nations?\n\nDoes not rebuild the pool cache."
      )
    ) {
      return;
    }
    setStatus("setupStatus", "Importing GPDB nation labels…");
    hideTopSeeds();
    try {
      const { data, error } = await supabase.rpc("international_sync_gpdb_nation_labels", {
        p_limit: 25,
      });
      if (error) {
        setStatus("setupStatus", `❌ ${error.message}${rpcMissingHint(error.message)}`, false);
        return;
      }
      const inserted = data?.inserted ?? 0;
      setStatus(
        "setupStatus",
        inserted > 0
          ? `✅ Step 1 batch — imported ${inserted}. Run again until it says no missing labels, then Refresh pool cache.`
          : `✅ Step 1 done — no missing labels left. Next: Refresh pool cache.`,
        true
      );
    } catch (err) {
      setStatus(
        "setupStatus",
        `❌ ${err?.message || err}. SQL Editor: SELECT public.international_sync_gpdb_nation_labels();`,
        false
      );
    }
  });

  document.getElementById("refreshPoolCacheBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Step 2 — Rebuild nation player pool cache from GPDB?\n\nSlowest step (~30–90s). Required after importing labels or a big GPDB update."
      )
    ) {
      return;
    }
    setStatus("setupStatus", "Refreshing nation pool cache… (may take up to 2 min)");
    hideTopSeeds();
    try {
      const data = await refreshNationPlayerPoolCache(supabase);
      const n = data?.nations_cached ?? "?";
      const at = data?.refreshed_at
        ? new Date(data.refreshed_at).toLocaleString()
        : "now";
      setStatus(
        "setupStatus",
        `✅ Step 2 done — pool cache refreshed (${n} nations) at ${at}. Next: Apply selectable.`,
        true
      );
    } catch (err) {
      setStatus(
        "setupStatus",
        `❌ ${err.message}${rpcMissingHint(err.message)}. SQL Editor: SELECT public.international_refresh_nation_player_pool_cache();`,
        false
      );
    }
  });

  document.getElementById("syncGpdbNationsBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Step 3 — Apply selectable flags from the existing pool cache?\n\nActivates nations that can form a 23-man squad (+ club depth). Thin nations are deactivated (assigned nations stay active).\n\nFast — requires step 2 cache to exist."
      )
    ) {
      return;
    }
    setStatus("setupStatus", "Applying selectable from pool cache…");
    hideTopSeeds();
    try {
      const { data, error } = await supabase.rpc(
        "international_apply_selectable_from_pool_cache"
      );
      if (error) {
        setStatus("setupStatus", `❌ ${error.message}${rpcMissingHint(error.message)}`, false);
        console.error("international_apply_selectable_from_pool_cache:", error);
        return;
      }
      const active = data?.active_nations ?? "?";
      const inactive = data?.inactive_nations ?? "?";
      setStatus(
        "setupStatus",
        `✅ Step 3 done — ${active} active / ${inactive} inactive` +
          ` (activated ${data?.activated ?? 0}, deactivated ${data?.deactivated ?? 0}).` +
          ` Next: Recompute seed ranks.`,
        true
      );
    } catch (err) {
      setStatus(
        "setupStatus",
        `❌ ${err?.message || err}. SQL Editor: SELECT public.international_apply_selectable_from_pool_cache();`,
        false
      );
      console.error(err);
    }
  });

  document.getElementById("seedNationsBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Step 4 — Recompute nation seed ranks from the player pool?\n\nActive nations ordered by rating-band strength. Seed 1 = strongest (qualifying pots).\nDoes not change owner draft pick order."
      )
    ) {
      return;
    }
    setStatus("setupStatus", "Recomputing seed ranks from pool…");
    hideTopSeeds();
    try {
      const { data, error } = await supabase.rpc(
        "international_recompute_seed_ranks_from_pool"
      );
      if (error) {
        setStatus("setupStatus", `❌ ${error.message}${rpcMissingHint(error.message)}`, false);
        return;
      }
      const ranked = data?.active_ranked ?? 0;
      setStatus(
        "setupStatus",
        `✅ Step 4 done — seed ranks updated for ${ranked} active nation(s)`,
        true
      );
      showTopSeeds(data?.top_nations || []);
    } catch (err) {
      setStatus(
        "setupStatus",
        `❌ ${err?.message || err}. SQL Editor: SELECT public.international_recompute_seed_ranks_from_pool();`,
        false
      );
    }
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
