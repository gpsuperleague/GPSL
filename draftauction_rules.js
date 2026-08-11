/**
 * Player Draft Auction — owner-facing instructions (left-to-right modules).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260811-draft-ltr";

export function getDraftAuctionRules() {
  return {
    title: "How player draft works",
    lead: "Live threads are listed below. Open a new free agent from <a href=\"GPDB.html\">GPDB</a>; join or raise bids here.",
    cards: [
      {
        heading: "1 · Earn bid credits",
        items: [
          "In <a href=\"GPDB.html\">GPDB</a>, be the <b>first</b> club to place a Draft Offer on a free agent.",
          "That opening bid earns you <b>2 credits</b> for later.",
        ],
      },
      {
        heading: "2 · Join or raise here",
        items: [
          "Each existing player thread you join costs <b>1 draft credit</b>.",
          "You cannot join with <b>zero</b> credits — earn one in GPDB first.",
          "Outbid rivals until the window ends.",
        ],
      },
      {
        heading: "3 · Highest bid wins",
        items: [
          "Draft closes with a random finish after <b>6:50pm UK</b> on Day 2.",
          "Leading bid on each player wins at settlement.",
        ],
      },
      {
        heading: "Timing (UK)",
        items: [
          "No bids by <b>6pm</b> → no bids after 6pm.",
          "No free agent openings after <b>6pm</b>.",
          "Countdowns show <b>your local</b> time.",
        ],
      },
      {
        heading: "On this page",
        items: [
          "<b>☆</b> saves a thread (also in Transfer Centre).",
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
