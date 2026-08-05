/**
 * Special Auction (Snap / LUB) — owner-facing one-line rules.
 */

export function getLubRulesText() {
  return "Submit one secret bid (nearest ₿1,000, minimum ₿1,000). When the window ends, all bids are revealed; the lowest amount that only one club chose wins and pays that amount.";
}

export function getSnapRulesText() {
  return "Snap (~1 hour). Countdown until the final 10 minutes, then a count-up timer — auction ends at a random moment in that window. Each bid costs ₿300k and must be at least ₿500k above the current highest. Winner pays 100% of bid fees + winning bid (minus first-bid discount 20/10/5/0%). Non-winners pay 25% of bid fees. Clues unlock at 0 / 20 / 40 / 50 minutes.";
}

/** @param {boolean} isLub */
export function getSpecialAuctionRulesText(isLub) {
  return isLub ? getLubRulesText() : getSnapRulesText();
}
