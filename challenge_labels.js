/**
 * Human-readable challenge target copy (Club challenges / Season challenges / Admin).
 */

/** Short labels for admin dropdowns. */
export const CHALLENGE_STAT_LABELS = {
  player_max_goals: "One club player — goals",
  player_max_assists: "One club player — assists",
  club_wins: "Club wins",
  club_goals_for: "Club goals scored",
  club_clean_sheets: "Club clean sheets",
  club_potm_awards: "Club POTM awards",
  player_hattrick_matchday: "Hat-trick on a matchday",
  transfer_sign_nation: "Sign by nationality",
  transfer_sign_homegrown: "Sign home-grown",
  transfer_sign_rated: "Sign low-rated player",
  match_hg_xi_unbeaten: "5 home-grown in the XI, and not lose",
  match_defender_goal_unbeaten: "Defender scores, and not lose",
  league_position_held: "Hold or improve league position",
  player_max_gk_clean_sheets: "One goalkeeper — clean sheets",
  match_win_by_3_spread: "Win by 3, 3 scorers, 3 assisters",
  transfer_sell_foreign_window: "Sell to foreign clubs (summer or January)",
  unbeaten_run_scheduled: "Unbeaten run in fixture order",
  match_u21_xi: "3 under-21s in the starting XI",
  match_young_xi: "Starting XI average age under 25",
};

function n(value, fallback = 1) {
  const x = Number(value);
  return Number.isFinite(x) && x > 0 ? Math.floor(x) : fallback;
}

function plural(count, one, many) {
  return count === 1 ? one : many;
}

function parseRatedParam(param) {
  if (!param) return null;
  try {
    return typeof param === "object" ? param : JSON.parse(param);
  } catch {
    return null;
  }
}

const MONTH_ORDER = [
  "june",
  "july",
  "august",
  "september",
  "october",
  "november",
  "december",
  "january",
  "february",
  "march",
  "april",
  "may",
];

const MONTH_LABELS = {
  june: "June",
  july: "July",
  august: "August",
  september: "September",
  october: "October",
  november: "November",
  december: "December",
  january: "January",
  february: "February",
  march: "March",
  april: "April",
  may: "May",
};

/** Transfer windows that fall inside the challenge's months, in season order. */
function transferWindowPhrase(monthFrom, monthTo) {
  const from = MONTH_ORDER.indexOf(String(monthFrom || "").toLowerCase());
  const to = MONTH_ORDER.indexOf(String(monthTo || "").toLowerCase());
  if (from < 0 || to < 0) return "";
  const lo = Math.min(from, to);
  const hi = Math.max(from, to);
  const names = ["june", "july", "august", "january"]
    .filter((month) => {
      const i = MONTH_ORDER.indexOf(month);
      return i >= lo && i <= hi;
    })
    .map((month) => MONTH_LABELS[month]);
  if (!names.length) return "";
  if (names.length === 1) return `the ${names[0]} window`;
  return `the ${names.join(", ")} window`;
}

/**
 * Plain-English description including the real target.
 * @param {string} statType
 * @param {number|string} targetValue
 * @param {string|object|null} statParam
 * @param {string|null} monthFrom
 * @param {string|null} monthTo
 */
export function challengeStatDescription(statType, targetValue, statParam = null, monthFrom = null, monthTo = null) {
  const t = n(targetValue, 1);
  const type = String(statType || "");

  switch (type) {
    case "player_max_goals":
      return `One of your players to score ${t} ${plural(t, "goal", "goals")}`;
    case "player_max_assists":
      return `One of your players to get ${t} ${plural(t, "assist", "assists")}`;
    case "club_wins":
      return `Your club to win ${t} ${plural(t, "match", "matches")}`;
    case "club_goals_for":
      return `Your club to score ${t} ${plural(t, "goal", "goals")}`;
    case "club_clean_sheets":
      return `Your club to keep ${t} clean ${plural(t, "sheet", "sheets")}`;
    case "club_potm_awards":
      return `Your club to win ${t} player-of-the-match ${plural(t, "award", "awards")}`;
    case "player_hattrick_matchday": {
      const md = String(statParam ?? "").replace(/[^0-9]/g, "") || "1";
      const when = md === "1" ? "on opening day (matchday 1)" : `on matchday ${md}`;
      return `One of your players to score a hat-trick ${when}`;
    }
    case "transfer_sign_nation": {
      const nation = String(statParam || "").trim().toUpperCase() || "the chosen nation";
      return `Sign ${t} ${plural(t, "player", "players")} from ${nation}`;
    }
    case "transfer_sign_homegrown":
      return `Sign ${t} home-grown ${plural(t, "player", "players")}`;
    case "transfer_sign_rated": {
      const o = parseRatedParam(statParam);
      const maxR = o?.max_rating != null ? o.max_rating : "?";
      const bits = [`rated ${maxR} or below`];
      if (o?.require_age) bits.push(`age ${o.max_age ?? 21} or under`);
      if (o?.require_hg) bits.push("home-grown");
      return `Sign ${t} ${plural(t, "player", "players")} ${bits.join(", ")}`;
    }
    case "match_hg_xi_unbeaten":
      return `Start at least 5 home-grown players and not lose, in ${t} ${plural(t, "match", "matches")}`;
    case "match_defender_goal_unbeaten":
      return `A defender scores and you do not lose, in ${t} ${plural(t, "match", "matches")}`;
    case "league_position_held":
      return `Finish the month level with or above your league position from the end of the previous month, in ${t} ${plural(t, "month", "months")}`;
    case "player_max_gk_clean_sheets":
      return `One goalkeeper to keep ${t} clean ${plural(t, "sheet", "sheets")}`;
    case "match_win_by_3_spread":
      return `Win by 3 or more with 3 different scorers and 3 different assisters, in ${t} ${plural(t, "match", "matches")}`;
    case "transfer_sell_foreign_window": {
      const window = transferWindowPhrase(monthFrom, monthTo);
      return `Sell ${t} ${plural(t, "player", "players")} to foreign clubs in ${
        window || "the summer window or January"
      }`;
    }
    case "unbeaten_run_scheduled":
      return `Go ${t} matches without losing, in fixture order`;
    case "match_u21_xi":
      return `Start 3 under-21 players in ${t} ${plural(t, "match", "matches")}`;
    case "match_young_xi":
      return `Start with an average age under 25 in ${t} ${plural(t, "match", "matches")}`;
    default:
      return type || "Challenge target";
  }
}
