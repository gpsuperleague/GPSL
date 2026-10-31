import { supabase } from "./global.js";
import { formatMoney } from "./competition.js";
import {
  aggregateLedgerByLine,
  enrichLedgerFineFixtures,
  renderFinanceSections,
} from "./finance_ui.js?v=20261031-takeover-fee-line";

/**
 * Published season accounts on club.html. A season appears once Close Finances
 * has snapshotted it (competition_club_finance_season_archive).
 */
export async function renderClubSeasonAccounts(container, clubShortName) {
  if (!container || !clubShortName) return;

  const { data, error } = await supabase
    .from("competition_club_finance_season_archive_public")
    .select(
      "season_id, season_label, opening_balance, closing_balance, income_total, cost_total, net_total, ledger_lines, archived_at"
    )
    .eq("club_short_name", clubShortName)
    .order("season_id", { ascending: false })
    .limit(10);

  if (error) {
    console.warn("club season accounts:", error.message);
    container.hidden = true;
    return;
  }

  const rows = data || [];
  if (!rows.length) {
    container.innerHTML = `
      <h2>Season accounts</h2>
      <p class="club-accounts-empty">No published accounts yet — each season's accounts appear here once finances are closed at season end.</p>`;
    return;
  }

  container.innerHTML = `
    <h2>Season accounts</h2>
    <p class="club-accounts-intro">Full accounts, published when each season's finances are closed.</p>
    ${rows.map((r, i) => seasonBlockHtml(r, i === 0)).join("")}`;

  const bySeason = new Map(rows.map((r) => [String(r.season_id), r]));
  container.querySelectorAll("details[data-season]").forEach((el) => {
    const fill = () => fillSheet(el, bySeason.get(el.dataset.season));
    if (el.open) fill();
    el.addEventListener("toggle", () => {
      if (el.open) fill();
    });
  });
}

function seasonBlockHtml(r, open) {
  const net = Number(r.net_total || 0);
  const label = r.season_label || `Season ${r.season_id}`;
  return `
    <details class="club-accounts-season" data-season="${r.season_id}"${open ? " open" : ""}>
      <summary>
        <span class="club-accounts-label">${escapeHtml(label)}</span>
        <span class="club-accounts-stat">Opening <b>${formatMoney(Number(r.opening_balance || 0))}</b></span>
        <span class="club-accounts-stat">Income <b class="income-amt">${formatMoney(Number(r.income_total || 0))}</b></span>
        <span class="club-accounts-stat">Costs <b class="cost-amt">${formatMoney(Number(r.cost_total || 0))}</b></span>
        <span class="club-accounts-stat">Net <b class="${net >= 0 ? "income-amt" : "cost-amt"}">${net >= 0 ? "+" : "−"}${formatMoney(Math.abs(net))}</b></span>
        <span class="club-accounts-stat">Closing <b>${formatMoney(Number(r.closing_balance || 0))}</b></span>
      </summary>
      <div class="club-accounts-sheet fin-accounts-workbook"><p class="club-accounts-empty">Loading…</p></div>
    </details>`;
}

async function fillSheet(detailsEl, row) {
  const host = detailsEl.querySelector(".club-accounts-sheet");
  if (!host || !row || host.dataset.filled) return;
  host.dataset.filled = "1";

  let ledger = Array.isArray(row.ledger_lines) ? row.ledger_lines : [];
  ledger = await enrichLedgerFineFixtures(supabase, ledger);
  const byLine = aggregateLedgerByLine(ledger);

  host.innerHTML = renderFinanceSections(byLine, {
    runningStart: Number(row.opening_balance || 0),
    currentBalance: Number(row.closing_balance || 0),
    closed: true,
  });
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
