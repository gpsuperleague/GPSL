import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadIncomeTaxSettings();
  document.getElementById("saveIncomeTaxBtn").onclick = saveIncomeTaxSettings;
  await loadAgentFeeSettings();
  document.getElementById("saveAgentFeeBtn").onclick = saveAgentFeeSettings;
  document.getElementById("taxTrueUpPreviewBtn").onclick = () => runTaxTrueUp(true);
  document.getElementById("taxTrueUpApplyBtn").onclick = () => runTaxTrueUp(false);
  document.getElementById("incomeTaxPct")?.addEventListener("input", () => {
    document.getElementById("taxTrueUpApplyBtn").disabled = true;
  });
});

function formatB(n) {
  const v = Number(n) || 0;
  const abs = Math.abs(v).toLocaleString("en-GB", { maximumFractionDigits: 0 });
  return (v < 0 ? "−₿" : "₿") + abs;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderTaxTrueUp(data) {
  const el = document.getElementById("taxTrueUpResult");
  const rows = Array.isArray(data?.rows) ? data.rows : [];
  if (!rows.length) {
    el.innerHTML = "";
    return;
  }
  const body = rows
    .map((r) => {
      const diff = Number(r.difference) || 0;
      const action =
        Math.abs(diff) < 1
          ? `<span style="color:#888;">Level</span>`
          : diff > 0
            ? `<span style="color:#f88;">Charge ${formatB(diff)}</span>`
            : `<span style="color:#8d8;">Refund ${formatB(-diff)}</span>`;
      return `<tr>
        <td>${escapeHtml(r.club)}</td>
        <td style="text-align:right;">${Number(r.purchases) || 0}</td>
        <td style="text-align:right;">${formatB(r.taxable_spend)}</td>
        <td style="text-align:right;">${formatB(r.tax_charged)}</td>
        <td style="text-align:right;">${formatB(r.tax_due)}</td>
        <td style="text-align:right;">${action}</td>
      </tr>`;
    })
    .join("");
  el.innerHTML = `
    <table class="admin-table" style="width:100%;margin-top:10px;font-size:12px;">
      <thead>
        <tr>
          <th>Club</th>
          <th style="text-align:right;">Purchases</th>
          <th style="text-align:right;">Taxable spend</th>
          <th style="text-align:right;">Tax charged so far</th>
          <th style="text-align:right;">Tax at ${escapeHtml(data.tax_pct)}%</th>
          <th style="text-align:right;">Action</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}

async function runTaxTrueUp(dryRun) {
  const applyBtn = document.getElementById("taxTrueUpApplyBtn");

  if (!dryRun) {
    const ok = confirm(
      "Charge or refund each club the income tax difference now?\n\n" +
        "Every purchase this season is re-taxed at the CURRENT %. " +
        "Clubs already level are skipped. Safe to re-run."
    );
    if (!ok) return;
  }

  setStatus("taxTrueUpStatus", dryRun ? "Previewing…" : "Applying…");
  applyBtn.disabled = true;

  const { data, error } = await supabase.rpc("admin_income_tax_true_up", {
    p_dry_run: dryRun,
  });

  if (error) {
    setStatus(
      "taxTrueUpStatus",
      error.message.includes("admin_income_tax_true_up")
        ? "Run supabase/sql/patches/income_tax_season_true_up_20261010.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  renderTaxTrueUp(data);
  const n = Number(data?.clubs_changed || 0);
  const total = Number(data?.total_difference || 0);
  const net =
    total >= 0 ? `net ${formatB(total)} charged` : `net ${formatB(-total)} refunded`;

  if (dryRun) {
    setStatus(
      "taxTrueUpStatus",
      n
        ? `Preview at ${data.tax_pct}%: ${n} club(s) change — ${net}. Check the table, then Apply.`
        : `Every club is already level at ${data.tax_pct}% — nothing to do.`,
      true
    );
    applyBtn.disabled = n === 0;
  } else {
    setStatus("taxTrueUpStatus", `✅ Applied at ${data.tax_pct}% to ${n} club(s) — ${net}.`, true);
  }
}

async function loadAgentFeeSettings() {
  const { data, error } = await supabase
    .from("global_settings")
    .select("transfer_agent_fee_pct")
    .eq("id", 1)
    .single();

  if (error) {
    setStatus(
      "agentFeeStatus",
      "❌ " + error.message + " — run patches/transfer_agent_fee_pct_20260928.sql",
      false
    );
    return;
  }

  const el = document.getElementById("agentFeePct");
  if (el) el.value = data?.transfer_agent_fee_pct ?? 1;
}

async function saveAgentFeeSettings() {
  const pct = Number(document.getElementById("agentFeePct")?.value);

  if (!Number.isFinite(pct) || pct < 0 || pct > 100) {
    setStatus("agentFeeStatus", "Agent fee % must be 0–100.", false);
    return;
  }

  setStatus("agentFeeStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_transfer_agent_fee_pct", {
    p_pct: pct,
  });

  if (error) {
    setStatus(
      "agentFeeStatus",
      error.message.includes("admin_update_transfer_agent_fee_pct")
        ? "Run patches/transfer_agent_fee_pct_20260928.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  setStatus(
    "agentFeeStatus",
    `✅ Agent fee saved — ${pct}% of the fee on transfer list deals (paid by the buyer).`,
    true
  );
}

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
