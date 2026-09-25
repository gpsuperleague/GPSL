import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { initGpslInfoTips, tipDataAttrs } from "./gpsl_info_tips.js";
import {
  FIN_BALANCE_TIPS,
  renderLeagueFinanceBalanceRules,
} from "./admin_league_finance_balance_rules.js?v=20260915-vacant-backfill";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  initGpslInfoTips();
  renderLeagueFinanceBalanceRules();
  await loadSeasons();
  document.getElementById("finBalRunBtn").onclick = runAnalysis;
  document.getElementById("finBalVacantBtn").onclick = backfillVacantClubs;
  document.getElementById("finBalTarget").addEventListener("blur", () => {
    const el = document.getElementById("finBalTarget");
    const n = parseMoney(el.value);
    if (Number.isFinite(n)) el.value = formatPlain(n);
  });
});

function parseMoney(raw) {
  if (raw == null || raw === "") return NaN;
  const n = Number(String(raw).replace(/,/g, "").trim());
  return Number.isFinite(n) ? n : NaN;
}

function formatPlain(n) {
  return Math.round(n).toLocaleString("en-GB");
}

function formatB(n) {
  if (n == null || !Number.isFinite(Number(n))) return "—";
  const v = Number(n);
  const abs = Math.abs(v).toLocaleString("en-GB", {
    maximumFractionDigits: 0,
  });
  return (v < 0 ? "−₿" : "₿") + abs;
}

function moneyClass(n) {
  if (n == null || !Number.isFinite(Number(n))) return "";
  if (Number(n) > 0) return "pos";
  if (Number(n) < 0) return "neg";
  return "";
}

function divShort(d) {
  if (!d) return "—";
  if (d === "superleague") return "SL";
  if (d === "championship_a") return "ChA";
  if (d === "championship_b") return "ChB";
  return d;
}

async function loadSeasons() {
  const sel = document.getElementById("finBalSeason");
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });

  if (error) {
    setStatus("finBalStatus", "❌ " + error.message, false);
    return;
  }

  sel.innerHTML = "";
  for (const s of data || []) {
    const opt = document.createElement("option");
    opt.value = String(s.id);
    opt.textContent = `${s.label || "Season " + s.id} (${s.status}${s.is_current ? ", current" : ""})`;
    if (s.is_current) opt.selected = true;
    sel.appendChild(opt);
  }
}

async function runAnalysis() {
  const seasonId = Number(document.getElementById("finBalSeason").value);
  const target = parseMoney(document.getElementById("finBalTarget").value);
  if (!seasonId) {
    setStatus("finBalStatus", "Pick a season.", false);
    return;
  }
  if (!Number.isFinite(target)) {
    setStatus("finBalStatus", "Enter a valid target average profit.", false);
    return;
  }

  setStatus("finBalStatus", "Analysing…");
  document.getElementById("finBalSummary").hidden = true;

  const { data, error } = await supabase.rpc("competition_admin_league_finance_balance", {
    p_season_id: seasonId,
    p_target_avg_ops_profit: target,
  });

  if (error) {
    setStatus(
      "finBalStatus",
      "❌ " +
        error.message +
        " — deploy supabase/sql/patches/league_finance_balance_div_avg_opening_fix_20260925.sql",
      false
    );
    return;
  }

  renderReport(data);
  setStatus(
    "finBalStatus",
    `✅ ${data.season_label || "Season"} — ${data.club_count || 0} clubs analysed.`,
    true
  );
}

async function backfillVacantClubs() {
  const seasonId = Number(document.getElementById("finBalSeason").value);
  if (!seasonId) {
    setStatus("finBalStatus", "Pick a season.", false);
    return;
  }

  const ok = confirm(
    "Backfill all unowned Super League / Championship clubs in this season?\n\n" +
      "• Posts stadium purchase (if missing) with ₿650m starting-budget trail\n" +
      "• Debits stadium from live cash (does not wipe gates already earned)\n" +
      "• Hires a club doctor if missing (₿5m)\n\n" +
      "Safe to re-run. Manager salary still posts at Close Finances."
  );
  if (!ok) return;

  const btn = document.getElementById("finBalVacantBtn");
  if (btn) btn.disabled = true;
  setStatus("finBalStatus", "Backfilling vacant league clubs…");

  const { data, error } = await supabase.rpc("admin_backfill_vacant_league_club_costs", {
    p_season_id: seasonId,
    p_hire_doctor: true,
  });

  if (btn) btn.disabled = false;

  if (error) {
    setStatus(
      "finBalStatus",
      "❌ " +
        error.message +
        " — deploy supabase/sql/patches/vacant_league_club_costs_backfill_20260915.sql",
      false
    );
    return;
  }

  setStatus(
    "finBalStatus",
    `✅ Vacant backfill: ${data?.clubs_processed ?? 0} clubs · ` +
      `${data?.stadium_posts ?? 0} stadium posts · ` +
      `${data?.doctors_hired ?? 0} doctors hired. Re-run analysis to refresh.`,
    true
  );
}

