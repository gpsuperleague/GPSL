/**
 * Special Auction (Snap / LUB) — owner-facing one-line rules.
 */

export function getLubRulesText() {
  return "Submit one secret bid (nearest ₿1,000, minimum ₿1,000). When the window ends, all bids are revealed; the lowest amount that only one club chose wins and pays that amount.";
}

export function getSnapRulesText() {
  return "Snap (~1 hour). Countdown until the final 10 minutes, then a count-up timer — auction ends at a random moment in that window. Each bid costs ₿300k and must be at least ₿500k above the current highest. Winner pays 100% of bid fees + winning bid (minus first-bid discount 20/10/5/0%). Non-winners pay 25% of bid fees. Clues unlock at 0 / 20 / 40 / 50 minutes.";
}

function fmtShortMoney(n) {
  const v = Number(n) || 0;
  if (v >= 1e6 && v % 1e6 === 0) return `₿${v / 1e6}m`;
  if (v >= 1e3 && v % 1e3 === 0) return `₿${v / 1e3}k`;
  return `₿${v.toLocaleString("en-GB")}`;
}

/** Snap rules as a row of small cards (owner page). */
export function getSnapRulesHtml({ bidFee = 300000, increment = 500000 } = {}) {
  const card = (icon, label, body) => `
    <div class="sa-rule-card">
      <div class="sa-rule-icon" aria-hidden="true">${icon}</div>
      <div class="sa-rule-label">${label}</div>
      <div class="sa-rule-body">${body}</div>
    </div>`;
  return `
    <div class="sa-rules-grid">
      ${card("⏱️", "Timing", "~1 hour. Countdown to minute 50, then a count-up — it ends at a <b>random moment</b> in the last 10 minutes.")}
      ${card("💸", "Each bid", `Costs <b>${fmtShortMoney(bidFee)}</b> and must beat the highest by at least <b>${fmtShortMoney(increment)}</b>.`)}
      ${card("🏆", "Winner pays", "Winning bid + <b>100%</b> of their bid fees, minus any first-bid discount.")}
      ${card("🤝", "Everyone else", "Pays <b>25%</b> of their bid fees.")}
      ${card("🎭", "Mystery player", "Clues unlock at <b>0 / 20 / 40 / 50</b> min. Identity revealed at the finish.")}
    </div>`;
}

/** @param {boolean} isLub */
export function getSpecialAuctionRulesText(isLub) {
  return isLub ? getLubRulesText() : getSnapRulesText();
}
