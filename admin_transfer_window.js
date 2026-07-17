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

  // Admin RPC (SECURITY DEFINER) — direct UPDATE on global_settings is revoked
  // for authenticated; the old update-global-settings edge fn is unreliable.
  const { data, error } = await supabase.rpc("admin_set_transfer_window_open", {
    p_open: transfer_window_open,
  });

  if (error) {
    setStatus(
      "transferWindowStatus",
      error.message.includes("admin_set_transfer_window_open")
        ? "❌ Run admin_set_transfer_window_open.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    setStatus(
      "transferWindowStatus",
      "⚠ " + (data?.reason || "Could not update transfer window"),
      false
    );
    return;
  }

  const discordBit = data.discord_queue_id
    ? ` Discord queued #${data.discord_queue_id} — Push on Discord News if needed.`
    : data.changed === false
      ? " (already that state — flip the other way for Discord)."
      : data.discord_error
        ? ` Discord failed: ${data.discord_error}`
        : data.hint
          ? ` ${data.hint}`
          : "";

  setStatus(
    "transferWindowStatus",
    (transfer_window_open
      ? "✅ Transfer window is now open."
      : "✅ Transfer window is now closed.") + discordBit,
    !data.discord_error
  );
  await loadGlobalSettings();
  await loadTransferWindow();
}
