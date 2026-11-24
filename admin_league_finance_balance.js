import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { initGpslInfoTips, tipDataAttrs } from "./gpsl_info_tips.js";
import {
  FIN_BALANCE_TIPS,
  renderLeagueFinanceBalanceRules,
} from "./admin_league_finance_balance_rules.js?v=20261124-core-ops";
import {
  FORECAST_SECTIONS,
  buildLeagueFinanceForecast,
} from "./admin_league_finance_forecast.js?v=20261012-monthly-interest";

primeAdminPageChrome();

let forecastRows = null;
let forecastVisibleRows = [];
let lastBalanceReport = null;

/** Same core lines as the season check. Challenges, transfers, commercial, releases, and FFP stay out. */
const CORE_PREVIEW_LINE_IDS = [
  "prize_league",
  "prize_cup",
  "prize_tv",
  "gate_league",
  "gate_cup",
  "infra_maintenance",
  "gov_hg",
  "gov_youth",
  "gov_bnb",
  "gov_emergency_tax",
  "upkeep_wages",
  "upkeep_34plus",
  "upkeep_star_tax",
  "staff_manager",
  "gov_income_tax",
];

function corePreviewSections() {
  const keep = new Set(CORE_PREVIEW_LINE_IDS);
  return FORECAST_SECTIONS.map((section) => ({
    ...section,
    lines: section.lines.filter((line) => keep.has(line.id)),
  })).filter((section) => section.lines.length);
}

function coreForecastNet(row) {
  return CORE_PREVIEW_LINE_IDS.reduce(
    (sum, id) => sum + Number(row?.forecast?.[id] || 0),
    0
  );
}

const TWEAK_STORAGE_KEY = "gpsl_fin_balance_tweaks_v2";

/** Levers the admin can actually move. `lines` are forecast line ids summed into the lever base. */
const TWEAK_LEVERS = [
  { id: "prize_league", label: "League prize money", lines: ["prize_league"], share: 20, href: "admin_league_prizes.html", where: "League Prize Money" },
  { id: "prize_cup", label: "Cup prize money", lines: ["prize_cup"], share: 10, href: "admin_cup_prizes.html", where: "Cup Prize Money" },
  { id: "prize_tv", label: "TV revenue", lines: ["prize_tv"], share: 10, href: "admin_tv_revenue.html", where: "TV Revenue" },
  { id: "gates", label: "Gate receipts", lines: ["gate_league", "gate_cup"], share: 10, href: "admin_stadium_settings.html", where: "Stadium settings (ticket / gate)" },
  { id: "gov_hg", label: "HG subsidy", lines: ["gov_hg"], share: 10, href: "admin_gov_subsidies.html", where: "Gov subsidies" },
  { id: "gov_youth", label: "Youth subsidy", lines: ["gov_youth"], share: 5, href: "admin_gov_subsidies.html", where: "Gov subsidies" },
  { id: "upkeep_wages", label: "Wages", lines: ["upkeep_wages"], share: 15, href: "admin_wage_pct.html", where: "Wage %" },
  { id: "upkeep_34plus", label: "34+ age fee", lines: ["upkeep_34plus"], share: 5, href: "admin_tax_34.html", where: "34+ age fee" },
  { id: "upkeep_star_tax", label: "Star tax", lines: ["upkeep_star_tax"], share: 5, href: "admin_star_tax.html", where: "Star tax" },
  { id: "infra_maintenance", label: "Stadium maintenance", lines: ["infra_maintenance"], share: 5, href: "admin_stadium_costs.html", where: "Stadium costs (maintenance %)" },
  { id: "gov_income_tax", label: "Income tax", lines: ["gov_income_tax"], share: 5, href: "admin_tax_pct.html", where: "Tax %" },
];

function loadTweakSettings() {
  const defaults = {
    closePct: 100,
    capPct: 50,
    bandPct: 10,
    shares: Object.fromEntries(TWEAK_LEVERS.map((l) => [l.id, l.share])),
  };
  try {
    const raw = JSON.parse(localStorage.getItem(TWEAK_STORAGE_KEY) || "null");
    if (!raw) return defaults;
    return {
      closePct: Number.isFinite(Number(raw.closePct)) ? Number(raw.closePct) : defaults.closePct,
      capPct: Number(raw.capPct) > 0 ? Number(raw.capPct) : defaults.capPct,
      bandPct: Number.isFinite(Number(raw.bandPct)) ? Number(raw.bandPct) : defaults.bandPct,
      shares: { ...defaults.shares, ...(raw.shares || {}) },
    };
  } catch {
    return defaults;
  }
}

