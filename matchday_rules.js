/**
 * Match Day — owner-facing squad help (modular cards).
 */
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260806-squad-rules2";
import { MATCHDAY_MIN_GOALKEEPERS } from "./squad_rules.js?v=20260925-no-u21-hg-mins";

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
          "This is your <b>default matchday squad</b> for the season — players must be from your <b>club squad</b>.",
          "Starters auto-tick <b>Started</b> on match stats.",
        ],
      },
      {
        heading: "Squad selection",
        items: [
          "Only players currently at your club.",
          "<b>No injured</b> or <b>suspended</b> players in the matchday 23 (save is blocked).",
          `At least <b>${MATCHDAY_MIN_GOALKEEPERS} goalkeeper in the starting XI</b>.`,
          "Matchday 23 has <b>no under-21 or home-grown minimum</b> — those rules apply to your <b>overall club squad</b> only (see Squad page).",
          "Live counts appear above the pitch — save is blocked until the matchday rules above are met.",
        ],
      },
      {
        heading: "Formations",
        items: [
          "Use the <b>formation dropdown</b> only — pick a named preset and click <b>Apply Formation</b>.",
          "<b>No free positioning</b> — marker layout comes from the formation; you cannot drag markers around.",
          "Role changes only where the Match Day / Admin catalogue allows (click a position label).",
          "<b>Mirroring:</b> LB must have RB, LWF must have RWF, LMF must have RMF.",
          "<b>No</b> CF/CF/SS, CF/SS/SS, or SS/SS/SS (CF + SS combined ≤ 2).",
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
