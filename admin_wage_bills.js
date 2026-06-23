import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  document.getElementById("postWageBillsBtn").onclick = postSeasonWageBills;
});

async function loadCurrentSeasonId() {
  const { data } = await supabase
    .from("competition_seasons")
    .select("id")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  currentSeasonId = data?.id ?? null;
}

async function postSeasonWageBills() {
  setStatus("wageBillsStatus", "Posting…");
  const { data, error } = await supabase.rpc("competition_admin_post_season_wage_bills", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("wageBillsStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "wageBillsStatus",
    `✅ Posted ${data?.charge_lines ?? 0} charge line(s) for ${data?.clubs_charged ?? 0} club(s). Skips already posted.`,
    true
  );
}
