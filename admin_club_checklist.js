import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import { loadFinanceSeasonContext } from "./finance_page_common.js";

primeAdminPageChrome();

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
let sortKey = "club_name";
let sortDir = "asc";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("reloadBtn").onclick = () => loadTable();
  document.getElementById("filterOwner").onchange = renderTable;
  document.getElementById("filterDivision").onchange = renderTable;

  await loadTable();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function compareValues(a, b, key) {
  const va = a?.[key];
  const vb = b?.[key];

  if (key === "current_balance" || key === "projected_eos_balance" || key === "total_wages") {
    const na = Number(va);
    const nb = Number(vb);
    if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb;
  }

  if (
    key === "squad_size" ||
    key === "star_count" ||
    key === "contract_releases_remaining" ||
    key === "foreign_sales_remaining" ||
    key === "fines_count" ||
    key === "u21_count" ||
    key === "manager_rating"
  ) {
    const na = Number(va);
    const nb = Number(vb);
    if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb;
  }

  return String(va ?? "").localeCompare(String(vb ?? ""), undefined, { sensitivity: "base" });
}

function filteredRows() {
  const ownerFilter = document.getElementById("filterOwner")?.value || "";
  const divisionFilter = document.getElementById("filterDivision")?.value || "";

  return allRows.filter((row) => {
    const hasOwner = Boolean(row.owner_tag || row.owner_email);
    if (ownerFilter === "owned" && !hasOwner) return false;
    if (ownerFilter === "vacant" && hasOwner) return false;

    const div = row.division || "unassigned";
    if (divisionFilter && div !== divisionFilter) return false;

    return true;
  });
}

function sortedRows(rows) {
  const sorted = [...rows];
  sorted.sort((a, b) => {
    const cmp = compareValues(a, b, sortKey);
    return sortDir === "asc" ? cmp : -cmp;
  });
  return sorted;
}

function renderSummary(rows) {
  const el = document.getElementById("summaryStrip");
  if (!el) return;

  let owned = 0;
  let vacant = 0;
  let under24 = 0;
  let negative = 0;

  for (const row of rows) {
    if (row.owner_tag || row.owner_email) owned += 1;
    else vacant += 1;
    if (Number(row.squad_size) < 24) under24 += 1;
    if (Number(row.current_balance) < 0) negative += 1;
  }

  el.innerHTML = `
    <span><b>${rows.length}</b> clubs</span>
    <span>${owned} owned · ${vacant} vacant</span>
    <span>${under24} below 24 squad</span>
    <span>${negative} negative balance</span>
  `;
}

function moneyCell(value, { warnBelow = null, badBelow = null } = {}) {
  if (value === undefined) {
    return '<td class="money proj-loading">…</td>';
  }
  if (value == null || value === "" || Number.isNaN(Number(value))) {
    return '<td class="money vacant">—</td>';
  }
  const n = Number(value);
  let cls = "money";
  if (badBelow != null && n < badBelow) cls += " bad";
  else if (warnBelow != null && n < warnBelow) cls += " warn";
  return `<td class="${cls}">${formatMoney(n)}</td>`;
}

