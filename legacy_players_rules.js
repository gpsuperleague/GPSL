/**
 * Legacy Players — owner-facing rules copy.
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js";

export function getLegacyPlayersRules() {
  return {
    sections: [
      {
        heading: "What is a legacy card?",
        lead: `After each PESDB sync, players who are in GPSL but no longer appear on pesdb.net are marked as
      <b>legacy</b>. They remain at their current club and can still be picked in your squad and play fixtures.
      They can also be <b>called up</b> to their national team. They <b>cannot</b> be signed, sold, or listed.`,
      },
      {
        heading: "Transfers vs internationals",
        items: [
          "<b>Signing / selling / draft / FA bids</b> — blocked while the card is legacy.",
          "<b>National team call-up</b> — allowed (same nationality rules and squad cap as any other player).",
          "Season exclusions (admin) are separate — those can still block call-ups.",
        ],
      },
      {
        heading: "When their contract runs out",
        items: [
          "<b>Cannot be sold or listed</b> on the transfer market at any time.",
          "<b>Not on the expiring-contracts wage bid market</b> — other clubs cannot bid for them.",
          `In the <b>final contract year</b>, renew from <a href="squad.html">Squad</a>:
        <b>one season at a time</b> (not a new 3-year deal). Home-grown ≤23 may keep the same wage on renew.`,
          "Or choose <b>Expire — release for MV</b> from Squad to drop the player for market value.",
          `<b>If released</b>, they stay in GPDB as a free agent but remain <b>unpurchaseable</b>
        (no draft / FA bids) until a future PESDB sync restores the card.`,
          "If the card returns on a future PESDB sync, it becomes a normal GPDB card again (sellable or draftable as a free agent).",
        ],
      },
    ],
  };
}

export function renderLegacyPlayersRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("legacyPlayersRules") ||
    document.querySelector(".info-box");
  renderRulesPanel(root, getLegacyPlayersRules(), {
    rootClass: "info-box info-box--accent",
  });
}