function renderReport(data) {
  const summary = document.getElementById("finBalSummary");
  summary.hidden = false;

  const setKpi = (id, val, cls) => {
    const el = document.getElementById(id);
    el.textContent = val;
    el.className = "val" + (cls ? " " + cls : "");
  };

  const avg = Number(data.ops_net_avg || 0);
  const med = Number(data.ops_net_median || 0);
  const target = Number(data.target_avg_ops_profit || 0);
  const gapClub = Number(data.gap_vs_target_avg || 0);
  const gapTotal = Number(data.gap_vs_target_total || 0);
  const clubs = Number(data.club_count || 0);
  const cats = data.category_totals || {};

  setKpi("kpiClubs", String(clubs));
  setKpi("kpiAvg", formatB(avg), moneyClass(avg));
  setKpi("kpiMed", formatB(med), moneyClass(med));
  setKpi("kpiTarget", formatB(target));

  const gapLabel =
    gapClub > 1000000
      ? `Shortfall ${formatB(gapClub)}`
      : gapClub < -1000000
        ? `Surplus ${formatB(Math.abs(gapClub))}`
        : formatB(gapClub);
  const gapTotalLabel =
    gapTotal > 1000000
      ? `Shortfall ${formatB(gapTotal)}`
      : gapTotal < -1000000
        ? `Surplus ${formatB(Math.abs(gapTotal))}`
        : formatB(gapTotal);

  setKpi(
    "kpiGapClub",
    gapLabel,
    gapClub > 1000000 ? "neg" : gapClub < -1000000 ? "pos" : ""
  );
  setKpi(
    "kpiGapTotal",
    gapTotalLabel,
    gapTotal > 1000000 ? "neg" : gapTotal < -1000000 ? "pos" : ""
  );

  const gapClubSub = document.getElementById("kpiGapClubSub");
  const gapTotalSub = document.getElementById("kpiGapTotalSub");
  if (gapClubSub) {
    gapClubSub.textContent =
      gapClub > 1000000
        ? "Need this much more profit each"
        : gapClub < -1000000
          ? "This much over your goal each"
          : "Close to your goal";
  }
  if (gapTotalSub) {
    gapTotalSub.textContent =
      gapTotal > 1000000
        ? "Rough size of league-wide fix"
        : gapTotal < -1000000
          ? "Rough size to cool the league"
          : "Little/no league-wide move needed";
  }

  renderVerdict(data, { avg, med, target, gapClub, gapTotal, clubs, cats });

  const hint = document.getElementById("finBalHint");
  if (hint) {
    const text = String(data.tuning_hint || "").trim();
    hint.textContent = text;
    hint.hidden = !text;
  }

  const divLabel = (d) => {
    if (d === "superleague") return "Super League";
    if (d === "championship_a") return "Championship A";
    if (d === "championship_b") return "Championship B";
    return d || "Unassigned";
  };
  const byDiv = Array.isArray(data.by_division) ? data.by_division : [];
  const divEl = document.getElementById("finBalByDivision");
  if (divEl) {
    if (!byDiv.length) {
      divEl.innerHTML = `<div class="note">No division splits returned — re-run SQL patch league_finance_balance_div_avg_opening_fix_20260925.sql</div>`;
    } else {
      divEl.innerHTML = byDiv
        .map((d) => {
          const dAvg = Number(d.ops_net_avg || 0);
          const dMed = Number(d.ops_net_median || 0);
          const dGap = Number(d.gap_vs_target_avg || 0);
          const gapTxt =
            dGap > 1000000
              ? `Shortfall ${formatB(dGap)}`
              : dGap < -1000000
                ? `Surplus ${formatB(Math.abs(dGap))}`
                : formatB(dGap);
          return `<div class="fin-div-card">
            <div class="div-name">${escapeHtml(divLabel(d.division))} · ${Number(d.club_count || 0)} clubs</div>
            <div class="div-row"><span>Average</span><b class="${moneyClass(dAvg)}">${formatB(dAvg)}</b></div>
            <div class="div-row"><span>Middle</span><b class="${moneyClass(dMed)}">${formatB(dMed)}</b></div>
            <div class="div-row"><span>vs goal</span><b class="${dGap > 1000000 ? "neg" : dGap < -1000000 ? "pos" : ""}">${gapTxt}</b></div>
          </div>`;
        })
        .join("");
    }
  }

  const catOrder = [
    ["gates", "Gates", FIN_BALANCE_TIPS.catGates],
    ["prizes", "Prizes", FIN_BALANCE_TIPS.catPrizes],
    ["tv", "TV", FIN_BALANCE_TIPS.catTv],
    ["subsidies", "Subsidies", FIN_BALANCE_TIPS.catSubsidies],
    ["wages", "Wages", FIN_BALANCE_TIPS.catWages],
    ["stadium", "Stadium ops", FIN_BALANCE_TIPS.catStadium],
    ["tax_fines", "Tax", FIN_BALANCE_TIPS.catTax],
    ["staff", "Staff", FIN_BALANCE_TIPS.catStaff],
    ["eos", "EOS", FIN_BALANCE_TIPS.catEos],
    ["admin_adj", "Admin adj.", FIN_BALANCE_TIPS.catAdmin],
    ["other_ops", "Other ops", FIN_BALANCE_TIPS.catOther],
    ["stadium_purchase", "Stadium buy (excl.)", FIN_BALANCE_TIPS.catStadiumPurchase],
    ["fines", "Fines (excl.)", FIN_BALANCE_TIPS.catFines],
    ["transfers", "Transfers (excl.)", FIN_BALANCE_TIPS.catTransfers],
    ["loans", "Loans (excl.)", FIN_BALANCE_TIPS.catLoans],
  ];
  const catEl = document.getElementById("finBalCats");
  catEl.innerHTML = catOrder
    .map(
      ([k, label, tip]) =>
        `<div><span class="gpsl-has-tip"${tipDataAttrs(tip)}>${label}</span><b class="${moneyClass(cats[k])}">${formatB(cats[k])}</b></div>`
    )
    .join("");

  const clubRows = Array.isArray(data.clubs) ? [...data.clubs] : [];
  clubRows.sort((a, b) => Number(b.ops_net || 0) - Number(a.ops_net || 0));

  const body = document.getElementById("finBalBody");
  body.innerHTML = clubRows
    .map((c) => {
      const cell = (v) =>
        `<td class="${moneyClass(v)}">${formatB(v)}</td>`;
      return `<tr>
        <td>${escapeHtml(c.club || "")}</td>
        <td>${escapeHtml(divShort(c.division))}</td>
        ${cell(c.opening_balance)}
        ${cell(c.gates)}
        ${cell(c.prizes)}
        ${cell(c.tv)}
        ${cell(c.subsidies)}
        ${cell(c.wages)}
        ${cell(c.stadium)}
        ${cell(c.tax_fines)}
        ${cell(c.staff)}
        ${cell(c.ops_net)}
        ${cell(c.transfers_net)}
        ${cell(c.balance_now)}
      </tr>`;
    })
    .join("");

  const sum = (key) => clubRows.reduce((a, c) => a + Number(c[key] || 0), 0);
  const foot = document.getElementById("finBalFoot");
  const fcell = (v) => `<td class="${moneyClass(v)}">${formatB(v)}</td>`;
  foot.innerHTML = `<tr>
    <td>TOTAL</td>
    <td></td>
    ${fcell(sum("opening_balance"))}
    ${fcell(sum("gates"))}
    ${fcell(sum("prizes"))}
    ${fcell(sum("tv"))}
    ${fcell(sum("subsidies"))}
    ${fcell(sum("wages"))}
    ${fcell(sum("stadium"))}
    ${fcell(sum("tax_fines"))}
    ${fcell(sum("staff"))}
    ${fcell(sum("ops_net"))}
    ${fcell(sum("transfers_net"))}
    ${fcell(sum("balance_now"))}
  </tr>`;
}