function numCell(value, { warnBelow = null, badBelow = null } = {}) {
  const n = Number(value ?? 0);
  let cls = "num";
  if (badBelow != null && n < badBelow) cls += " bad";
  else if (warnBelow != null && n < warnBelow) cls += " warn";
  return `<td class="${cls}">${n}</td>`;
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  const countEl = document.getElementById("rowCount");
  if (!wrap) return;

  const rows = sortedRows(filteredRows());
  renderSummary(allRows);

  if (countEl) {
    countEl.textContent =
      rows.length === allRows.length
        ? `Showing all ${rows.length}`
        : `Showing ${rows.length} of ${allRows.length}`;
  }

  if (!rows.length) {
    wrap.innerHTML = '<p class="note">No clubs match this filter.</p>';
    return;
  }

  const headers = [
    ["owner_tag", "Owner"],
    ["club_name", "Club"],
    ["manager_name", "Manager"],
    ["ooo_player_name", "OooO"],
    ["squad_size", "Squad"],
    ["star_count", "Stars"],
    ["current_balance", "Balance"],
    ["projected_eos_balance", "Proj. EOS"],
    ["total_wages", "Wages"],
    ["contract_releases_remaining", "Releases"],
    ["foreign_sales_remaining", "Foreign"],
    ["fines_count", "Fines"],
    ["u21_count", "U21"],
  ];

  wrap.innerHTML = `
    <table class="chk-table">
      <thead>
        <tr>
          ${headers
            .map(([key, label]) => {
              const sorted =
                sortKey === key ? ` sorted-${sortDir === "asc" ? "asc" : "desc"}` : "";
              return `<th data-sort="${key}" class="${sorted.trim()}">${label}</th>`;
            })
            .join("")}
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const owner = row.owner_tag || row.owner_email;
            const ownerHtml = owner
              ? escapeHtml(owner)
              : '<span class="vacant">Vacant</span>';
            const manager = row.manager_name
              ? `${escapeHtml(row.manager_name)}${
                  row.manager_rating != null ? ` (${row.manager_rating})` : ""
                }`
              : '<span class="vacant">—</span>';
            const ooo = row.ooo_player_name
              ? escapeHtml(row.ooo_player_name)
              : '<span class="vacant">—</span>';

            return `
          <tr data-club="${escapeHtml(row.club_short_name)}">
            <td>${ownerHtml}</td>
            <td class="club-cell">
              <div class="club-name">${escapeHtml(row.club_name || row.club_short_name)}</div>
              <div class="club-short">${escapeHtml(row.club_short_name)}${
                row.division ? ` · ${escapeHtml(row.division)}` : ""
              }</div>
            </td>
            <td>${manager}</td>
            <td>${ooo}</td>
            ${numCell(row.squad_size, { warnBelow: 24 })}
            ${numCell(row.star_count)}
            ${moneyCell(row.current_balance, { warnBelow: 0 })}
            ${moneyCell(row.projected_eos_balance, { warnBelow: 0 })}
            ${moneyCell(row.total_wages)}
            ${numCell(row.contract_releases_remaining)}
            ${numCell(row.foreign_sales_remaining)}
            ${numCell(row.fines_count, { warnBelow: 1 })}
            ${numCell(row.u21_count, { warnBelow: 5 })}
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  wrap.querySelectorAll("th[data-sort]").forEach((th) => {
    th.onclick = () => {
      const key = th.getAttribute("data-sort");
      if (!key) return;
      if (sortKey === key) {
        sortDir = sortDir === "asc" ? "desc" : "asc";
      } else {
        sortKey = key;
        sortDir = "asc";
      }
      renderTable();
    };
  });
}

async function enrichProjectedBalances(rows) {
  const concurrency = 6;
  let index = 0;
  let renderTimer = null;

  function scheduleRender() {
    if (renderTimer) return;
    renderTimer = setTimeout(() => {
      renderTimer = null;
      renderTable();
    }, 250);
  }

  async function worker() {
    while (index < rows.length) {
      const i = index++;
      const row = rows[i];
      const club = row.club_short_name;
      if (!club) continue;

      try {
        const ctx = await loadFinanceSeasonContext(supabase, club);
        row.projected_eos_balance = ctx.projectedBalance;
      } catch (err) {
        console.warn("projected balance", club, err);
        row.projected_eos_balance = null;
      }

      scheduleRender();
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  if (renderTimer) clearTimeout(renderTimer);
  renderTable();
}

async function loadTable() {
  setStatus("pageStatus", "Loading checklist…");
  const wrap = document.getElementById("tableWrap");
  if (wrap) wrap.innerHTML = '<p class="note">Loading…</p>';

  const { data, error } = await supabase.rpc("admin_club_season_checklist");

  if (error) {
    const msg = [error.message, error.hint].filter(Boolean).join(" — ");
    setStatus(
      "pageStatus",
      `❌ ${msg}. Run supabase/sql/patches/admin_club_season_checklist.sql in Supabase.`,
      false
    );
    if (wrap) wrap.innerHTML = `<p class="note">${escapeHtml(msg)}</p>`;
    return;
  }

  allRows = (data || []).map((row) => ({
    ...row,
    projected_eos_balance: undefined,
  }));

  renderTable();
  setStatus("pageStatus", `Loaded ${allRows.length} clubs — projecting balances…`);

  await enrichProjectedBalances(allRows);
  setStatus("pageStatus", `✅ ${allRows.length} clubs loaded.`);
}
