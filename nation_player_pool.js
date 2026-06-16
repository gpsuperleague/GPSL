import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import {
  loadNationPlayerPoolReport,
  loadNationPlayerPoolCacheMeta,
  refreshNationPlayerPoolCache,
  renderNationFlag,
  NATIONAL_SQUAD_MIN_GK,
  NATION_HEALTHY_CLUB_REQUIREMENTS,
  nationPoolSection,
  nationPoolStatus,
  nationHealthyClubCapacity,
  nationPoolIsFaint,
} from "./international.js";

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
let cacheMeta = null;

function formatCacheAge(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

function renderCacheMeta() {
  const el = document.getElementById("poolCacheMeta");
  const btn = document.getElementById("poolRefreshCacheBtn");
  if (!el) return;

  if (!cacheMeta?.cache_ready) {
    el.hidden = false;
    el.style.color = "#f88";
    el.textContent =
      "GPDB pool counts are not cached yet — page loads may time out. An admin must refresh the pool cache.";
    if (btn) btn.hidden = !btn.dataset.admin;
    return;
  }

  const when = formatCacheAge(cacheMeta.refreshed_at);
  el.hidden = false;
  el.style.color = "#999";
  el.textContent = when
    ? `GPDB counts as of ${when} (${cacheMeta.nation_count ?? "?"} nations). Owner/club columns are live.`
    : "GPDB pool cache ready.";
  if (btn) btn.hidden = !btn.dataset.admin;
}

function section(row, key) {
  return nationPoolSection(row, key);
}

function poolStatus(row) {
  return nationPoolStatus(row);
}

function healthyClubCapacity(row) {
  return nationHealthyClubCapacity(row);
}

const HEALTHY_CLUB_REQUIREMENTS = NATION_HEALTHY_CLUB_REQUIREMENTS;

function ownedClubCount(row) {
  return Number(row?.owned_clubs_count ?? 0);
}

function ownedClubsCell(row) {
  const owned = ownedClubCount(row);
  const healthy = healthyClubCapacity(row);
  const cls =
    owned === 0
      ? ""
      : owned <= healthy
        ? "pool-clubs-ok"
        : "pool-clubs-over";
  return `<span class="${cls}">${owned}</span>`;
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

function fitNationColumn() {
  const table = document.getElementById("poolTable");
  if (!table || !reportRows.length) return;

  const probe = document.createElement("div");
  probe.className = "pool-nation-meta";
  probe.style.cssText =
    "position:absolute;left:-9999px;top:0;visibility:hidden;pointer-events:none;font-size:12px;font-family:Arial,sans-serif";
  document.body.appendChild(probe);

  let maxMeta = 0;
  for (const row of reportRows) {
    probe.replaceChildren();
    const name = document.createElement("strong");
    name.className = "pool-nation-name";
    name.textContent = row.nation_name || "";
    const seed = document.createElement("span");
    seed.className = "pool-owner";
    seed.textContent = `${row.nation_code} · seed ${row.seed_rank}`;
    const owner = document.createElement("span");
    owner.className = "pool-owner";
    owner.textContent = row.is_taken
      ? row.owner_tag || row.owner_club || "Assigned"
      : "Unassigned";
    probe.append(name, seed, owner);
    maxMeta = Math.max(maxMeta, probe.scrollWidth);
  }
  probe.remove();

  const btn = document.querySelector("#poolBody .pool-expand-btn");
  const btnW = btn ? btn.offsetWidth : 76;
  const colW = Math.ceil(maxMeta + 28 + 6 + 8 + btnW + 16);
  table.style.setProperty("--pool-nation-col-width", `${colW}px`);
}

function renderTable() {
  const tbody = document.getElementById("poolBody");
  if (!tbody) return;

  const visible = sortRows(filterRows(reportRows));
  renderSummary(reportRows);

  if (!visible.length) {
    tbody.innerHTML =
      '<tr><td colspan="13" style="padding:20px;color:#888;">No nations match this filter.</td></tr>';
    return;
  }

  tbody.innerHTML = visible
    .map((row) => {
      const all = section(row, "all");
      const u21 = section(row, "u21");
      const status = poolStatus(row);
      const healthy = healthyClubCapacity(row);
      const faint = nationPoolIsFaint(row);
      const isOpen = expandedCode === row.nation_code;
      const ownerLine = row.is_taken
        ? `<span class="pool-owner">${row.owner_tag || row.owner_club || "Assigned"}</span>`
        : `<span class="pool-owner">Unassigned</span>`;

      const bandCells = SUMMARY_BANDS.map(
        (key) => `<td>${countCell(section(row, key).total)}</td>`
      ).join("");

      const mainRow = `
        <tr data-code="${row.nation_code}" class="${faint ? "pool-row-faint" : ""}">
          <td class="pool-sticky">
            <div class="pool-nation-cell">
              ${renderNationFlag({ nation_code: row.nation_code, nation_name: row.nation_name }, "sm")}
              <span class="pool-nation-meta">
                <strong class="pool-nation-name">${row.nation_name}</strong>
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
          <td title="${HEALTHY_CLUB_REQUIREMENTS.map((r) => `${r.min}× ${r.label}`).join(", ")}">${countCell(healthy)}</td>
          <td>${ownedClubsCell(row)}</td>
          <td class="pool-status-${status.key}">${status.label}</td>
        </tr>`;

      const detailRow = isOpen
        ? `<tr class="pool-detail-row"><td colspan="13">${detailTable(row)}</td></tr>`
        : "";

      return mainRow + detailRow;
    })
    .join("");

  requestAnimationFrame(fitNationColumn);
}

async function loadReport() {
  const loading = document.getElementById("poolLoading");
  const wrap = document.getElementById("poolTableWrap");
  if (loading) loading.hidden = false;
  if (wrap) wrap.hidden = true;

  const [rows, meta] = await Promise.all([
    loadNationPlayerPoolReport(supabase),
    loadNationPlayerPoolCacheMeta(supabase),
  ]);
  reportRows = rows;
  cacheMeta = meta;
  renderCacheMeta();

  if (loading) loading.hidden = true;
  if (wrap) wrap.hidden = false;
}

async function runCacheRefresh() {
  const btn = document.getElementById("poolRefreshCacheBtn");
  const errEl = document.getElementById("poolError");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Refreshing cache…";
  }
  if (errEl) errEl.hidden = true;

  try {
    const result = await refreshNationPlayerPoolCache(supabase);
    cacheMeta = {
      cache_ready: true,
      refreshed_at: result?.refreshed_at ?? new Date().toISOString(),
      nation_count: result?.nations_cached ?? null,
    };
    renderCacheMeta();
    await loadReport();
    renderTable();
  } catch (err) {
    console.error("pool cache refresh:", err);
    if (errEl) {
      errEl.hidden = false;
      errEl.textContent =
        err.message ||
        "Pool cache refresh failed (admin only, may take up to 2 minutes).";
    }
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Refresh pool cache (admin)";
    }
  }
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

  document.getElementById("poolRefreshCacheBtn")?.addEventListener("click", () => {
    if (
      !confirm(
        "Rescan all GPDB players into the nation pool cache?\n\nTakes ~30–90 seconds. Run after GPDB import or nation sync."
      )
    ) {
      return;
    }
    runCacheRefresh();
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

  await initGlobal();

  const refreshBtn = document.getElementById("poolRefreshCacheBtn");
  if (refreshBtn && isGpslAdminUser(user)) {
    refreshBtn.dataset.admin = "1";
  }

  const errEl = document.getElementById("poolError");
  try {
    await loadReport();
    if (errEl) errEl.hidden = true;
    wireControls();
    renderTable();
  } catch (err) {
    console.error("nation_player_pool:", err);
    const loading = document.getElementById("poolLoading");
    if (loading) loading.hidden = true;
    if (errEl) {
      errEl.hidden = false;
      errEl.textContent =
        err.message ||
        "Could not load nation pool report. Re-run supabase/sql/patches/international_nation_player_pool.sql in Supabase, then SELECT international_refresh_nation_player_pool_cache(); as admin.";
    }
  }
}

main();
