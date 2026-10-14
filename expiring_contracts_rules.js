/**
 * Expiring Contracts — owner-facing rules copy (modular cards).
 */
import { expiryWageMinUpliftPct } from "./wages.js";
import { renderRulesPanel } from "./gpsl_rules_cards.js";

/** Champ→SL expiry signing-on fee as % of market value (paid to the player). */
export const CHAMP_SL_SIGNING_FEE_PCT = 15;

/**
 * @returns {{ title: string, cards: { heading: string, items: string[] }[] }}
 */
export function getExpiringContractRules() {
  const uplift = expiryWageMinUpliftPct();

  return {
    title: "Hidden wage bid rules",
    cards: [
      {
        heading: "Who is on this market",
        items: [
          "Players in their <b>final contract year</b> on the <b>contested</b> path.",
          "<b>Not listed here:</b> home-grown ≤23, non-home-grown ≤21 (renew uncontested on Squad), and <b>emergency / season loans</b> drafted in as stop-gaps.",
          "Bids open for the <b>final half-season</b> only: from <b>GPSL January</b> for summer contracts (before that the holder can still sell them), and from the <b>summer rollover</b> for January contracts (marked <b>Ends Jan</b>).",
          "The player <b>stays at the holding club</b> while bids are collected and cannot be sold.",
        ],
      },
      {
        heading: "How to bid",
        items: [
          "<b>One</b> wage offer per club per player — <b>locked in</b> once submitted (cannot be changed).",
          `Minimum offer: <b>+${uplift}%</b> above the player’s current wage.`,
          "Any <b>whole ₿</b> amount at or above that floor is allowed.",
          "Rival amounts stay <b>hidden</b> until the contract ends.",
        ],
      },
      {
        heading: "When the contract ends (summer rollover, or GPSL January for January contracts)",
        items: [
          "<b>Highest wage</b> wins a new <b>3-season</b> contract at that wage.",
          "<b>Ties</b> favour the holding club.",
          "Another club winning pays <b>market value</b> to the holder.",
          `Championship club taking a Super League player also pays <b>${CHAMP_SL_SIGNING_FEE_PCT}% of market value</b> to the player as a signing-on fee (shown on the market for Championship owners).`,
          "If nobody re-signs them, they become a free agent — holding club receives market value then.",
        ],
      },
    ],
  };
}

/** Render rules into `#expiringRules` (or the given root). */
export function renderExpiringContractRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("expiringRules") ||
    document.querySelector(".info-box");
  renderRulesPanel(root, getExpiringContractRules());
}