let tweakSettings = loadTweakSettings();

function saveTweakSettings() {
  try {
    localStorage.setItem(TWEAK_STORAGE_KEY, JSON.stringify(tweakSettings));
  } catch {
    /* ignore */
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  initGpslInfoTips();
  renderLeagueFinanceBalanceRules();
  await loadSeasons();
  document.getElementById("finBalRunBtn").onclick = runAnalysis;
  document.getElementById("finBalVacantBtn").onclick = backfillVacantClubs;
  document.getElementById("finFcRunBtn").onclick = runForecast;
  document.getElementById("finFcDivision").onchange = renderForecast;
  document.getElementById("finFcMode").onchange = renderForecast;
  document.getElementById("finFcOwned").onchange = renderForecast;
  document.getElementById("finBalDivision").onchange = refreshBalanceView;
  document.getElementById("finBalOwned").onchange = refreshBalanceView;
  document.querySelectorAll(".fin-tab").forEach((btn) => {
    btn.addEventListener("click", () => showFinTab(btn.dataset.finTab));
  });
  wireTweakControls();
  document.getElementById("finBalTarget").addEventListener("blur", () => {
    const el = document.getElementById("finBalTarget");
    const n = parseMoney(el.value);
    if (Number.isFinite(n)) el.value = formatPlain(n);
    refreshBalanceView();
  });
});

