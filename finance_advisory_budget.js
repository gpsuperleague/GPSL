/**
 * Advisory season transfer budget:
 *   raw = current balance + predicted ops (excl. transfers) − winning bids
 *   spendable = max(0, raw)
 *
 * Soft guidance only — does not reserve cash or block bids.
 */

import { formatMoney, loadClubBalance, loadFinanceLedger } from "./competition.js";
import { aggregateLedgerByLine } from "./finance_ui.js";
import {
  buildFinanceProjections,
  loadClubWinningBidExposure,
} from "./finance_projections.js";

export const TRANSFER_PENDING_LINE_IDS = new Set([
  "transfer_sales",
  "transfer_purchases",
]);

export { loadClubWinningBidExposure };

function sumOpsPending(pendingByLine) {
  let opsPending = 0;
  let pendingIncome = 0;
  let pendingExpenditure = 0;
  for (const [lineId, pending] of pendingByLine.entries()) {
    if (TRANSFER_PENDING_LINE_IDS.has(lineId)) continue;
    const amt = Number(pending?.amount) || 0;
    opsPending += amt;
    if (amt >= 0) pendingIncome += amt;
    else pendingExpenditure += Math.abs(amt);
  }
  return { opsPending, pendingIncome, pendingExpenditure };
}

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {string} clubShortName
 * @param {{
 *   balanceNow?: number,
 *   byLine?: Map<string, { amount: number }>,
 *   pendingByLine?: Map<string, { amount: number, note?: string }>,
 * }} [preloaded]
 */
export async function computeAdvisoryTransferBudget(
  supabase,
  clubShortName,
  preloaded = {}
) {
  if (!clubShortName) {
    return {
      clubShortName: null,
      balanceNow: 0,
      opsPending: 0,
      pendingIncome: 0,
      pendingExpenditure: 0,
      bidExposure: 0,
      bidCount: 0,
      raw: 0,
      spendable: 0,
      runwayNegative: false,
      pendingByLine: new Map(),
    };
  }

  let balanceNow = preloaded.balanceNow;
  let byLine = preloaded.byLine;
  let pendingByLine = preloaded.pendingByLine;

  if (balanceNow == null || !byLine) {
    const balanceRow = await loadClubBalance(supabase, clubShortName);
    balanceNow = Number(balanceRow?.balance ?? 0);
    const ledger = await loadFinanceLedger(supabase, clubShortName, 1000);
    byLine = aggregateLedgerByLine(ledger);
  } else {
    balanceNow = Number(balanceNow) || 0;
  }

  let exposure = preloaded.bidExposure || null;

  if (!pendingByLine) {
    if (!exposure) {
      exposure = await loadClubWinningBidExposure(supabase, clubShortName);
    }
    const built = await buildFinanceProjections(supabase, clubShortName, {
      byLine,
      winningBidExposure: exposure,
    });
    pendingByLine = built.pendingByLine;
    exposure = built.bidExposure || exposure;
  } else if (!exposure) {
    exposure = await loadClubWinningBidExposure(supabase, clubShortName);
  }

  const { opsPending, pendingIncome, pendingExpenditure } =
    sumOpsPending(pendingByLine);

  const bidTotal = Number(exposure?.total) || 0;
  const bidCount = Number(exposure?.count) || 0;
  const raw = balanceNow + opsPending - bidTotal;
  const spendable = Math.max(0, raw);

  return {
    clubShortName,
    balanceNow,
    opsPending,
    pendingIncome,
    pendingExpenditure,
    bidExposure: bidTotal,
    bidCount,
    bidBreakdown: exposure,
    raw,
    spendable,
    runwayNegative: raw < 0,
    pendingByLine,
  };
}

export function advisoryBudgetTitle(advisory) {
  if (!advisory) return "Advisory season transfer budget";
  const parts = [
    `Bank ${formatMoney(advisory.balanceNow)}`,
    `ops +${formatMoney(advisory.pendingIncome)} / −${formatMoney(advisory.pendingExpenditure)}`,
  ];
  if (advisory.bidExposure > 0.5) {
    parts.push(
      `${advisory.bidCount} winning bid${advisory.bidCount === 1 ? "" : "s"} −${formatMoney(advisory.bidExposure)}`
    );
  }
  if (advisory.runwayNegative) {
    parts.push(`projected runway ${formatMoney(advisory.raw)}`);
  }
  return `Advisory season transfer budget (excl. transfer sales/purchases). ${parts.join(" · ")}`;
}

/**
 * Compact HTML for badges / panels.
 * @param {Awaited<ReturnType<typeof computeAdvisoryTransferBudget>>} advisory
 * @param {{ href?: string|null }} [opts]
 */
export function renderAdvisoryBudgetBadgeHtml(advisory, opts = {}) {
  const href = opts.href === undefined ? "finances.html" : opts.href;
  const spendable = formatMoney(advisory.spendable);
  const bank = formatMoney(advisory.balanceNow);
  const warn = advisory.runwayNegative
    ? `<span class="cbb-warn">Runway ${formatMoney(advisory.raw)}</span>`
    : "";
  const bidNote =
    advisory.bidExposure > 0.5
      ? `<span class="cbb-subline">Incl. −${formatMoney(advisory.bidExposure)} winning bids</span>`
      : `<span class="cbb-subline">Bank ${bank}</span>`;

  const inner = `
    <span class="cbb-stack">
      <span class="cbb-row">
        <span class="cbb-label">Advisory transfer budget</span>
        <span class="cbb-amount">${spendable}</span>
      </span>
      ${bidNote}
      ${warn}
    </span>
  `;

  if (href) {
    return `<a href="${href}">${inner}</a>`;
  }
  return inner;
}
