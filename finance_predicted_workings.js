/**
 * "How we got here" panel for the Predicted end-of-season balance on finances.html:
 * current balance + each pending forecast line = predicted, then a list of
 * money that could still move the figure but is not in it.
 */

import { formatMoney } from "./competition.js";
import { FINANCE_UI_SECTIONS } from "./finance_ui.js?v=20261009-fin-remaining";

const LINE_LABELS = new Map();
for (const section of FINANCE_UI_SECTIONS) {
  for (const line of section.lines) {
    LINE_LABELS.set(line.id, { label: line.label, section: section.title });
  }
}

const FFP_THRESHOLD = -100_000_000;

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function signed(n) {
  const v = Number(n) || 0;
  const cls = v >= 0 ? "pw-pos" : "pw-neg";
  return `<span class="${cls}">${v >= 0 ? "+" : "−"}${formatMoney(Math.abs(v))}</span>`;
}

function posted(byLine, lineId) {
  return Math.abs(Number(byLine?.get(lineId)?.amount || 0)) > 0.5;
}

/** Live listings where this club is the seller and someone has bid. */
export async function loadListedSaleBids(supabase, clubShortName) {
  if (!clubShortName) return { total: 0, count: 0 };
  const { data, error } = await supabase
    .from("Player_Transfer_Listings")
    .select("id, current_highest_bid")
    .eq("seller_club_id", clubShortName)
    .in("status", ["Active", "Review", "Seller Review"])
    .gt("current_highest_bid", 0);
  if (error) {
    console.warn("listed sale bids:", error);
    return { total: 0, count: 0 };
  }
  const rows = data || [];
  return {
    total: rows.reduce((s, r) => s + (Number(r.current_highest_bid) || 0), 0),
    count: rows.length,
  };
}

/**
 * @param {{
 *   balanceNow: number,
 *   projectedBalance: number,
 *   pendingByLine: Map<string, { amount: number, note?: string }>,
 *   byLine: Map<string, { amount: number }>,
 *   bidExposure?: { total: number, count: number },
 * }} data
 * @param {{ listedSales?: { total: number, count: number } }} [extra]
 */
