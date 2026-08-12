/**
 * Player Draft Auction — owner-facing instructions (left-to-right modules).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260812-draft-detail";

export function getDraftAuctionRules() {
  return {
    title: "How player draft works",
    lead: "Live threads below. Open free agents from <a href=\"GPDB.html\">GPDB</a>; join or raise bids here.",
    cards: [
      {
        heading: "1 · Credits",
        items: [
          "First <b>Draft Offer</b> on a free agent in <a href=\"GPDB.html\">GPDB</a> earns <b>2 credits</b>.",
          "Credits fund joining other threads — you need them to bid.",
        ],
      },
      {
        heading: "2 · Join / raise",
        items: [
          "Joining a thread costs <b>1 credit</b> (need ≥1 available).",
          "Once in, raise / outbid until the window ends. Your max bid can auto-raise.",
        ],
      },
      {
        heading: "3 · Winner",
        items: [
          "Random finish after <b>6:50pm UK</b> on Day 2.",
          "Whoever holds the leading bid when it closes wins the player.",
        ],
      },
      {
        heading: "Timing (UK)",
        items: [
          "No new bids or free-agent openings after <b>6pm</b>.",
          "Countdowns on this page use your local time.",
        ],
      },
      {
        heading: "On this page",
        items: [
          "<b>☆</b> saves a thread so you can find it again.",
          "Saved threads also appear in Transfer Centre.",
        ],
      },
      {
        heading: "Fair play",
        items: [
          "Don’t probe with tiny raises just to force rivals’ <b>max / auto-bids</b> up.",
          "Admins may remove bids and sanction rule-breaking.",
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