function renderVerdict(data, { avg, med, target, gapClub, gapTotal, clubs, cats }) {
  const box = document.getElementById("finBalVerdict");
  const statusEl = document.getElementById("finBalVerdictStatus");
  const meansEl = document.getElementById("finBalVerdictMeans");
  const actionsEl = document.getElementById("finBalVerdictActions");
  if (!box || !statusEl || !meansEl || !actionsEl) return;

  const wages = Number(cats.wages || 0);
  const subsidies = Number(cats.subsidies || 0);
  const eos = Number(cats.eos || 0);
  const incomplete =
    Math.abs(wages) < 1 && Math.abs(subsidies) < 1 && Math.abs(eos) < 1;

  const verdict = String(data.verdict || "");
  let tone = "near";
  let tag = "On track";
  let headline = "Day-to-day finances look near your goal";

  if (incomplete) {
    tone = "incomplete";
    tag = "Incomplete season";
    headline = "Useful progress check — not a final redesign yet";
  } else if (verdict === "under_target" || gapClub > 1000000) {
    tone = "under";
    tag = "Shortfall";
    headline =
      avg < 0
        ? "Clubs are losing money on day-to-day running"
        : "Clubs are making less day-to-day profit than you want";
  } else if (verdict === "over_target" || gapClub < -1000000) {
    tone = "over";
    tag = "Too rich";
    headline = "Clubs are making more day-to-day profit than you want";
  }

  box.className = `fin-verdict is-${tone}`;
  statusEl.innerHTML = `${escapeHtml(headline)} <span class="tag">${escapeHtml(
    tag
  )}</span>`;

  if (incomplete) {
    meansEl.textContent =
      `Right now the average club’s day-to-day result is ${formatB(avg)} ` +
      `(middle club ${formatB(med)}). Your goal is ${formatB(target)} profit each. ` +
      `Wages, subsidies and end-of-season lines are still ₿0 — so this is mid-season progress, not the full year.`;
    actionsEl.innerHTML = `
      <li><b>Do not</b> redesign prize / wage tables from this run alone.</li>
      <li>Use it to check gates, prizes and TV so far.</li>
      <li>Re-run <b>after Close Finances</b> (wages + stadium maintenance + EOS), then use the shortfall/surplus numbers to tune.</li>
      <li>If you must act early: treat ${formatB(Math.abs(gapClub))} per club as a <b>rough</b> direction only.</li>
    `;
    return;
  }

  if (tone === "under") {
    meansEl.textContent =
      `Average club day-to-day result: ${formatB(avg)}. ` +
      `You want about ${formatB(target)} profit each. ` +
      `That is a shortfall of about ${formatB(gapClub)} per club ` +
      `(≈ ${formatB(gapTotal)} across ${clubs} clubs). ` +
      `Transfers are ignored here — this is running the club, not the transfer market.`;
    actionsEl.innerHTML = `
      <li><b>Add income</b> — raise league/cup prizes, TV, or government subsidies by roughly ${formatB(gapClub)} per club in total.</li>
      <li><b>Or cut costs</b> — ease wage %, tax, stadium maintenance, or staff pressure by a similar amount.</li>
      <li>Often a mix works better than one huge prize bump.</li>
      <li>Check category totals below: if stadium/tax dominate, fix those levers first.</li>
    `;
    return;
  }

  if (tone === "over") {
    meansEl.textContent =
      `Average club day-to-day result: ${formatB(avg)}. ` +
      `You only want about ${formatB(target)} profit each. ` +
      `Clubs are about ${formatB(Math.abs(gapClub))} too rich on ops each ` +
      `(≈ ${formatB(Math.abs(gapTotal))} league-wide).`;
    actionsEl.innerHTML = `
      <li><b>Cool income</b> — trim prizes, TV, or subsidies.</li>
      <li><b>Or raise costs</b> — wage %, tax, or maintenance pressure.</li>
      <li>Aim for about ${formatB(Math.abs(gapClub))} less ops profit per club.</li>
    `;
    return;
  }

  meansEl.textContent =
    `Average club day-to-day result (${formatB(avg)}) is close to your goal (${formatB(target)}). ` +
    `Middle club is ${formatB(med)}. Fine-tune only if you want a tighter band.`;
  actionsEl.innerHTML = `
    <li>No big prize/wage redesign needed.</li>
    <li>Optional: nudge prizes/TV/tax slightly if outliers bother you.</li>
  `;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
