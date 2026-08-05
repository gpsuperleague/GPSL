/**
 * Player Draft Auction — owner-facing rules copy.
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js";

export function getDraftAuctionRules() {
  return {
    title: "Draft Rules",
    cards: [
      {
        heading: "Credits",
        items: [
          "Earn credits by being the <b>first</b> to bid on a free agent in GPDB.",
          "Joining an existing draft auction costs <b>1 credit</b>.",
        ],
      },
      {
        heading: "Timing (UK)",
        items: [
          "No bids by <b>6pm</b> → no bids after 6pm.",
          "No free agent bids after <b>6pm</b>.",
          "Rules use <b>UK time</b>; countdown clocks show <b>your local</b> time.",
        ],
      },
      {
        heading: "Saved &amp; filters",
        items: [
          "Click <b>☆</b> on a row to save a thread — saved auctions appear at the top here and in <b>Transfer Centre → Saved Draft Auctions</b>.",
          "Use filters above the table for name, club, your bids, scouting targets, nation / position / playstyle, and age / rating / bid / wage ranges.",
        ],
      },
    ],
  };
}

export function renderDraftAuctionRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("draftAuctionRules") ||
    document.querySelector(".info-box");
  renderRulesPanel(root, getDraftAuctionRules());
}
