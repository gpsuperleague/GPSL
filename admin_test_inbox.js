import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("sendTestInboxBtn").onclick = sendTestInboxAllClubs;
  document.getElementById("clearTestInboxBtn").onclick = clearTestInboxAllClubs;
});

async function sendTestInboxAllClubs() {
  if (
    !confirm(
      "Send 17 sample inbox messages to EVERY club with an owner?\n\nTitles are prefixed [TEST]. Previous test batch will be cleared first."
    )
  ) {
    return;
  }
  setStatus("testInboxStatus", "Sending…");
  const { data, error } = await supabase.rpc("owner_inbox_admin_send_test_notifications", {
    p_batch: "preview",
    p_resend: true,
  });
  if (error) {
    setStatus(
      "testInboxStatus",
      "❌ " + error.message + " — run patches/owner_inbox_test_notifications.sql",
      false
    );
    return;
  }
  setStatus(
    "testInboxStatus",
    `✅ Sent ${data?.sent ?? 0} messages to ${data?.clubs ?? 0} club(s) (${data?.types ?? 17} types each). Skipped ${data?.skipped ?? 0} duplicate(s).`,
    true
  );
}

async function clearTestInboxAllClubs() {
  if (!confirm("Remove all [TEST] inbox messages (preview batch)?")) return;
  setStatus("testInboxStatus", "Clearing…");
  const { data, error } = await supabase.rpc("owner_inbox_admin_clear_test_notifications", {
    p_batch: "preview",
  });
  if (error) {
    setStatus("testInboxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("testInboxStatus", `✅ Cleared ${data ?? 0} test message(s).`, true);
}
