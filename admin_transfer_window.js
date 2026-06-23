import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadGlobalSettings } from "./global.js";

primeAdminPageChrome();

function applyHashPreset() {
  const hash = (window.location.hash || "").replace("#", "").toLowerCase();
  const sel = document.getElementById("transferWindowSelect");
  if (!sel) return;
  if (hash === "open") sel.value = "true";
  else if (hash === "closed") sel.value = "false";
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  applyHashPreset();
  await loadTransferWindow();
  document.getElementById("saveTransferWindowBtn").onclick = saveTransferWindow;
});

async function loadTransferWindow() {
  const { data } = await supabase.from("global_settings").select("transfer_window_open").eq("id", 1).single();
  if (!data) return;

  const open = data.transfer_window_open === true;
  document.getElementById("transferWindowSelect").value = open ? "true" : "false";

  const note = document.getElementById("transferWindowCurrent");
  if (note) {
    note.textContent = open
      ? "Currently open — owners can trade on the transfer market."
      : "Currently closed — transfer market actions are blocked for owners.";
  }
}

async function saveTransferWindow() {
  const transfer_window_open =
    document.getElementById("transferWindowSelect").value === "true";

  setStatus("transferWindowStatus", "Saving…");
  const { error } = await supabase.functions.invoke("update-global-settings", {
    body: { transfer_window_open },
  });

  if (error) {
    const { error: updError } = await supabase
      .from("global_settings")
      .update({
        transfer_window_open,
        updated_at: new Date().toISOString(),
      })
      .eq("id", 1);

    if (updError) {
      setStatus(
        "transferWindowStatus",
        "❌ " + (updError.message || error.message || "Save failed"),
        false
      );
      return;
    }
  }

  setStatus(
    "transferWindowStatus",
    transfer_window_open ? "✅ Transfer window is now open." : "✅ Transfer window is now closed.",
    true
  );
  await loadGlobalSettings();
  await loadTransferWindow();
}
