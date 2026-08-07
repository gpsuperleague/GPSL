import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";

const COLUMNS = [
  { key: "club_name", label: "Club", sort: "club_name" },
  { key: "stadium_name", label: "Stadium", sort: "stadium_name" },
  { key: "stadium_capacity", label: "Capacity", sort: "stadium_capacity" },
  { key: "stadium_max_capacity", label: "Max capacity", sort: "stadium_max_capacity" },
  { key: "stadium_expansion_potential", label: "Expansion headroom", sort: "stadium_expansion_potential" },
  { key: "club_expectation", label: "Expectation", sort: "club_expectation" },
  { key: "club_market_value", label: "Squad MV", sort: "club_market_value" },
  { key: "stadium_value", label: "Stadium value", sort: "stadium_value" },
  { key: "stadium_maintenance_cost", label: "Stadium maintenance", sort: "stadium_maintenance_cost" },
  { key: "gate_money_full", label: "Gate 100%", sort: "gate_money_full" },
  { key: "gate_money_80", label: "Gate 80%", sort: "gate_money_80" },
  { key: "nation", label: "Nation", sort: "nation" },
  { key: "owner_tag", label: "Owner", sort: "owner_tag" },
  { key: "prestige_rank", label: "Prestige", sort: "prestige_rank" },
];

let allRows = [];
let sortKey = "prestige_rank";
let sortDir = "asc";
let page = 1;
let pageSize = 100;

function setStatus(msg) {
  const el = document.getElementById("statusNote");
  if (el) el.textContent = msg || "";
}

function setError(msg) {
  const el = document.getElementById("cdbError");
  if (el) el.textContent = msg || "";
}

function moneyCell(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `<span class="money">${formatMoney(v)}</span>`;
}

function buildHead() {
  const head = document.getElementById("tableHead");
  if (!head) return;
  head.innerHTML =
    "<tr>" +
    COLUMNS.map((c) => {
      const cls =
        sortKey === c.sort ? (sortDir === "asc" ? "sort-asc" : "sort-desc") : "";
      return `<th class="${cls}" data-sort="${c.sort}">${c.label}</th>`;
    }).join("") +
    "</tr>";
  head.querySelectorAll("th[data-sort]").forEach((th) => {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (sortKey === key) sortDir = sortDir === "asc" ? "desc" : "asc";
      else {
        sortKey = key;
        sortDir = key === "club_name" || key === "stadium_name" || key === "nation" || key === "owner_tag"
          ? "asc"
          : "asc";
      }
      page = 1;
      render();
    });
  });
}

function filteredRows() {
  const q = String(document.getElementById("filterSearch")?.value || "")
    .trim()
    .toLowerCase();
  const nation = document.getElementById("filterNation")?.value || "";
  return allRows.filter((r) => {
    if (nation && String(r.nation || "") !== nation) return false;
    if (!q) return true;
    const hay = [
      r.club_name,
      r.club_short_name,
      r.stadium_name,
      r.nation,
      r.owner_tag,
      r.manager_name,
    ]
      .map((x) => String(x || "").toLowerCase())
      .join(" ");
    return hay.includes(q);
  });
}

function sortedRows(rows) {
  const dir = sortDir === "desc" ? -1 : 1;
  const key = sortKey;
  return [...rows].sort((a, b) => {
    const av = a[key];
    const bv = b[key];
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    if (typeof av === "number" || typeof bv === "number") {
      return (Number(av) - Number(bv)) * dir;
    }
    return String(av).localeCompare(String(bv), undefined, { sensitivity: "base" }) * dir;
  });
}

function render() {
  buildHead();
  const rows = sortedRows(filteredRows());
  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (page > pages) page = pages;
  const start = (page - 1) * pageSize;
  const slice = rows.slice(start, start + pageSize);

  const body = document.getElementById("tableBody");
  if (!body) return;
  body.innerHTML = slice
    .map((r) => {
      const clubHref = `club.html?club=${encodeURIComponent(r.club_short_name || "")}`;
      return `<tr>
        <td class="left"><a class="club-link" href="${clubHref}">${escapeHtml(r.club_name || r.club_short_name)}</a></td>
        <td class="left">${escapeHtml(r.stadium_name || "—")}</td>
        <td>${fmtInt(r.stadium_capacity)}</td>
        <td>${fmtInt(r.stadium_max_capacity)}</td>
        <td>${fmtInt(r.stadium_expansion_potential)}</td>
        <td>${r.club_expectation != null ? escapeHtml(String(r.club_expectation)) : "—"}</td>
        <td title="Sum of contracted players’ market values">${moneyCell(r.club_market_value)}</td>
        <td title="Capacity × ₿1,500">${moneyCell(r.stadium_value)}</td>
        <td>${moneyCell(r.stadium_maintenance_cost)}</td>
        <td>${moneyCell(r.gate_money_full)}</td>
        <td>${moneyCell(r.gate_money_80)}</td>
        <td>${escapeHtml(r.nation || "—")}</td>
        <td>${escapeHtml(r.owner_tag || "—")}</td>
        <td>${r.prestige_rank != null ? escapeHtml(String(r.prestige_rank)) : "—"}</td>
      </tr>`;
    })
    .join("");

  setStatus(`${total} clubs · page ${page}/${pages}`);

  const pager = document.getElementById("pager");
  if (pager) {
    pager.innerHTML = `
      <button type="button" class="button gpsl-view-ok" id="prevPage" ${page <= 1 ? "disabled" : ""}>Prev</button>
      <button type="button" class="button gpsl-view-ok" id="nextPage" ${page >= pages ? "disabled" : ""}>Next</button>
    `;
    document.getElementById("prevPage")?.addEventListener("click", () => {
      page -= 1;
      render();
    });
    document.getElementById("nextPage")?.addEventListener("click", () => {
      page += 1;
      render();
    });
  }
}

function fmtInt(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return Math.round(v).toLocaleString("en-GB");
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function fillNationFilter() {
  const sel = document.getElementById("filterNation");
  if (!sel) return;
  const nations = [...new Set(allRows.map((r) => r.nation).filter(Boolean))].sort((a, b) =>
    a.localeCompare(b)
  );
  const cur = sel.value;
  sel.innerHTML =
    `<option value="">All</option>` +
    nations.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join("");
  sel.value = cur;
}

async function loadClubs() {
  setError("");
  setStatus("Loading clubs…");
  const { data, error } = await supabase
    .from("clubs_database_public")
    .select("*")
    .order("prestige_rank", { ascending: true, nullsFirst: false });

  if (error) {
    setError(
      error.message +
        " — run supabase/sql/patches/clubs_database_public.sql in Supabase."
    );
    setStatus("");
    return;
  }
  allRows = data || [];
  fillNationFilter();
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("filterSearch")?.addEventListener("input", () => {
    page = 1;
    render();
  });
  document.getElementById("filterNation")?.addEventListener("change", () => {
    page = 1;
    render();
  });
  document.getElementById("pageSize")?.addEventListener("change", (e) => {
    pageSize = Number(e.target.value) || 100;
    page = 1;
    render();
  });
  document.getElementById("clearFiltersBtn")?.addEventListener("click", () => {
    const s = document.getElementById("filterSearch");
    const n = document.getElementById("filterNation");
    if (s) s.value = "";
    if (n) n.value = "";
    page = 1;
    render();
  });

  await loadClubs();
});