function medianOf(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function clubListFilters(divisionId, ownedId) {
  return {
    division: document.getElementById(divisionId)?.value || "all",
    ownedOnly: document.getElementById(ownedId)?.value === "owned",
  };
}

function clubMatchesFilters(club, filters) {
  if (filters.ownedOnly && !club?.owned) return false;
  if (filters.division !== "all" && club?.division !== filters.division) return false;
  return true;
}

function refreshBalanceView() {
  if (!lastBalanceReport) return;
  renderReport(lastBalanceReport);
}

function showFinTab(name) {
  document.querySelectorAll("[data-fin-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.finPanel !== name;
  });
  document.querySelectorAll(".fin-tab").forEach((btn) => {
    const on = btn.dataset.finTab === name;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
}

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

  lastBalanceReport = data;
  renderReport(data);
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

  const filters = clubListFilters("finBalDivision", "finBalOwned");
  const matched = (Array.isArray(data.clubs) ? data.clubs : []).filter((c) =>
    clubMatchesFilters(c, filters)
  );
  const targetInput = parseMoney(document.getElementById("finBalTarget").value);
  const target = Number.isFinite(targetInput)
    ? targetInput
    : Number(data.target_avg_ops_profit || 0);
  const nets = matched.map((c) => Number(c.ops_net || 0));
  const clubs = matched.length;
  const avg = clubs ? nets.reduce((sum, n) => sum + n, 0) / clubs : 0;
  const med = medianOf(nets);
  const gapClub = target - avg;
  const gapTotal = gapClub * clubs;
  const cats = {};
  for (const key of [
    "gates",
    "prize_league",
    "prize_cup",
    "tv",
    "subsidies",
    "wages",
    "stadium",
    "tax_fines",
    "staff",
  ]) {
    cats[key] = matched.reduce((sum, c) => sum + Number(c[key] || 0), 0);
  }
  const clubsSub = document.getElementById("kpiClubsSub");
  if (clubsSub) {
    const who = filters.ownedOnly ? "Owned clubs" : "Owned and vacant";
    const where = filters.division === "all" ? "in this season" : `in ${divShort(filters.division)}`;
    clubsSub.textContent = `${who} ${where}`;
  }

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

  const verdict =
    Math.abs(gapClub) <= 1000000 ? "near_target" : gapClub > 0 ? "under_target" : "over_target";
  renderVerdict({ ...data, verdict }, { avg, med, target, gapClub, gapTotal, clubs, cats });

  const hint = document.getElementById("finBalHint");
  if (hint) hint.hidden = true;

  const divLabel = (d) => {
    if (d === "superleague") return "Super League";
    if (d === "championship_a") return "Championship A";
    if (d === "championship_b") return "Championship B";
    return d || "Unassigned";
  };
  const divisionOrder = ["superleague", "championship_a", "championship_b"];
  const byDivisionMap = new Map();
  for (const club of matched) {
    const key = club.division || "unassigned";
    if (!byDivisionMap.has(key)) byDivisionMap.set(key, []);
    byDivisionMap.get(key).push(Number(club.ops_net || 0));
  }
  const byDiv = [...byDivisionMap.keys()]
    .sort((a, b) => {
      const ia = divisionOrder.indexOf(a);
      const ib = divisionOrder.indexOf(b);
      return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
    })
    .map((division) => {
      const values = byDivisionMap.get(division);
      const total = values.reduce((sum, n) => sum + n, 0);
      const dAvg = values.length ? total / values.length : 0;
      return {
        division,
        club_count: values.length,
        ops_net_avg: dAvg,
        ops_net_median: medianOf(values),
        gap_vs_target_avg: target - dAvg,
      };
    });
  const divEl = document.getElementById("finBalByDivision");
  if (divEl) {
    if (!byDiv.length) {
      divEl.innerHTML = `<div class="note">No clubs match this division and ownership filter.</div>`;
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
    ["prize_league", "League prize", "League prize money only. Challenges are not included."],
    ["prize_cup", "Cup prize", "Cup prize money only."],
    ["tv", "TV", FIN_BALANCE_TIPS.catTv],
    ["subsidies", "Subsidies", FIN_BALANCE_TIPS.catSubsidies],
    ["wages", "Wages", "Squad wages, 34+ fee, and star tax."],
    ["stadium", "Maintenance", "Stadium maintenance only."],
    ["tax_fines", "Emergency tax", "Admin emergency tax. Income tax on transfers is not included."],
    ["staff", "Manager", "Manager salary only."],
  ];
  const catEl = document.getElementById("finBalCats");
  catEl.innerHTML = catOrder
    .map(
      ([k, label, tip]) =>
        `<div><span class="gpsl-has-tip"${tipDataAttrs(tip)}>${label}</span><b class="${moneyClass(cats[k])}">${formatB(cats[k])}</b></div>`
    )
    .join("");

  const clubRows = [...matched].sort((a, b) => Number(b.ops_net || 0) - Number(a.ops_net || 0));

  const body = document.getElementById("finBalBody");
  body.innerHTML = clubRows
    .map((c) => {
      const cell = (v) =>
        `<td class="${moneyClass(v)}">${formatB(v)}</td>`;
      return `<tr>
        <td>${escapeHtml(c.club || "")}</td>
        <td>${escapeHtml(divShort(c.division))}</td>
        ${cell(c.gates)}
        ${cell(c.prize_league)}
        ${cell(c.prize_cup)}
        ${cell(c.tv)}
        ${cell(c.subsidies)}
        ${cell(c.wages)}
        ${cell(c.stadium)}
        ${cell(c.tax_fines)}
        ${cell(c.staff)}
        ${cell(c.ops_net)}
      </tr>`;
    })
    .join("");

  const sum = (key) => clubRows.reduce((a, c) => a + Number(c[key] || 0), 0);
  const foot = document.getElementById("finBalFoot");
  const fcell = (v) => `<td class="${moneyClass(v)}">${formatB(v)}</td>`;
  foot.innerHTML = `<tr>
    <td>TOTAL</td>
    <td></td>
    ${fcell(sum("gates"))}
    ${fcell(sum("prize_league"))}
    ${fcell(sum("prize_cup"))}
    ${fcell(sum("tv"))}
    ${fcell(sum("subsidies"))}
    ${fcell(sum("wages"))}
    ${fcell(sum("stadium"))}
    ${fcell(sum("tax_fines"))}
    ${fcell(sum("staff"))}
    ${fcell(sum("ops_net"))}
  </tr>`;

  const who = filters.ownedOnly ? "owned" : "all";
  const where = filters.division === "all" ? "all divisions" : divShort(filters.division);
  setStatus(
    "finBalStatus",
    `✅ ${data.season_label || "Season"} — ${clubs} ${who} clubs · ${where}.`,
    true
  );
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

async function runForecast() {
  const btn = document.getElementById("finFcRunBtn");
  btn.disabled = true;
  setStatus("finFcStatus", "Forecasting clubs…");
  try {
    const result = await buildLeagueFinanceForecast(supabase, {
      onProgress: (done, total) =>
        setStatus("finFcStatus", `Forecasting clubs… ${done} / ${total}`),
    });
    forecastRows = result.clubs;
    await markOwnedClubs(forecastRows);
    renderForecast();
    setStatus(
      "finFcStatus",
      `✅ ${result.season.label || "Current season"} preview — ${forecastRows.length} clubs, core lines only.`,
      true
    );
  } catch (err) {
    setStatus("finFcStatus", "❌ " + (err?.message || err), false);
  } finally {
    btn.disabled = false;
  }
}

function renderForecast() {
  if (!forecastRows) return;
  const wrap = document.getElementById("finFcWrap");
  const division = document.getElementById("finFcDivision").value;
  const mode = document.getElementById("finFcMode").value;

  const sections = corePreviewSections();
  const lineIds = sections.flatMap((s) => s.lines.map((l) => l.id));
  const ownedOnly = document.getElementById("finFcOwned")?.value === "owned";
  const rows = forecastRows
    .filter((r) => (division === "all" || r.division === division) && (!ownedOnly || r.owned))
    .map((r) => {
      const vals = r[mode];
      const net = lineIds.reduce((s, id) => s + Number(vals[id] || 0), 0);
      return { ...r, vals, modeNet: net };
    })
    .sort((a, b) => b.modeNet - a.modeNet);

  const netLabel =
    mode === "posted" ? "Core posted" : mode === "pending" ? "Core still to come" : "Core net";

  document.getElementById("finFcHead").innerHTML = `
    <tr class="fc-sections">
      <th colspan="2"></th>
      ${sections
        .map((s) => `<th colspan="${s.lines.length}">${escapeHtml(s.title)}</th>`)
        .join("")}
      <th></th>
    </tr>
    <tr class="fc-lines">
      <th>Club</th>
      <th>Div</th>
      ${sections
        .map((s) =>
          s.lines
            .map(
              (l, i) =>
                `<th class="${i === 0 ? "fc-sec-start" : ""}">${escapeHtml(l.label)}</th>`
            )
            .join("")
        )
        .join("")}
      <th class="fc-sec-start fc-key">${netLabel}</th>
    </tr>`;

  const sectionStarts = new Set(sections.map((s) => s.lines[0].id));
  const cell = (v, cls = "") =>
    `<td class="${[moneyClass(v), cls].filter(Boolean).join(" ")}">${formatB(v)}</td>`;

  document.getElementById("finFcBody").innerHTML = rows
    .map(
      (r) => `<tr title="${escapeHtml(r.clubName)}">
        <td>${escapeHtml(r.club)}</td>
        <td>${escapeHtml(divShort(r.division))}</td>
        ${lineIds
          .map((id) => cell(r.vals[id], sectionStarts.has(id) ? "fc-sec-start" : ""))
          .join("")}
        ${cell(r.modeNet, "fc-sec-start fc-key")}
      </tr>`
    )
    .join("");

  const n = rows.length || 1;
  const sum = (fn) => rows.reduce((s, r) => s + Number(fn(r) || 0), 0);
  const footRow = (label, div) => `<tr>
    <td>${label}</td>
    <td></td>
    ${lineIds
      .map((id) => cell(sum((r) => r.vals[id]) / div, sectionStarts.has(id) ? "fc-sec-start" : ""))
      .join("")}
    ${cell(sum((r) => r.modeNet) / div, "fc-sec-start fc-key")}
  </tr>`;
  document.getElementById("finFcFoot").innerHTML =
    footRow("AVERAGE", n) + footRow("TOTAL", 1);

  wrap.hidden = false;
  const visible = forecastRows.filter(
    (r) => (division === "all" || r.division === division) && (!ownedOnly || r.owned)
  );
  renderPreviewKpis(visible);
  forecastVisibleRows = visible;
  renderTweaks();
}

async function markOwnedClubs(rows) {
  const shorts = [...new Set((rows || []).map((r) => r.club).filter(Boolean))];
  if (!shorts.length) return;
  const { data, error } = await supabase.from("Clubs").select("ShortName, owner_id").in("ShortName", shorts);
  if (error) {
    for (const row of rows) row.owned = true;
    return;
  }
  const owned = new Set((data || []).filter((c) => c.owner_id).map((c) => c.ShortName));
  for (const row of rows) row.owned = owned.has(row.club);
}

function renderPreviewKpis(rows) {
  const el = document.getElementById("finFcKpis");
  if (!el) return;
  if (!rows.length) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }
  const n = rows.length;
  const avgNet = rows.reduce((s, r) => s + coreForecastNet(r), 0) / n;
  const below = rows.filter((r) => coreForecastNet(r) < 0).length;
  const kpi = (label, value, cls, sub) =>
    `<div class="fin-kpi"><span class="lbl">${label}</span><span class="val ${cls}">${value}</span><span class="sub">${sub}</span></div>`;
  el.hidden = false;
  el.innerHTML =
    kpi(
      "Clubs in this preview",
      String(n),
      "",
      document.getElementById("finFcOwned")?.value === "owned"
        ? "Owned clubs in this division filter"
        : "Owned and vacant in this division filter"
    ) +
    kpi("Average core net", formatB(avgNet), moneyClass(avgNet), "Posted plus still to come") +
    kpi(
      "Core net below zero",
      String(below),
      below ? "neg" : "pos",
      "Clubs whose core lines do not cover their costs"
    );
}

function wireTweakControls() {
  const closeEl = document.getElementById("finTwClosePct");
  const capEl = document.getElementById("finTwCapPct");
  const bandEl = document.getElementById("finTwBandPct");
  closeEl.value = tweakSettings.closePct;
  capEl.value = tweakSettings.capPct;
  bandEl.value = tweakSettings.bandPct;

  const onSettings = () => {
    tweakSettings.closePct = Math.max(0, Number(closeEl.value) || 0);
    tweakSettings.capPct = Math.max(1, Number(capEl.value) || 1);
    tweakSettings.bandPct = Math.max(0, Number(bandEl.value) || 0);
    saveTweakSettings();
    renderTweaks();
  };
  [closeEl, capEl, bandEl].forEach((el) => el.addEventListener("input", onSettings));

  document.getElementById("finTwBody").addEventListener("input", (e) => {
    const input = e.target.closest("input.tw-share");
    if (!input) return;
    tweakSettings.shares[input.dataset.lever] = Math.max(0, Number(input.value) || 0);
    saveTweakSettings();
    renderTweaks({ keepFocus: input.dataset.lever });
  });

  document.getElementById("finTwResetBtn").onclick = () => {
    tweakSettings.shares = Object.fromEntries(TWEAK_LEVERS.map((l) => [l.id, l.share]));
    saveTweakSettings();
    renderTweaks();
  };

  document.getElementById("finBalTarget").addEventListener("change", renderTweaks);
}

/**
 * Split the profit fix across levers by share, capping each lever at capPct of
 * its current level and handing any overflow to the uncapped levers.
 */
function allocateTweaks(needed, levers, capPct) {
  const alloc = new Map(levers.map((l) => [l.id, 0]));
  const capped = new Set();
  let remainingNeed = needed;

  for (let pass = 0; pass < levers.length && Math.abs(remainingNeed) > 0.5; pass++) {
    const open = levers.filter((l) => !capped.has(l.id) && l.share > 0 && Math.abs(l.base) > 0.5);
    const shareSum = open.reduce((s, l) => s + l.share, 0);
    if (!open.length || shareSum <= 0) break;

    let spent = 0;
    for (const l of open) {
      const want = alloc.get(l.id) + (remainingNeed * l.share) / shareSum;
      const cap = (Math.abs(l.base) * capPct) / 100;
      if (Math.abs(want) > cap) {
        const clamped = Math.sign(want) * cap;
        spent += clamped - alloc.get(l.id);
        alloc.set(l.id, clamped);
        capped.add(l.id);
      } else {
        spent += want - alloc.get(l.id);
        alloc.set(l.id, want);
      }
    }
    remainingNeed -= spent;
  }
  return { alloc, capped, unallocated: remainingNeed };
}

function renderTweaks({ keepFocus = null } = {}) {
  const wrap = document.getElementById("finTwWrap");
  const rows = forecastVisibleRows;
  if (!rows.length) {
    wrap.hidden = true;
    return;
  }
  wrap.hidden = false;

  const target = parseMoney(document.getElementById("finBalTarget").value);
  const goal = Number.isFinite(target) ? target : 0;
  const clubs = rows.length;
  const avgNet = rows.reduce((s, r) => s + coreForecastNet(r), 0) / clubs;
  const gapPerClub = goal - avgNet;
  const band = (Math.abs(goal) * tweakSettings.bandPct) / 100;
  const onTarget = Math.abs(gapPerClub) <= band;
  const needed = onTarget ? 0 : gapPerClub * clubs * (tweakSettings.closePct / 100);

  const levers = TWEAK_LEVERS.map((l) => ({
    ...l,
    share: Number(tweakSettings.shares[l.id] ?? 0),
    base: rows.reduce(
      (s, r) => s + l.lines.reduce((a, id) => a + Number(r.forecast[id] || 0), 0),
      0
    ),
  }));
  const { alloc, capped, unallocated } = allocateTweaks(
    needed,
    levers,
    tweakSettings.capPct
  );

  const summary = document.getElementById("finTwSummary");
  const direction = gapPerClub > 0 ? "shortfall" : "surplus";
  if (onTarget) {
    summary.innerHTML =
      `Average forecast net ${formatB(avgNet)} vs goal ${formatB(goal)} — within the ` +
      `±${tweakSettings.bandPct}% dead band (${formatB(band)}). <b>No tweaks needed.</b>`;
  } else {
    summary.innerHTML =
      `Average forecast net <b>${formatB(avgNet)}</b> vs goal <b>${formatB(goal)}</b> — ` +
      `${direction} of <b>${formatB(Math.abs(gapPerClub))}</b> per club across ${clubs} clubs. ` +
      `Closing ${tweakSettings.closePct}% means moving league profit by ` +
      `<b>${needed >= 0 ? "+" : "−"}${formatB(Math.abs(needed))}</b>` +
      (gapPerClub > 0
        ? " (raise income / cut costs)."
        : " (trim income / raise costs).") +
      (Math.abs(unallocated) > 0.5
        ? ` <span class="neg">${formatB(Math.abs(unallocated))} could not be allocated within the ${tweakSettings.capPct}% cap — raise the cap or add shares.</span>`
        : "") +
      ` Every line with a forecast is already inside that average, including amounts still to come. A share of 0 keeps the forecast and does not move the line.`;
  }

  const pct = (n) => `${n >= 0 ? "+" : "−"}${Math.abs(n).toFixed(1)}%`;
  const body = document.getElementById("finTwBody");
  body.innerHTML = levers
    .map((l) => {
      const effect = alloc.get(l.id) || 0;
      const isIncome = l.base >= 0;
      // Income: level moves with the effect. Cost (negative base): cutting cost adds profit.
      const newLevel = l.base + effect;
      const changePct = Math.abs(l.base) > 0.5 ? (effect / Math.abs(l.base)) * 100 : 0;
      const levelPct = isIncome ? changePct : -changePct;
      const held = l.share <= 0 && Math.abs(l.base) > 0.5;
      const off = Math.abs(l.base) < 0.5;
      const cls = [off ? "tw-off" : "", capped.has(l.id) ? "tw-capped" : ""]
        .filter(Boolean)
        .join(" ");
      const changeTxt = off
        ? "—"
        : held
          ? "Counted, not moved"
          : Math.abs(effect) < 0.5
            ? "—"
            : `${pct(levelPct)} ${isIncome ? (levelPct >= 0 ? "raise" : "cut") : levelPct >= 0 ? "cost up" : "cost down"}${capped.has(l.id) ? " (cap)" : ""}`;
      return `<tr class="${cls}">
        <td>${escapeHtml(l.label)}</td>
        <td><input type="number" class="tw-share" data-lever="${l.id}" min="0" step="5" value="${l.share}"></td>
        <td class="${moneyClass(l.base)}">${formatB(l.base)}</td>
        <td>${changeTxt}</td>
        <td class="${moneyClass(held ? l.base : newLevel)}">${off ? "—" : formatB(held ? l.base : newLevel)}</td>
        <td class="${moneyClass(effect)}">${off ? "—" : formatB(effect)}</td>
        <td class="${moneyClass(effect)}">${off ? "—" : formatB(effect / clubs)}</td>
        <td><a href="${l.href}" style="color:#ff9900;">${escapeHtml(l.where)}</a></td>
      </tr>`;
    })
    .join("");

  const totalEffect = [...alloc.values()].reduce((s, v) => s + v, 0);
  const newAvg = avgNet + totalEffect / clubs;
  document.getElementById("finTwFoot").innerHTML = `<tr>
    <td>TOTAL</td>
    <td>${levers.reduce((s, l) => s + (l.share > 0 ? l.share : 0), 0)}</td>
    <td></td><td></td><td></td>
    <td class="${moneyClass(totalEffect)}">${formatB(totalEffect)}</td>
    <td class="${moneyClass(totalEffect)}">${formatB(totalEffect / clubs)}</td>
    <td>New average net ≈ <b class="${moneyClass(newAvg)}">${formatB(newAvg)}</b></td>
  </tr>`;

  if (keepFocus) {
    const el = body.querySelector(`input.tw-share[data-lever="${keepFocus}"]`);
    if (el) {
      el.focus();
      const len = String(el.value).length;
      try {
        el.setSelectionRange(len, len);
      } catch {
        /* number inputs may not support selection */
      }
    }
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
