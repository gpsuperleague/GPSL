import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  document.getElementById("closeFinancesBtn").onclick = closeFinances;
  document.getElementById("postWageBillsBtn").onclick = postSeasonWageBills;

  document.getElementById("upkeepPreviewBtn").onclick = () => runUpkeepResettle(true);
  document.getElementById("upkeepApplyBtn").onclick = () => runUpkeepResettle(false);
  for (const id of ["upkeepDivision", "upkeepBasis", "upkeepInterest"]) {
    document.getElementById(id).onchange = () => {
      document.getElementById("upkeepApplyBtn").disabled = true;
    };
  }
});

function formatB(n) {
  const v = Number(n) || 0;
  const abs = Math.abs(v).toLocaleString("en-GB", { maximumFractionDigits: 0 });
  return (v < 0 ? "−₿" : "₿") + abs;
}

function signedB(n) {
  const v = Number(n) || 0;
  if (Math.abs(v) < 0.5) return "—";
  return (v > 0 ? "+" : "") + formatB(v);
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function runUpkeepResettle(dryRun) {
  if (!currentSeasonId) {
    setStatus("upkeepStatus", "No current season.", false);
    return;
  }
  const division = document.getElementById("upkeepDivision").value || null;
  const basis = document.getElementById("upkeepBasis").value;
  const trueUp = document.getElementById("upkeepInterest").checked;
  const applyBtn = document.getElementById("upkeepApplyBtn");

  if (!dryRun) {
    const ok = confirm(
      "Post wage / upkeep differences to club balances now?\n\n" +
        (basis === "wage_pct"
          ? "Player wages will be repriced at the CURRENT wage % for this season's bill.\n"
          : "Player wages use stored contract wages (same as Close Finances).\n") +
        (trueUp ? "End-of-season interest will also be corrected.\n" : "") +
        "FFP is not changed. Safe to re-run."
    );
    if (!ok) return;
  }

  setStatus("upkeepStatus", dryRun ? "Previewing…" : "Applying…");
  applyBtn.disabled = true;

  const { data, error } = await supabase.rpc("competition_admin_resettle_season_upkeep", {
    p_season_id: currentSeasonId,
    p_division: division,
    p_dry_run: dryRun,
    p_true_up_interest: trueUp,
    p_wage_basis: basis,
  });

  if (error) {
    setStatus(
      "upkeepStatus",
      error.message.includes("competition_admin_resettle_season_upkeep")
        ? "Run supabase/sql/patches/season_upkeep_resettle_20260928.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  renderUpkeepResettle(data);
  const n = Number(data?.clubs_changed || 0);
  const totals = `upkeep ${signedB(data.total_upkeep_delta)}, interest ${signedB(data.total_interest_delta)}`;
  if (dryRun) {
    setStatus(
      "upkeepStatus",
      n
        ? `Preview: ${n} club(s) change — ${totals} (club cash effect). Check the table, then Apply.`
        : "Nothing to re-settle — posted charges already match (or Close Finances has not run).",
      true
    );
    applyBtn.disabled = n === 0;
  } else {
    setStatus("upkeepStatus", `✅ Applied to ${n} club(s) — ${totals}.`, true);
  }
}

function renderUpkeepResettle(data) {
  const el = document.getElementById("upkeepResult");
  const rows = Array.isArray(data?.rows) ? data.rows : [];
  if (!rows.length) {
    el.innerHTML = "";
    return;
  }
  const divShort = { superleague: "SL", championship_a: "ChA", championship_b: "ChB" };
  const color = (n) => (Number(n) >= 0 ? "#8d8" : "#f88");
  el.innerHTML = `
    <table class="admin-table" style="width:100%;margin-top:10px;font-size:12px;">
      <thead>
        <tr>
          <th>Club</th><th>Div</th><th>Changes (old → new)</th>
          <th>Upkeep effect</th><th>Interest effect</th><th>Net effect</th><th>Review</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `<tr>
          <td>${escapeHtml(r.club)}</td>
          <td>${escapeHtml(divShort[r.division] || r.division)}</td>
          <td style="white-space:normal;">${(r.lines || [])
            .map(
              (l) =>
                `${escapeHtml(l.label)}: ${formatB(l.old)} → ${formatB(l.new)} ` +
                `<span style="color:${color(l.club_effect)}">(${signedB(l.club_effect)})</span>`
            )
            .join("<br>")}</td>
          <td style="color:${color(r.upkeep_delta)}">${signedB(r.upkeep_delta)}</td>
          <td>${signedB(r.interest_delta)}</td>
          <td style="color:${color(r.net_effect)}">${signedB(r.net_effect)}</td>
          <td style="color:#fc9;white-space:normal;">${(r.flags || []).map(escapeHtml).join("<br>")}</td>
        </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

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
  setStatus("wageBillsStatus", "Posting wage bills…");
  const { data, error } = await supabase.rpc("competition_admin_post_season_wage_bills", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("wageBillsStatus", "❌ " + error.message, false);
    return;
  }
  setStatus(
    "wageBillsStatus",
    `✅ Posted ${data?.charge_lines ?? 0} wage line(s) for ${data?.clubs_charged ?? 0} club(s). Skips already posted.`,
    true
  );
}

async function closeFinances() {
  if (
    !confirm(
      "Close Finances for the current season?\n\n" +
        "This posts wage bills, stadium maintenance, debt interest, " +
        "FFP (₿50M + MV player releases until above −₿99,999,999 + next-window buy embargo), " +
        "and 0.5% interest on positive balances.\n\n" +
        "Already-posted lines are skipped."
    )
  ) {
    return;
  }

  setStatus("wageBillsStatus", "Closing finances…");
  const { data, error } = await supabase.rpc("competition_admin_close_finances", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    let hint = "";
    if (/charge_type_check|competition_season_charge_paid/i.test(error.message)) {
      hint = " — run supabase/sql/patches/season_charge_paid_types_hotfix_20260925.sql in Supabase.";
    } else if (/underperformance|cannot be removed manually/i.test(error.message)) {
      hint = " — run supabase/sql/patches/ffp_release_perpetual_listing_hotfix_20260925.sql in Supabase.";
    }
    setStatus("wageBillsStatus", "❌ " + error.message + hint, false);
    return;
  }

  const wages = data?.wages || {};
  setStatus(
    "wageBillsStatus",
    `✅ Close Finances complete (season ${data?.season_id ?? "—"}). ` +
      `Wages: ${wages.charge_lines ?? 0} line(s) / ${wages.clubs_charged ?? 0} club(s). ` +
      `Maintenance: ${data?.infra_maintenance_clubs ?? 0}. ` +
      `Debt interest: ${data?.debt_interest_clubs ?? 0}. ` +
      `FFP: ${data?.ffp_clubs ?? 0}. ` +
      `Balance interest: ${data?.balance_interest_clubs ?? 0}.`,
    true
  );
}
