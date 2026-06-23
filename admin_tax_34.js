import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadTax34Settings();
  document.getElementById("saveTax34Btn").onclick = saveTax34Settings;
});

function setInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadTax34Settings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("tax34Status", "❌ " + error.message + " — run competition_wages_taxes.sql", false);
    return;
  }
  if (!data) return;
  setInput("tax34MinRating", data.wage_34plus_min_rating ?? 34);
  setInput("tax34PerPlayer", data.wage_34plus_per_player ?? 500000);
}

async function saveTax34Settings() {
  setStatus("tax34Status", "Saving…");
  const { error } = await supabase.rpc("admin_update_upkeep_tax_settings", {
    p_settings: {
      wage_34plus_min_rating: Number(document.getElementById("tax34MinRating")?.value),
      wage_34plus_per_player: Number(document.getElementById("tax34PerPlayer")?.value),
    },
  });
  if (error) {
    setStatus("tax34Status", "❌ " + error.message, false);
    return;
  }
  setStatus("tax34Status", "✅ 34+ settings saved.", true);
}
