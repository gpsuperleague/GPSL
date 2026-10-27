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
        tip: "First 20 paid friendlies each month earn club gate. Standard rate ₿5,000. Ko-fi Supporters earn ₿15,000 on the first 10 of the month, then ₿5,000 for 11–20. Season caps: ₿1,200,000 standard / ₿2,000,000 for Supporters.",
        items: [
          "First <b>20 paid</b> friendlies each month earn gate receipts.",
          "Standard: <b>₿5,000</b> each. Season cap <b>₿1,200,000</b>.",
          "<b>Ko-fi Supporters:</b> first <b>10</b> → <b>₿15,000</b>, then <b>₿5,000</b> for 11–20. Season cap <b>₿2,000,000</b>.",
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
          "Only your <b>first 2 games</b> against the same club each month count (extra games still earn gate money).",
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
