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
    title: "Final-year market rules",
    cards: [
      {
        heading: "Who is on this market",
        items: [
          "Players in their <b>final contract year</b> on the <b>contested</b> path.",
          "<b>Not listed here:</b> home-grown ≤23, non-home-grown ≤21 (renew uncontested on Squad), and <b>emergency / season loans</b>.",
          "Playoffs sit <b>outside</b> the 10 GPSL months (Aug–May).",
        ],
      },
      {
        heading: "August–December — transfer offers",
        items: [
          "Use <b>Make transfer offer</b> (fee to the holding club) — same as a GPDB direct offer.",
          "Seller reviews in <a href=\"transfer_center.html\">Transfer Centre</a>.",
          "Wage contract offers are <b>not</b> open yet.",
        ],
      },
      {
        heading: "January–May — wage contract offers",
        items: [
          "<b>One</b> wage offer per club per player — <b>locked</b> once submitted.",
          `Minimum offer: <b>+${uplift}%</b> above current wage.`,
          "Rival amounts stay <b>hidden</b>; clubs that bid show as <b>interested</b> to the holding club.",
          "Highest wage wins a new <b>3-season</b> deal when the contract ends; ties favour the holder.",
        ],
      },
      {
        heading: "Playoffs — owner only + agent bribe",
        items: [
          "<b>Rivals cannot</b> make contract offers in Playoffs.",
          "Only the <b>holding club</b> can submit a contract offer.",
          "Only the <b>holding club</b> can bribe — and only with a <b>Side door brown envelope</b> from <b>Owners Shop</b> (₿50,000).",
          "Shop buy posts Building Society as a <b>personal cheque to a made-up name</b>.",
          "<b>20% chance</b> a public <b>Leaked bids</b> stamp appears on the listing — rivals see the stamp only, not the amounts.",
        ],
      },
      {
        heading: "When the contract ends",
        items: [
          "Another club winning pays <b>market value</b> to the holder.",
          `Championship club taking a Super League player also pays <b>${CHAMP_SL_SIGNING_FEE_PCT}% of MV</b> to the player as a signing-on fee.`,
          "If nobody re-signs them, they become a free agent — holder receives market value then.",
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
