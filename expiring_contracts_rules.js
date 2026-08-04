/**
 * Expiring Contracts — owner-facing rules copy (modular cards).
 */
import { expiryWageMinUpliftPct, formatWage } from "./wages.js";

const CHAMP_SL_SIGNING_FEE = 10_000_000;

/**
 * @returns {{ title: string, cards: { heading: string, items: string[] }[] }}
 */
export function getExpiringContractRules() {
  const uplift = expiryWageMinUpliftPct();
  const signingFee = formatWage(CHAMP_SL_SIGNING_FEE);

  return {
    title: "Hidden wage bid rules",
    cards: [
      {
        heading: "Who is on this market",
        items: [
          "Players in their <b>final contract year</b> on the <b>contested</b> path.",
          "<b>Not listed here:</b> home-grown ≤23, and non-home-grown ≤21 — those renew uncontested on Squad.",
          "The player <b>stays at the holding club</b> all season while bids are collected.",
        ],
      },
      {
        heading: "How to bid",
        items: [
          "<b>One</b> wage offer per club per player — <b>locked in</b> once submitted (cannot be changed).",
          `Minimum offer: <b>+${uplift}%</b> above the player’s current wage.`,
          "Any <b>whole ₿</b> amount at or above that floor is allowed.",
          "Rival amounts stay <b>hidden</b> until season rollover.",
        ],
      },
      {
        heading: "At season rollover",
        items: [
          "<b>Highest wage</b> wins a new <b>3-season</b> contract at that wage.",
          "<b>Ties</b> favour the holding club.",
          "Another club winning pays <b>market value</b> to the holder.",
          `Championship club taking a Super League player also pays <b>${signingFee}</b> to the player as a signing-on fee.`,
          "<b>No mid-season expire.</b> If nobody re-signs them, they become a free agent — holding club receives market value then.",
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
  if (!root) return;

  const { title, cards } = getExpiringContractRules();
  root.innerHTML = `
    <h2>${title}</h2>
    <div class="rules-grid">
      ${cards
        .map(
          (card) => `
        <section class="rules-card">
          <h3>${card.heading}</h3>
          <ul>
            ${card.items.map((item) => `<li>${item}</li>`).join("")}
          </ul>
        </section>`
        )
        .join("")}
    </div>
  `;
}
