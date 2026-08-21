/**
 * Match Day — owner-facing squad help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-squad-rules2";
import {
  MATCHDAY_MIN_GOALKEEPERS,
  MATCHDAY_MIN_UNDER_21,
  MATCHDAY_MIN_HG_STARTING_XI,
  MATCHDAY_MIN_HG_SQUAD,
} from "./squad_rules.js";

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
        heading: "Composition rules",
        items: [
          `At least <b>${MATCHDAY_MIN_GOALKEEPERS} goalkeeper</b> in the matchday squad.`,
          `At least <b>${MATCHDAY_MIN_UNDER_21} under-21</b> players in the matchday squad (age ≤21).`,
          `At least <b>${MATCHDAY_MIN_HG_STARTING_XI} home-grown</b> in the <b>starting XI</b> (Nation matches your club).`,
          `At least <b>${MATCHDAY_MIN_HG_SQUAD} home-grown</b> in the <b>whole matchday squad</b> (XI + bench).`,
          "Live counts appear above the pitch — save is blocked until these are met.",
        ],
      },
      {
        heading: "Positions &amp; roles",
        items: [
          "<b>Click</b> a position label or player on the pitch (or <b>right-click</b> the slot) to change its role (DMF, CMF, etc.).",
          "Use <b>Move positions</b> to drag markers around the pitch.",
          "Drag a player onto another to <b>swap</b>. Use <b>✕</b> to return them to the pool.",
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
