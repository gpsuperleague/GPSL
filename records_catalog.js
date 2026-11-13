/** GPSL all-time record catalogs. Only marks the weekly job can fill. */

/** @typedef {{ id: string, label: string }} RecordDef */
/** @typedef {{ id: string, title: string, records: RecordDef[] }} RecordGroup */

/** @type {RecordGroup[]} */
export const LEAGUE_RECORD_GROUPS = [
  {
    id: "club",
    title: "Club Records",
    records: [
      { id: "most_points_season", label: "Most Points in a Season" },
      { id: "fewest_points_season", label: "Fewest Points in a Season" },
      { id: "most_wins_season", label: "Most Wins in a Season" },
      { id: "fewest_wins_season", label: "Fewest Wins in a Season" },
      { id: "most_consecutive_wins", label: "Most Consecutive Wins" },
      { id: "longest_unbeaten_run", label: "Longest Unbeaten Run" },
      { id: "most_home_wins_season", label: "Most Home Wins in a Season" },
      { id: "most_away_wins_season", label: "Most Away Wins in a Season" },
      { id: "fewest_defeats_season", label: "Fewest Defeats in a Season" },
      { id: "most_draws_season", label: "Most Draws in a Season" },
      { id: "most_goals_scored_season", label: "Most Goals Scored in a Season" },
      { id: "fewest_goals_conceded_season", label: "Fewest Goals Conceded in a Season" },
      { id: "best_goal_difference", label: "Best Goal Difference" },
    ],
  },
  {
    id: "match",
    title: "Match Records",
    records: [
      { id: "biggest_league_win", label: "Biggest League Win" },
      { id: "highest_scoring_match", label: "Highest Scoring Match" },
      { id: "most_goals_one_team_match", label: "Most Goals by One Team in a Match" },
    ],
  },
  {
    id: "player",
    title: "Player Records",
    records: [
      { id: "most_league_apps", label: "Most League Appearances" },
      { id: "most_league_goals", label: "Most League Goals" },
      { id: "most_goals_season", label: "Most Goals in a Season" },
      { id: "most_hat_tricks", label: "Most Hat-Tricks" },
      { id: "most_assists", label: "Most Assists" },
      { id: "most_potm", label: "Most Player of the Match Awards" },
      { id: "most_goals_single_match", label: "Most Goals in a Single Match" },
      { id: "most_yellow_cards", label: "Most Yellow Cards" },
      { id: "most_red_cards", label: "Most Red Cards" },
    ],
  },
];

/** @type {RecordGroup[]} */
export const CUP_RECORD_GROUPS = [
  {
    id: "club",
    title: "Club Records",
    records: [
      { id: "most_cup_matches_won", label: "Most Cup Matches Won" },
      { id: "biggest_cup_match_victory", label: "Biggest Cup Match Victory" },
    ],
  },
  {
    id: "player",
    title: "Player Records",
    records: [
      { id: "most_cup_apps", label: "Most Cup Appearances" },
      { id: "most_cup_goals", label: "Most Cup Goals" },
      { id: "most_cup_assists", label: "Most Assists in Cup History" },
      { id: "most_goals_single_cup_match", label: "Most Goals in a Single Cup Match" },
    ],
  },
];

/** @type {RecordGroup[]} */
export const FUN_RECORD_GROUPS = [
  {
    id: "fun",
    title: "Fun Records",
    records: [
      { id: "biggest_giant_killing", label: "Biggest Giant Killing" },
      { id: "richest_club_ever", label: "Richest Club Ever Recorded" },
    ],
  },
];
