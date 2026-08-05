/**
 * Manager Draft Auction — owner-facing rules copy.
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js";

export function getManagerDraftAuctionRules() {
  return {
    title: "Rules",
    lead: "UK time, shown locally on countdown.",
    cards: [
      {
        heading: "Window",
        items: [
          "Bidding stays open until the <b>6:50pm UK random window</b> on Day 2.",
          "Settles after evening transfer auctions, same as players.",
        ],
      },
      {
        heading: "One lead at a time",
        items: [
          "You may hold the <b>highest bid on only one</b> manager auction at a time.",
          "Get outbid elsewhere, or wait for that auction to settle, before leading another.",
        ],
      },
    ],
  };
}

export function renderManagerDraftAuctionRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("managerDraftAuctionRules") ||
    document.querySelector(".info-box");
  renderRulesPanel(root, getManagerDraftAuctionRules());
}
