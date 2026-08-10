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
      {
        heading: "View vs bid",
        items: [
          "<b>View</b> always opens the auction room so you can check the live high bid and full bid history.",
          "<b>Bid</b> is only available when you are eligible; otherwise it shows <b>Locked</b> (you can still View).",
        ],
      },
      {
        heading: "Fair play — no auto-bid probing",
        items: [
          "Do <b>not</b> open auctions just to nudge prices up by forcing rivals’ <b>max / auto-bids</b> to fire.",
          "Min-step probes and repeated “bump then walk away” bids to inflate a listing are against fair play.",
          "Admins may remove abusive bids and sanction repeat offenders.",
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
