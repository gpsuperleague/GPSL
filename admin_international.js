import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  loadSelectionWindow,
  loadOwnerDraftOrder,
  loadInternationalNations,
  refreshNationPlayerPoolCache,
} from "./international.js";

primeAdminPageChrome();

/** @type {Map<string, string>} owner_id → email */
let ownerEmailById = new Map();

function escapeOpt(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadOwnerEmails() {
  ownerEmailById = new Map();
  try {
    const { data, error } = await supabase.functions.invoke("list-owners");
    if (error) {
      console.warn("list-owners:", error);
      return;
    }
    for (const u of data?.users || []) {
      if (u?.id && u?.email) ownerEmailById.set(u.id, u.email);
    }
  } catch (err) {
    console.warn("list-owners skipped:", err);
  }
}

function clubAssignLabel(row) {
  const club = row.club_name || row.club_short_name || "?";
  const short = row.club_short_name || "";
  const tag = row.owner_tag || row.owner_name || "";
  const email = row.owner_id ? ownerEmailById.get(row.owner_id) : null;
  const who = [tag, email].filter(Boolean).join(" · ") || "No owner tag";
  const taken = row.nation_code
    ? ` — already ${row.nation_code}${row.nation_name ? ` (${row.nation_name})` : ""}`
    : "";
  return `${club} [${short}] — ${who}${taken}`;
}

function nationAssignLabel(row) {
  const rank = row.seed_rank != null ? `#${row.seed_rank}` : "#—";
  const flag = row.flag_emoji ? `${row.flag_emoji} ` : "";
  const taken = row.is_taken
    ? ` — taken${row.owner_club_name || row.owner_club ? ` by ${row.owner_club_name || row.owner_club}` : ""}`
    : "";
  return `${rank} ${flag}${row.code} — ${row.name || row.code}${taken}`;
}

async function refreshAssignDropdowns() {
  const clubSel = document.getElementById("assignClubSelect");
  const nationSel = document.getElementById("assignNationSelect");
  if (!clubSel || !nationSel) return;

  const prevClub = clubSel.value;
  const prevNation = nationSel.value;

  clubSel.innerHTML = `<option value="">Loading clubs…</option>`;
  nationSel.innerHTML = `<option value="">Loading nations…</option>`;

  const [draft, nations] = await Promise.all([
    loadOwnerDraftOrder(supabase),
    loadInternationalNations(supabase),
  ]);

  const clubs = (draft || []).filter((d) => d.club_short_name);
  clubs.sort((a, b) => {
    const aTaken = a.nation_code ? 1 : 0;
    const bTaken = b.nation_code ? 1 : 0;
    if (aTaken !== bTaken) return aTaken - bTaken;
    return String(a.club_name || a.club_short_name).localeCompare(
      String(b.club_name || b.club_short_name)
    );
  });

  const clubOpts = [`<option value="">Select owner / club…</option>`];
  for (const row of clubs) {
    const taken = !!row.nation_code;
    clubOpts.push(
      `<option value="${escapeOpt(row.club_short_name)}"${taken ? " disabled" : ""}${
        !taken && prevClub === row.club_short_name ? " selected" : ""
      }>${escapeOpt(clubAssignLabel(row))}</option>`
    );
  }
  clubSel.innerHTML = clubOpts.join("");
  if (!clubs.length) {
    clubSel.innerHTML = `<option value="">No owned clubs found</option>`;
  }

  const nationRows = (nations || []).slice().sort((a, b) => {
    const ar = Number(a.seed_rank) || 9999;
    const br = Number(b.seed_rank) || 9999;
    if (ar !== br) return ar - br;
    return String(a.code).localeCompare(String(b.code));
  });

  const nationOpts = [`<option value="">Select nation…</option>`];
  for (const row of nationRows) {
    const taken = !!row.is_taken;
    nationOpts.push(
      `<option value="${escapeOpt(row.code)}"${taken ? " disabled" : ""}${
        !taken && prevNation === row.code ? " selected" : ""
      }>${escapeOpt(nationAssignLabel(row))}</option>`
    );
  }
  nationSel.innerHTML = nationOpts.join("");
  if (!nationRows.length) {
    nationSel.innerHTML = `<option value="">No active nations — run Apply selectable first</option>`;
  }
}

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
        (r.avg_rating != null
          ? ` <span style="color:#888">(top ${r.players_used ?? 100} avg ${Number(r.avg_rating).toFixed(2)})</span>`
          : r.strength != null
            ? ` <span style="color:#888">(score ${Number(r.strength).toFixed(1)})</span>`
            : "") +
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
  await loadOwnerEmails();
  await refreshAssignDropdowns();

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
        "Step 3 — Apply selectable flags from the existing pool cache?\n\nActivates nations with ≥24 GPDB players and ≥2 GKs (enough for a 23-man squad). Thin nations are deactivated (assigned nations stay active).\n\nFast — requires step 2 cache to exist."
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
        "Step 4 — Recompute nation seed ranks?\n\nActive nations ordered by average rating of their highest-rated 100 GPDB players (fewer than 100 → average of all).\nSeed 1 = strongest (qualifying pots).\nDoes not change owner draft pick order."
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

  document.getElementById("refreshAssignListsBtn")?.addEventListener("click", async () => {
    setStatus("assignStatus", "Refreshing lists…");
    await loadOwnerEmails();
    await refreshAssignDropdowns();
    setStatus("assignStatus", "✅ Lists refreshed", true);
  });

  document.getElementById("assignBtn")?.addEventListener("click", async () => {
    const clubSel = document.getElementById("assignClubSelect");
    const nationSel = document.getElementById("assignNationSelect");
    const club = clubSel?.value?.trim();
    const nation = nationSel?.value?.trim().toUpperCase();
    if (!club) {
      setStatus("assignStatus", "Select an owner / club.", false);
      return;
    }
    if (!nation) {
      setStatus("assignStatus", "Select a nation.", false);
      return;
    }
    const clubLabel = clubSel.selectedOptions[0]?.textContent || club;
    const nationLabel = nationSel.selectedOptions[0]?.textContent || nation;
    if (!confirm(`Assign national team?\n\n${nationLabel}\n→\n${clubLabel}`)) {
      return;
    }
    setStatus("assignStatus", "Assigning…");
    const { error } = await supabase.rpc("international_admin_assign_nation", {
      p_club: club,
      p_nation_code: nation,
    });
    if (error) {
      setStatus("assignStatus", `❌ ${error.message}`, false);
      return;
    }
    setStatus("assignStatus", `✅ ${nation} → ${club}`, true);
    await refreshAssignDropdowns();
    await refreshSelectionLive();
  });

  document.getElementById("openInitialBtn")?.addEventListener("click", async () => {
    // Soft warning if everyone already has a nation
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
    openSelection("initial");
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
  if (!error) {
    await refreshSelectionLive();
    await refreshAssignDropdowns();
  }
}

async function closeSelection() {
  setStatus("selectionStatus", "Closing…");
  const { error } = await supabase.rpc("international_admin_close_selection");
  setStatus("selectionStatus", error ? `❌ ${error.message}` : "✅ Selection closed", !error);
  if (!error) {
    await refreshSelectionLive();
    await refreshAssignDropdowns();
  }
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
  if (!error) {
    await refreshSelectionLive();
    await refreshAssignDropdowns();
  }
}
