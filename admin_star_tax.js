import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadStarTaxSettings();
  document.getElementById("saveStarTaxBtn").onclick = saveStarTaxSettings;
});

function setInput(id, val) {
  const el = document.getElementById(id);
  if (el && val != null) el.value = val;
}

async function loadStarTaxSettings() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("starTaxStatus", "❌ " + error.message + " — run competition_wages_taxes.sql", false);
    return;
  }
  if (!data) return;
  setInput("starTaxMinRating", data.star_tax_min_rating ?? 70);
  setInput("starTaxPerPlayer", data.star_tax_per_player ?? 1000000);
}

async function saveStarTaxSettings() {
  setStatus("starTaxStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_upkeep_tax_settings", {
    p_settings: {
      star_tax_min_rating: Number(document.getElementById("starTaxMinRating")?.value),
      star_tax_per_player: Number(document.getElementById("starTaxPerPlayer")?.value),
    },
  });
  if (error) {
    setStatus("starTaxStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("starTaxStatus", "✅ Star settings saved.", true);
}