export function renderPredictedWorkingsHtml(data, extra = {}) {
  const byLine = data.byLine || new Map();
  const pending = [...(data.pendingByLine || new Map()).entries()]
    .filter(([, p]) => Math.abs(Number(p?.amount) || 0) >= 0.5)
    .sort((a, b) => Math.abs(b[1].amount) - Math.abs(a[1].amount));

  const income = pending.filter(([, p]) => p.amount > 0);
  const costs = pending.filter(([, p]) => p.amount < 0);
  const sum = (rows) => rows.reduce((s, [, p]) => s + Number(p.amount), 0);

  const rowHtml = ([lineId, p]) => {
    const meta = LINE_LABELS.get(lineId);
    const label = meta?.label || lineId;
    const section = meta?.section ? `<span class="pw-section">${esc(meta.section)}</span>` : "";
    return `<tr>
      <td>${esc(label)}${section}${p.note ? `<div class="pw-note">${esc(p.note)}</div>` : ""}</td>
      <td class="pw-amt">${signed(p.amount)}</td>
    </tr>`;
  };

  const groupHtml = (title, rows) =>
    rows.length
      ? `<tr class="pw-group"><td colspan="2">${title}</td></tr>${rows.map(rowHtml).join("")}`
      : "";

  const workings = `
    <table class="pw-table">
      <tbody>
        <tr class="pw-total"><td>Current balance (money in the bank now)</td><td class="pw-amt">${formatMoney(data.balanceNow)}</td></tr>
        ${groupHtml("Still to come in", income)}
        ${groupHtml("Still to go out", costs)}
        ${pending.length ? "" : `<tr><td colspan="2" class="pw-note">Nothing pending — every forecast line is already on the ledger.</td></tr>`}
        <tr class="pw-sub"><td>Pending income</td><td class="pw-amt">${signed(sum(income))}</td></tr>
        <tr class="pw-sub"><td>Pending costs</td><td class="pw-amt">${signed(sum(costs))}</td></tr>
        <tr class="pw-total"><td>Predicted end-of-season balance</td><td class="pw-amt">${formatMoney(data.projectedBalance)}</td></tr>
      </tbody>
    </table>`;

  const projected = Number(data.projectedBalance) || 0;
  const bids = data.bidExposure || { total: 0, count: 0 };
  const listed = extra.listedSales || { total: 0, count: 0 };
  const missing = [];

  if (bids.count > 0) {
    missing.push(
      `<b>Tax and agent fees on your ${bids.count} winning bid${bids.count === 1 ? "" : "s"}.</b> The bids are counted at their price only. Income tax on player purchases, and the agent fee on transfer list deals, are added when they settle.`
    );
  }
  if (listed.count > 0) {
    missing.push(
      `<b>Sales of your listed players — up to ${formatMoney(listed.total)}</b> from ${listed.count} listing${listed.count === 1 ? "" : "s"} with bids. Not counted until the sale completes (bids can drop or be withdrawn).`
    );
  }
  if (!posted(byLine, "commercial_merchandise")) {
    missing.push(
      "<b>Merchandising income</b> — paid at Close Finances on this season's results and stadium fill. Not estimated yet."
    );
  }
  if (!posted(byLine, "commercial_sponsorship")) {
    missing.push(
      "<b>Main sponsor</b> — not paid yet. Choose your sponsor on the Stadium page; the money appears once the deal is signed."
    );
  } else {
    missing.push(
      "<b>Sponsor performance bonus</b> — performance deals can add a bonus at Close Finances. Not estimated."
    );
  }
  if (!posted(byLine, "commercial_advertising")) {
    missing.push("<b>Pitchside advertising</b> — not paid yet this season. Not estimated.");
  }
  missing.push(
    "<b>Future cup rounds and challenge prizes</b> — depend on results, so only money already won is counted."
  );
  if (projected >= 0) {
    missing.push(
      "<b>Balance interest</b> — a small credit on a positive balance at Close Finances. Not estimated."
    );
  } else {
    missing.push(
      "<b>Debt interest</b> — charged on a negative balance at Close Finances. Not estimated, so the real figure will be lower."
    );
  }
  if (projected <= FFP_THRESHOLD) {
    missing.push(
      `<b>FFP fine</b> — your prediction is at or below ${formatMoney(FFP_THRESHOLD)}, which triggers a flat FFP fine at Close Finances. Not included.`
    );
  }
  missing.push(
    "<b>Fines, medical hires, stadium expansions, new signings and sales you have not made yet</b> — only counted once they happen."
  );

  const assumptions = [];
  if (Math.abs(Number(data.pendingByLine?.get("gov_emergency_tax")?.amount) || 0) >= 0.5) {
    assumptions.push(
      "<b>Emergency tax</b> is included as a cost, but it is only charged if the admin applies it."
    );
  }
  if (Math.abs(Number(data.pendingByLine?.get("prize_league")?.amount) || 0) >= 0.5) {
    assumptions.push(
      "<b>League prize</b> assumes you finish where you are in the table now."
    );
  }
  if (Math.abs(Number(data.pendingByLine?.get("infra_gates")?.amount) || 0) >= 0.5) {
    assumptions.push(
      "<b>Gate receipts</b> use an estimate per home match; real crowds vary."
    );
  }
  if (Math.abs(Number(data.pendingByLine?.get("transfer_purchases")?.amount) || 0) >= 0.5) {
    assumptions.push(
      "<b>Winning bids</b> assume you win every auction you currently lead. Being outbid raises the figure."
    );
  }
  assumptions.push(
    "Loan instalments due in later seasons are not included — only this season's."
  );

  const list = (items) => `<ul class="pw-list">${items.map((t) => `<li>${t}</li>`).join("")}</ul>`;

  return `
    <h3>How we got to ${formatMoney(data.projectedBalance)}</h3>
    ${workings}
    ${assumptions.length ? `<h4>Assumptions in this figure</h4>${list(assumptions)}` : ""}
    <h4>Not in this figure (could still change it)</h4>
    ${list(missing)}
  `;
}
