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

/**
 * Plain-English description including the real target.
 * @param {string} statType
 * @param {number|string} targetValue
 * @param {string|object|null} statParam
 */
export function challengeStatDescription(statType, targetValue, statParam = null) {
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
    default:
      return type || "Challenge target";
  }
}
