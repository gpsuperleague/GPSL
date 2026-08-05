/**
 * Transfer Market — owner-facing rules copy (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js";

export function getTransferMarketRules() {
  return {
    title: "Transfer market rules",
    cards: [
      {
        heading: "Listing &amp; bidding",
        items: [
          "Runs at least <b>24 hours</b>, until the later of that or <b>7pm UK</b>.",
          "First bid ≥ <b>market value</b> (Value column).",
          "Later bids ≥ highest + <b>₿500,000</b> (and still ≥ market value).",
          "<b>Direct offers</b> (GPDB → Make Offer) also ≥ market value; seller reviews in Transfer Centre.",
        ],
      },
      {
        heading: "When time ends",
        items: [
          "<b>Reserve met</b> → highest bidder wins automatically.",
          "<b>Reserve not met</b> (with bids) → seller has <b>24 hours</b> to accept or reject (Seller review).",
          "<b>No bids</b> → listing closes; player stays with seller.",
        ],
      },
      {
        heading: "Extra time &amp; clocks",
        items: [
          "Bid in final <b>2 hours</b> → +<b>1 hour</b> once.",
          "Then bid in final <b>5 minutes</b> → +<b>5 minutes</b> (can repeat).",
          "Countdown shows time left, <b>UK end</b>, and <b>your local</b> time. Settlement follows shortly after zero.",
        ],
      },
    ],
  };
}

export function renderTransferMarketRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("transferMarketRules") ||
    document.querySelector(".info-box");
  renderRulesPanel(root, getTransferMarketRules(), {
    rootClass: "info-box info-box--wide",
  });
}
