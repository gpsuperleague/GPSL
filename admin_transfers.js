import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { loadGlobalSettings, computeNextDraftTimesFromNow } from "./global.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadSettings();
  document.getElementById("saveSettingsBtn").onclick = saveSettings;
  document.getElementById("runTransferEngineBtn").onclick = runTransferEngine;
});

async function loadSettings() {
  const { data } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (!data) return;

  document.getElementById("transferWindowSelect").value = data.transfer_window_open
    ? "true"
    : "false";
  document.getElementById("draftAuctionSelect").value = data.draft_auction_enabled
    ? "true"
    : "false";

  const el = document.getElementById("draftStartTime");
  if (data.draft_auction_enabled && data.draft_auction_start_time) {
    const ukFmt = new Intl.DateTimeFormat("en-GB", {
      timeZone: "Europe/London",
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const start = new Date(data.draft_auction_start_time);
    const finish = data.draft_random_finish_time
      ? new Date(data.draft_random_finish_time)
      : null;
    el.textContent =
      `Draft start: ${ukFmt.format(start)} UK` +
      (finish ? ` · Secret finish: ${ukFmt.format(finish)} UK` : " · ⚠ No secret finish set");
  } else {
    el.textContent = "";
  }
}

async function saveSettings() {
  const transfer_window_open =
    document.getElementById("transferWindowSelect").value === "true";
  const draft_auction_enabled =
    document.getElementById("draftAuctionSelect").value === "true";

  const { data: current } = await supabase
    .from("global_settings")
    .select("draft_auction_enabled, draft_auction_start_time, draft_random_finish_time")
    .eq("id", 1)
    .single();

  let draft_auction_start_time = current?.draft_auction_start_time || null;
  let draft_random_finish_time = current?.draft_random_finish_time || null;

  if (draft_auction_enabled && !current?.draft_auction_enabled) {
    const times = computeNextDraftTimesFromNow();
    draft_auction_start_time = times.draftStartISO;
    draft_random_finish_time = times.randomFinishISO;
  }

  if (!draft_auction_enabled) {
    draft_auction_start_time = null;
    draft_random_finish_time = null;
  }

  const { error } = await supabase.functions.invoke("update-global-settings", {
    body: {
      transfer_window_open,
      draft_auction_enabled,
      draft_random_finish_time,
      draft_auction_start_time,
    },
  });

  setStatus(
    "settingsMessage",
    error ? "❌ " + (error.message || "Error") : "✅ Settings updated.",
    !error
  );
  await loadGlobalSettings();
  await loadSettings();
}

async function runTransferEngine() {
  setStatus("transferEngineStatus", "Running…");
  try {
    const { data, error } = await supabase.rpc("admin_transferengine_run");
    if (error) throw error;
    setStatus(
      "transferEngineStatus",
      `✅ Ran at ${new Date(data?.ran_at || Date.now()).toLocaleString("en-GB")}. ` +
        `Stuck standard: ${data?.stuck_standard_before ?? "?"}. Active drafts: ${data?.active_draft_before ?? "?"}.`,
      true
    );
  } catch (err) {
    setStatus(
      "transferEngineStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run admin_transferengine_run.sql in Supabase.",
      false
    );
  }
}
