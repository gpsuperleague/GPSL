import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadSeasons();
  document.getElementById("finBalRunBtn").onclick = runAnalysis;
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
        " — deploy supabase/sql/patches/admin_league_finance_balance.sql",
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

function renderReport(data) {
  const summary = document.getElementById("finBalSummary");
  summary.hidden = false;

  const setKpi = (id, val, cls) => {
    const el = document.getElementById(id);
    el.textContent = val;
    el.className = "val" + (cls ? " " + cls : "");
  };

  setKpi("kpiClubs", String(data.club_count ?? 0));
  setKpi("kpiAvg", formatB(data.ops_net_avg), moneyClass(data.ops_net_avg));
  setKpi("kpiMed", formatB(data.ops_net_median), moneyClass(data.ops_net_median));
  setKpi("kpiTarget", formatB(data.target_avg_ops_profit));
  setKpi("kpiGapClub", formatB(data.gap_vs_target_avg), moneyClass(-data.gap_vs_target_avg));
  setKpi("kpiGapTotal", formatB(data.gap_vs_target_total), moneyClass(-data.gap_vs_target_total));

  document.getElementById("finBalHint").textContent = data.tuning_hint || "";

  const cats = data.category_totals || {};
  const catOrder = [
    ["gates", "Gates"],
    ["prizes", "Prizes"],
    ["tv", "TV"],
    ["subsidies", "Subsidies"],
    ["wages", "Wages"],
    ["stadium", "Stadium"],
    ["tax_fines", "Tax / fines"],
    ["staff", "Staff"],
    ["eos", "EOS"],
    ["admin_adj", "Admin adj."],
    ["other_ops", "Other ops"],
    ["transfers", "Transfers (excl.)"],
    ["loans", "Loans (excl.)"],
  ];
  const catEl = document.getElementById("finBalCats");
  catEl.innerHTML = catOrder
    .map(
      ([k, label]) =>
        `<div><span>${label}</span><b class="${moneyClass(cats[k])}">${formatB(cats[k])}</b></div>`
    )
    .join("");

  const clubs = Array.isArray(data.clubs) ? [...data.clubs] : [];
  clubs.sort((a, b) => Number(b.ops_net || 0) - Number(a.ops_net || 0));

  const body = document.getElementById("finBalBody");
  body.innerHTML = clubs
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

  const sum = (key) => clubs.reduce((a, c) => a + Number(c[key] || 0), 0);
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

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
