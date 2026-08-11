/**
 * Player Draft Auction — owner-facing instructions (modular steps + cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260811-draft-guide";

export function getDraftAuctionRules() {
  return {
    title: "How player draft works",
    lead: "This page lists live draft threads. Open a new free agent from <a href=\"GPDB.html\">GPDB</a>; join or raise bids here.",
    notice: {
      title: "Credits before you bid here",
      body: `Joining a thread someone else already opened costs <b>1 draft credit</b>.
        You earn credits by making the <b>opening Draft Offer</b> on a free agent in
        <a href="GPDB.html">GPDB</a> (first club to bid in the live window).
        You cannot join threads here with <b>zero</b> credits.`,
      cta: {
        href: "GPDB.html",
        label: "Go to GPDB — earn credits",
        className: "button rules-notice-btn",
      },
    },
    steps: [
      {
        heading: "Earn a credit in GPDB",
        body: "Be the <b>first</b> club to place a Draft Offer on a free agent. That opening bid earns you a credit for later.",
      },
      {
        heading: "Join or raise on this page",
        body: "Find a live thread below, then bid. Each player you join costs <b>1 credit</b>. Outbid rivals until the window ends.",
      },
      {
        heading: "Highest bid wins at settlement",
        body: "When the draft closes (random finish after 6pm UK on Day 2), the leading bid on each player wins automatically.",
      },
    ],
    cards: [
      {
        heading: "Timing (UK)",
        items: [
          "No bids by <b>6pm</b> → no bids after 6pm.",
          "No free agent opening bids after <b>6pm</b>.",
          "Rules use <b>UK time</b>; countdown clocks show <b>your local</b> time.",
        ],
      },
      {
        heading: "On this page",
        items: [
          "Click <b>☆</b> to save a thread — pinned here and in <b>Transfer Centre → Saved Draft Auctions</b>.",
          "Use filters for name, club, your bids, scouting targets, nation / position / playstyle, and age / rating / bid / wage.",
          "Hide a thread to declutter the list (bids are unchanged). Turn on <b>Show hidden</b> to restore it.",
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
