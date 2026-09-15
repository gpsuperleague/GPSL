/**
 * Club Friendlies — owner-facing help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260915-myclub-tips";

/**
 * @returns {{ cards: { heading: string, items: string[] }[] }}
 */
export function getClubFriendliesRules() {
  return {
    cards: [
      {
        heading: "What you see",
        tip: "Discord-confirmed friendlies for your club. Grouped by GPSL month.",
        items: [
          "<b>Discord-confirmed</b> friendlies for your club.",
          "Grouped by <b>GPSL month</b>.",
        ],
      },
      {
        heading: "Gate receipts",
        tip: "First 10 paid friendlies each month earn ₿5,000 gate each. Season cap: ₿500,000 total from friendlies.",
        items: [
          "First <b>10 paid</b> friendlies each month earn <b>₿5,000</b> each.",
          "Season cap: <b>₿500,000</b> total from friendlies.",
        ],
      },
      {
        heading: "Standalone only",
        tip: "Standalone only — no league or cup fixtures, and no player match records from these games.",
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
