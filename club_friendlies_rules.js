/**
 * Club Friendlies — owner-facing help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-friendlies";

/**
 * @returns {{ cards: { heading: string, items: string[] }[] }}
 */
export function getClubFriendliesRules() {
  return {
    cards: [
      {
        heading: "What you see",
        items: [
          "<b>Discord-confirmed</b> friendlies for your club.",
          "Grouped by <b>GPSL month</b>.",
        ],
      },
      {
        heading: "Gate receipts",
        items: [
          "First <b>10 paid</b> friendlies each month earn <b>₿5,000</b> each.",
          "Season cap: <b>₿500,000</b> total from friendlies.",
        ],
      },
      {
        heading: "Standalone only",
        items: [
          "No league or cup fixtures.",
          "No player match records from these games.",
        ],
      },
    ],
  };
}

export function renderClubFriendliesRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("clubFriendliesRules");
  renderRulesPanel(root, getClubFriendliesRules());
}
