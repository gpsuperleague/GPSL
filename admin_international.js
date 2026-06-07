import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("seedNationsBtn")?.addEventListener("click", async () => {
    setStatus("setupStatus", "Seeding…");
    const { data, error } = await supabase.rpc("international_seed_nations");
    setStatus(
      "setupStatus",
      error ? `❌ ${error.message}` : `✅ Seeded/updated nations (${data})`,
      !error
    );
  });

  document.getElementById("syncRanksBtn")?.addEventListener("click", async () => {
    setStatus("setupStatus", "Syncing…");
    const { data, error } = await supabase.rpc("international_sync_owner_ranks");
    setStatus(
      "setupStatus",
      error ? `❌ ${error.message}` : `✅ Added ${data} owner rank rows`,
      !error
    );
  });

  document.getElementById("setRankBtn")?.addEventListener("click", async () => {
    const club = document.getElementById("rankClub")?.value?.trim();
    const pts = Number(document.getElementById("rankPoints")?.value);
    if (!club) {
      setStatus("rankStatus", "Enter club ShortName.", false);
      return;
    }
    setStatus("rankStatus", "Saving…");
    const { error } = await supabase.rpc("international_admin_set_rank_points", {
      p_club: club,
      p_points: pts,
    });
    setStatus(
      "rankStatus",
      error ? `❌ ${error.message}` : `✅ Rank points saved for ${club}`,
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
  document.getElementById("openPostWcBtn")?.addEventListener("click", () =>
    openSelection("post_world_cup")
  );
  document.getElementById("closeSelectionBtn")?.addEventListener("click", closeSelection);
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
}

async function closeSelection() {
  setStatus("selectionStatus", "Closing…");
  const { error } = await supabase.rpc("international_admin_close_selection");
  setStatus("selectionStatus", error ? `❌ ${error.message}` : "✅ Selection closed", !error);
}
