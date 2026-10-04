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
        heading: "How your squad is used",
        items: [
          "You save <b>one squad</b> and it is used for <b>every fixture</b> until you change it — there is no separate submit step.",
          "It is checked when you <b>check in</b> (from 10 minutes before kick-off): <b>exactly 11 starters</b>, a goalkeeper, and <b>no injured or suspended players</b>. If it fails, check-in is refused.",
          "Injuries and suspensions change between matches — re-check before each kick-off. You'll get an Inbox warning if your saved squad isn't valid for a kick-off in the next 48 hours.",
          "Your opponent can see your saved XI in the Match Centre preview.",
        ],
      },
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
          "Live counts appear above the pitch. Saving is blocked for unavailable players or a missing goalkeeper; fewer than 11 starters can be saved as a draft but won't pass check-in.",
        ],
      },
      {
        heading: "Formations",
        items: [
          "Pick a formation from the <b>dropdown</b> — the pitch layout updates straight away. <b>Apply Formation</b> resets the markers to that template.",
          "<b>No free positioning</b> — marker layout comes from the formation template set by the league.",
          "Click a position label to change its role, where the formation allows it.",
          "<b>Mirroring:</b> LB must have RB, LWF must have RWF, LMF must have RMF.",
          "<b>No</b> CF/CF/SS, CF/SS/SS, or SS/SS/SS (CF + SS combined ≤ 2).",
          "<b>No more than 2 DMFs</b> and <b>no more than 2 AMFs</b> on the pitch (hard rule — converting a third is blocked).",
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
