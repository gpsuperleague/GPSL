import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { loadNationPlayerPoolReport, renderNationFlag, NATIONAL_SQUAD_MIN_GK } from "./international.js";

const POOL_MIN_PLAYERS = 24;

const SECTIONS = [
  { key: "all", label: "All players" },
  { key: "le_65", label: "≤65" },
  { key: "r66_69", label: "66–69" },
  { key: "r70_72", label: "70–72" },
  { key: "r73_75", label: "73–75" },
  { key: "r76_78", label: "76–78" },
  { key: "r79_plus", label: "79+" },
  { key: "u21", label: "U21 (≤21)" },
];

const SUMMARY_BANDS = ["le_65", "r66_69", "r70_72", "r73_75", "r76_78", "r79_plus"];

let reportRows = [];
let expandedCode = null;

function section(row, key) {
  return row?.pool?.[key] || { total: 0, gk: 0, def: 0, mid: 0, fwd: 0 };
}

function poolStatus(row) {
  const all = section(row, "all");
  if (all.total === 0) return { key: "bad", label: "No GPDB match" };
  if (all.total >= POOL_MIN_PLAYERS && all.gk >= NATIONAL_SQUAD_MIN_GK) {
    return { key: "ok", label: "OK" };
  }
  if (all.total >= 23 && all.gk >= NATIONAL_SQUAD_MIN_GK) {
    return { key: "warn", label: "Tight" };
  }
  return { key: "bad", label: "Short" };
}

function countCell(n) {
  const v = Number(n) || 0;
  return `<span class="${v ? "" : "pool-zero"}">${v}</span>`;
}

function detailTable(row) {
  const body = SECTIONS.map(({ key, label }) => {
    const s = section(row, key);
    return `
      <tr>
        <td>${label}</td>
        <td>${countCell(s.total)}</td>
        <td>${countCell(s.gk)}</td>
        <td>${countCell(s.def)}</td>
        <td>${countCell(s.mid)}</td>
        <td>${countCell(s.fwd)}</td>
      </tr>`;
  }).join("");

  return `
    <div class="pool-detail-inner">
      <table class="pool-detail-table">
        <thead>
          <tr>
            <th>Section</th>
            <th>Total</th>
            <th>GK</th>
            <th>DEF</th>
            <th>MID</th>
            <th>FWD</th>
          </tr>
        </thead>
        <tbody>${body}</tbody>
      </table>
    </div>`;
}

function renderSummary(rows) {
  const el = document.getElementById("poolSummary");
  if (!el) return;

  const ok = rows.filter((r) => poolStatus(r).key === "ok").length;
  const short = rows.filter((r) => poolStatus(r).key === "bad").length;
  const tight = rows.filter((r) => poolStatus(r).key === "warn").length;
  const unassigned = rows.filter((r) => !r.is_taken).length;

  el.innerHTML = `
    <div class="pool-chip"><b>${rows.length}</b> selectable nations</div>
    <div class="pool-chip"><b>${ok}</b> pool OK (≥${POOL_MIN_PLAYERS}, ≥${NATIONAL_SQUAD_MIN_GK} GK)</div>
    <div class="pool-chip"><b>${tight}</b> tight</div>
    <div class="pool-chip"><b>${short}</b> short / empty</div>
    <div class="pool-chip"><b>${unassigned}</b> unassigned</div>
  `;
}

function filterRows(rows) {
  const filter = document.getElementById("poolFilter")?.value || "all";
  const q = (document.getElementById("poolSearch")?.value || "").trim().toLowerCase();

  return rows.filter((row) => {
    const status = poolStatus(row);
    const all = section(row, "all");

    if (filter === "short" && status.key === "ok") return false;
    if (filter === "empty" && all.total !== 0) return false;
    if (filter === "unassigned" && row.is_taken) return false;
    if (filter === "assigned" && !row.is_taken) return false;

    if (q) {
      const hay = [
        row.nation_code,
        row.nation_name,
        row.owner_club,
        row.owner_tag,
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      if (!hay.includes(q)) return false;
    }

    return true;
  });
}

function sortRows(rows) {
  const sort = document.getElementById("poolSort")?.value || "seed";
  const copy = [...rows];

  copy.sort((a, b) => {
    if (sort === "name") {
      return String(a.nation_name).localeCompare(String(b.nation_name));
    }
    if (sort === "total_desc") {
      return section(b, "all").total - section(a, "all").total;
    }
    if (sort === "total_asc") {
      return section(a, "all").total - section(b, "all").total;
    }
    return (a.seed_rank || 999) - (b.seed_rank || 999);
  });

  return copy;
}

function renderTable() {
  const tbody = document.getElementById("poolBody");
  if (!tbody) return;

  const visible = sortRows(filterRows(reportRows));
  renderSummary(reportRows);

  if (!visible.length) {
    tbody.innerHTML =
      '<tr><td colspan="11" style="padding:20px;color:#888;">No nations match this filter.</td></tr>';
    return;
  }

  tbody.innerHTML = visible
    .map((row) => {
      const all = section(row, "all");
      const u21 = section(row, "u21");
      const status = poolStatus(row);
      const isOpen = expandedCode === row.nation_code;
      const ownerLine = row.is_taken
        ? `<span class="pool-owner">${row.owner_tag || row.owner_club || "Assigned"}</span>`
        : `<span class="pool-owner">Unassigned</span>`;

      const bandCells = SUMMARY_BANDS.map((key) =>
        countCell(section(row, key).total)
      ).join("");

      const mainRow = `
        <tr data-code="${row.nation_code}">
          <td class="pool-sticky">
            <div class="pool-nation-cell">
              ${renderNationFlag({ nation_code: row.nation_code, nation_name: row.nation_name }, "sm")}
              <span>
                <strong>${row.nation_name}</strong>
                <span class="pool-owner">${row.nation_code} · seed ${row.seed_rank}</span>
                ${ownerLine}
              </span>
              <button type="button" class="pool-expand-btn" data-expand="${row.nation_code}">
                ${isOpen ? "Hide" : "Breakdown"}
              </button>
            </div>
          </td>
          <td>${countCell(all.total)}</td>
          <td>${countCell(u21.total)}</td>
          ${bandCells}
          <td>${countCell(all.gk)}</td>
          <td class="pool-status-${status.key}">${status.label}</td>
        </tr>`;

      const detailRow = isOpen
        ? `<tr class="pool-detail-row"><td colspan="11">${detailTable(row)}</td></tr>`
        : "";

      return mainRow + detailRow;
    })
    .join("");
}

async function loadReport() {
  reportRows = await loadNationPlayerPoolReport(supabase);
}

function wireControls() {
  for (const id of ["poolSort", "poolFilter"]) {
    document.getElementById(id)?.addEventListener("change", renderTable);
  }
  document.getElementById("poolSearch")?.addEventListener("input", renderTable);

  document.getElementById("poolBody")?.addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-expand]");
    if (!btn) return;
    const code = btn.getAttribute("data-expand");
    expandedCode = expandedCode === code ? null : code;
    renderTable();
  });
}

async function main() {
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return;
  }

  if (!isGpslAdminUser(user)) {
    window.location = "dashboard.html";
    return;
  }

  await initGlobal();

  const errEl = document.getElementById("poolError");
  try {
    await loadReport();
    if (errEl) errEl.hidden = true;
    wireControls();
    renderTable();
  } catch (err) {
    console.error("nation_player_pool:", err);
    if (errEl) {
      errEl.hidden = false;
      errEl.textContent =
        err.message ||
        "Could not load nation pool report. Run supabase/sql/patches/international_nation_player_pool.sql in Supabase.";
    }
  }
}

main();
