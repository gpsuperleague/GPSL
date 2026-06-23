import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadIncomeTaxSettings();
  document.getElementById("saveIncomeTaxBtn").onclick = saveIncomeTaxSettings;
});

async function loadIncomeTaxSettings() {
  const { data, error } = await supabase.from("global_settings").select("gov_income_tax_pct").eq("id", 1).single();

  if (error) {
    setStatus(
      "incomeTaxStatus",
      "❌ " + error.message + " — run patches/gov_income_tax.sql",
      false
    );
    return;
  }

  const el = document.getElementById("incomeTaxPct");
  if (el) el.value = data?.gov_income_tax_pct ?? 0;
}

async function saveIncomeTaxSettings() {
  const pct = Number(document.getElementById("incomeTaxPct")?.value);

  if (!Number.isFinite(pct) || pct < 0 || pct > 100) {
    setStatus("incomeTaxStatus", "Tax % must be 0–100.", false);
    return;
  }

  setStatus("incomeTaxStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_income_tax_settings", {
    p_pct: pct,
  });

  if (error) {
    const { error: updError } = await supabase
      .from("global_settings")
      .update({
        gov_income_tax_pct: pct,
        updated_at: new Date().toISOString(),
      })
      .eq("id", 1);

    if (updError) {
      setStatus("incomeTaxStatus", "❌ " + (updError.message || error.message), false);
      return;
    }
    setStatus("incomeTaxStatus", "✅ Saved (direct update). Run patches/gov_income_tax.sql for RPC.", true);
    return;
  }

  setStatus("incomeTaxStatus", `✅ Income tax % saved — ${pct}% on player spend.`, true);
}
