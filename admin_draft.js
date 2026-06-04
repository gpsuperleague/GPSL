import { initAdminPage, setStatus, supabase } from "./admin_common.js";
import { loadGlobalSettings } from "./global.js";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage("draft", "Draft auction"))) return;
  document.getElementById("resetDraftBtn").onclick = resetDraft;
});

async function resetDraft() {
  if (
    !confirm(
      "Reset draft schedule?\n\nClears start/finish times and turns the auction off. Completed transfers and bids are kept."
    )
  ) {
    return;
  }

  setStatus("resetDraftStatus", "Resetting…");
  const { error } = await supabase.rpc("admin_reset_draft_auction");

  if (error) {
    setStatus(
      "resetDraftStatus",
      "❌ " +
        (error.message || "Failed") +
        " — run admin_reset_draft_auction.sql in Supabase.",
      false
    );
    return;
  }

  setStatus("resetDraftStatus", "✅ Draft schedule reset.", true);
  await loadGlobalSettings();
}
