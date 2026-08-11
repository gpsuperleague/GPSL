/**
 * Player Draft Auction — owner-facing instructions (left-to-right modules).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260811-draft-ltr";

export function getDraftAuctionRules() {
  return {
    title: "How player draft works",
    lead: "Live threads below. Open free agents from <a href=\"GPDB.html\">GPDB</a>; join or raise bids here.",
    cards: [
      {
        heading: "1 · Credits",
        items: [
          "First Draft Offer on a FA in <a href=\"GPDB.html\">GPDB</a> earns <b>2 credits</b>.",
        ],
      },
      {
        heading: "2 · Join / raise",
        items: [
          "Joining a thread costs <b>1 credit</b> (need ≥1). Outbid until the window ends.",
        ],
      },
      {
        heading: "3 · Winner",
        items: [
          "Random finish after <b>6:50pm UK</b> Day 2. Leading bid wins.",
        ],
      },
      {
        heading: "Timing (UK)",
        items: [
          "No new bids or FA openings after <b>6pm</b>. Countdowns use local time.",
        ],
      },
      {
        heading: "On this page",
        items: [
          "<b>☆</b> saves a thread (also in Transfer Centre).",
        ],
      },
      {
        heading: "Fair play",
        items: [
          "Don’t probe to force rivals’ <b>max / auto-bids</b> up. Admins may remove bids / sanction.",
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
