/**
 * Match Day — owner-facing squad help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js";

/**
 * @returns {{ cards: { heading: string, items: string[] }[] }}
 */
export function getMatchdaySquadRules() {
  return {
    cards: [
      {
        heading: "Build the 23",
        items: [
          "Drag player cards onto the pitch (<b>11 starters</b>) and bench (<b>12 subs</b>).",
          "This is your <b>default matchday squad</b> for the season.",
          "Starters auto-tick <b>Started</b> on match stats.",
        ],
      },
      {
        heading: "Positions &amp; roles",
        items: [
          "<b>Click</b> a position label or player on the pitch (or <b>right-click</b> the slot) to change its role (DMF, CMF, etc.).",
          "Use <b>Move positions</b> to drag markers around the pitch.",
        ],
      },
      {
        heading: "Formations",
        items: [
          "Save up to <b>5 custom formations</b> (Custom 1–5).",
          "Formation presets only apply when you click <b>Apply Default Formation</b>.",
          "Custom layouts must follow <b>GPSL mirroring</b>: LB↔RB, LMF↔RMF, LWF↔RWF; max <b>2</b> CF/SS combined.",
        ],
      },
    ],
  };
}

export function renderMatchdaySquadRules(rootEl) {
  const root =
    rootEl ||
    document.getElementById("matchdaySquadRules");
  renderRulesPanel(root, getMatchdaySquadRules());
}
