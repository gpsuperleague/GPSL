import { initAdminPage, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

const TYPE_LABELS = {
  opening_balance: "Opening balance",
  bookies_expenditure: "Bookies stake",
  bookies_income: "Bookies win",
  shop_purchase: "Owners Shop",
  gpfl_prize: "GPFL prize",
  challenge_prize: "Challenge prize",
  friendlies_prize: "Friendlies prize",
  supporter_lottery_credit: "Supporters' lottery",
  admin_credit: "Admin credit",
  admin_debit: "Admin debit",
};

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
let sortKey = "balance";
let sortDir = "desc";
let activeOwnerId = null;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function typeLabel(t) {
  return TYPE_LABELS[t] || String(t || "Entry").replace(/_/g, " ");
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function filteredRows() {
  const q = String(document.getElementById("owFilter")?.value || "")
    .trim()
    .toLowerCase();
  const scope = document.getElementById("owScope")?.value || "all";
  let rows = allRows.slice();
  if (scope === "club") rows = rows.filter((r) => r.club_short_name);
  if (scope === "noclub") rows = rows.filter((r) => !r.club_short_name);
  if (q) {
    rows = rows.filter((r) => {
      const hay = [r.owner_tag, r.email, r.club_name, r.club_short_name, r.registry_status]
        .map((x) => String(x || "").toLowerCase())
        .join(" ");
      return hay.includes(q);
    });
  }
  rows.sort((a, b) => {
    let av = a[sortKey];
    let bv = b[sortKey];
    if (sortKey === "balance") {
      av = Number(av) || 0;
      bv = Number(bv) || 0;
      return sortDir === "asc" ? av - bv : bv - av;
    }
    av = String(av ?? "").toLowerCase();
    bv = String(bv ?? "").toLowerCase();
    if (av < bv) return sortDir === "asc" ? -1 : 1;
    if (av > bv) return sortDir === "asc" ? 1 : -1;
    return 0;
  });
  return rows;
}

function renderSummary(rows) {
  const el = document.getElementById("owSummary");
  if (!el) return;
  const total = rows.reduce((s, r) => s + (Number(r.balance) || 0), 0);
  const withClub = rows.filter((r) => r.club_short_name).length;
  el.innerHTML = `
    <span><b>${rows.length}</b> shown</span>
    <span><b>${withClub}</b> with a club</span>
    <span>Total wealth <b>${escapeHtml(formatMoney(total))}</b></span>
  `;
}

function renderTable() {
  const body = document.getElementById("owBody");
  if (!body) return;
  const rows = filteredRows();
  renderSummary(rows);
  if (!rows.length) {
    body.innerHTML = `<tr><td colspan="5" class="ow-muted">No owners match.</td></tr>`;
    return;
  }
  body.innerHTML = rows
    .map((r) => {
      const bal = Number(r.balance) || 0;
      const active = r.owner_id === activeOwnerId ? " ow-active" : "";
      return `
      <tr class="${active}" data-owner="${escapeHtml(r.owner_id)}">
        <td>${escapeHtml(r.owner_tag || r.email || "—")}</td>
        <td>${escapeHtml(r.club_name || "—")}</td>
        <td class="ow-muted">${escapeHtml(r.registry_status || "—")}</td>
        <td class="ow-bal${bal < 0 ? " neg" : ""}">${escapeHtml(formatMoney(bal))}</td>
        <td class="ow-muted">${r.wallet_updated_at ? escapeHtml(formatWhen(r.wallet_updated_at)) : "—"}</td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll("tr[data-owner]").forEach((tr) => {
    tr.addEventListener("click", () => loadStatement(tr.dataset.owner));
  });
}

async function loadOverview() {
  setStatus("Loading…");
  const { data, error } = await supabase.rpc("admin_owner_wallets_overview");
  if (error) {
    setStatus(
      error.message.includes("admin_owner_wallets")
        ? "Run admin_owner_wallets_overview_20261016.sql in Supabase."
        : error.message,
      false
    );
    allRows = [];
    renderTable();
    return;
  }
  allRows = Array.isArray(data) ? data : [];
  setStatus(`${allRows.length} owners loaded.`);
  renderTable();
}

async function loadStatement(ownerId) {
  activeOwnerId = ownerId;
  renderTable();
  const card = document.getElementById("owStmtCard");
  const title = document.getElementById("owStmtTitle");
  const meta = document.getElementById("owStmtMeta");
  const body = document.getElementById("owStmtBody");
  if (!card || !body) return;
  card.hidden = false;
  title.textContent = "Statement";
  meta.textContent = "Loading…";
  body.innerHTML = "";

  const { data, error } = await supabase.rpc("admin_owner_wallet_statement", {
    p_owner_id: ownerId,
    p_limit: 100,
  });
  if (error) {
    meta.textContent = error.message;
    return;
  }
  const tag = data?.owner_tag || "Owner";
  const club = data?.club_name ? ` · ${data.club_name}` : "";
  title.textContent = `${tag}${club}`;
  meta.textContent = `Balance ${formatMoney(Number(data?.balance) || 0)} · last 100 entries`;
  const entries = Array.isArray(data?.entries) ? data.entries : [];
  if (!entries.length) {
    body.innerHTML = `<tr><td colspan="4" class="ow-muted">No ledger entries.</td></tr>`;
    return;
  }
  body.innerHTML = entries
    .map((e) => {
      const amt = Number(e.amount) || 0;
      const cls = amt < 0 ? "ow-amt-neg" : "ow-amt-pos";
      return `<tr>
        <td class="ow-muted">${escapeHtml(formatWhen(e.created_at))}</td>
        <td>${escapeHtml(typeLabel(e.entry_type))}</td>
        <td>${escapeHtml(e.description || "—")}</td>
        <td class="${cls}">${escapeHtml(formatMoney(amt))}</td>
      </tr>`;
    })
    .join("");
  card.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage(); // admin only — mods redirected
  if (!user) return;

  document.getElementById("owReload")?.addEventListener("click", () => loadOverview());
  document.getElementById("owFilter")?.addEventListener("input", () => renderTable());
  document.getElementById("owScope")?.addEventListener("change", () => renderTable());
  document.querySelectorAll("#owTable th[data-sort]").forEach((th) => {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (sortKey === key) sortDir = sortDir === "asc" ? "desc" : "asc";
      else {
        sortKey = key;
        sortDir = key === "balance" ? "desc" : "asc";
      }
      renderTable();
    });
  });

  await loadOverview();
});
