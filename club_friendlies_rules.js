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
        tip: "First 15 paid friendlies each month earn ₿5,000 gate each. Season cap: ₿750,000 total from friendlies.",
        items: [
          "First <b>15 paid</b> friendlies each month earn <b>₿5,000</b> each.",
          "Season cap: <b>₿750,000</b> total from friendlies.",
        ],
      },
      {
        heading: "Monthly table",
        tip:
          "Each month (June to May, not playoffs) has its own friendlies table. A win scores 2 to 6 points, a draw 0.5 to 3, " +
          "and a loss to a difficulty 4 or 5 side still scores 0.5 or 1. Only your first 2 games against the same club each month count. " +
          "You need 3 counted friendlies to win a prize. At month end, 1st gets ₿3,000 and 2nd ₿1,500 in their owner account.",
        items: [
          "Points for the result, more against <b>harder opponents</b>.",
          "Month winner <b>₿3,000</b>, runner-up <b>₿1,500</b> to your owner account.",
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
