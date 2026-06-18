/** Winner medals on player career profiles (shared with preview page). */

import { fullClubName } from "./clubs_lookup.js";
import { TROPHY_IMAGES, trophyImageForCup } from "./trophy_assets.js";
import { trophyHonourHref } from "./history_trophies.js";

export function trophyImageForHonour(h) {
  if (h.honour_type === "league_champion") {
    return TROPHY_IMAGES[h.division] || TROPHY_IMAGES.championship;
  }
  return trophyImageForCup(h.cup_code);
}

export function formatHonourDetail(h) {
  const club = fullClubName(h.club_short_name) || h.club_name || h.club_short_name;
  return [h.season_label, club].filter(Boolean).join(" · ");
}

export function sortHonours(honours) {
  return [...(honours || [])].sort((a, b) => {
    const pri = (h) => (h.honour_type === "league_champion" ? 0 : 1);
    const p = pri(a) - pri(b);
    if (p !== 0) return p;
    return String(b.season_label || "").localeCompare(String(a.season_label || ""));
  });
}

const DEFAULT_EMPTY =
  "No winner medals yet — league titles and cups appear after season archive (5+ league apps or 1+ cup app with the winning club).";

/** Returns HTML for the medals list (player career + preview). */
export function renderHonoursHtml(honours, { emptyMessage = DEFAULT_EMPTY } = {}) {
  if (!honours?.length) {
    return `<p class="empty">${emptyMessage}</p>`;
  }

  return `
    <ul class="trophy-list">
      ${sortHonours(honours)
        .map((h) => {
          const img = trophyImageForHonour(h);
          const href = trophyHonourHref(h);
          const thumb = img
            ? `<img class="medal-thumb" src="${img}" alt="" width="44" height="56" loading="lazy">`
            : `<span class="medal-thumb-fallback" aria-hidden="true">🏆</span>`;
          const body = `
            <div class="trophy-body">
              <div class="trophy-title">${h.honour_label || "Winner"}</div>
              <div class="trophy-meta">${formatHonourDetail(h)}</div>
            </div>`;
          if (href) {
            return `<li class="trophy-item medal-item">
              <a class="medal-link" href="${href}">${thumb}${body}</a>
            </li>`;
          }
          return `<li class="trophy-item medal-item">${thumb}${body}</li>`;
        })
        .join("")}
    </ul>`;
}

/** Sample honours for preview — not live player data. */
export const PLAYER_MEDALS_PREVIEW_SCENARIOS = [
  {
    id: "empty",
    title: "No medals yet",
    blurb: "Before any archived wins — empty state on the profile.",
    player_name: "Sample Player",
    honours: [],
  },
  {
    id: "first_title",
    title: "First league title",
    blurb: "One Super League winners medal with season and club.",
    player_name: "Sample Striker",
    honours: [
      {
        honour_type: "league_champion",
        division: "superleague",
        honour_label: "SuperLeague champions",
        season_label: "2024/25",
        club_short_name: "MCI",
        club_name: "Manchester City",
      },
    ],
  },
  {
    id: "multi_club",
    title: "Titles at two clubs (Ekitike-style)",
    blurb:
      "Super League with Barcelona, League Cup with Barcelona, then Super League again after a move to Kasimpasa — three separate medals.",
    player_name: "Hugo Ekitike",
    honours: [
      {
        honour_type: "league_champion",
        division: "superleague",
        honour_label: "SuperLeague champions",
        season_label: "Season 1",
        club_short_name: "BAR",
        club_name: "Barcelona",
      },
      {
        honour_type: "cup_winner",
        cup_code: "league_cup",
        honour_label: "League Cup winners",
        season_label: "Season 2",
        club_short_name: "BAR",
        club_name: "Barcelona",
      },
      {
        honour_type: "league_champion",
        division: "superleague",
        honour_label: "SuperLeague champions",
        season_label: "Season 3",
        club_short_name: "KAS",
        club_name: "Kasimpasa",
      },
    ],
  },
  {
    id: "cup_specialist",
    title: "Cup medals",
    blurb: "Super8 and League Cup — trophy images differ per competition.",
    player_name: "Cup Final Hero",
    honours: [
      {
        honour_type: "cup_winner",
        cup_code: "super8",
        honour_label: "Super8 winners",
        season_label: "2023/24",
        club_short_name: "RMA",
        club_name: "Real Madrid",
      },
      {
        honour_type: "cup_winner",
        cup_code: "league_cup",
        honour_label: "League Cup winners",
        season_label: "2024/25",
        club_short_name: "RMA",
        club_name: "Real Madrid",
      },
    ],
  },
  {
    id: "full_shelf",
    title: "Busy career",
    blurb: "League titles in Super League and Championship plus several cups.",
    player_name: "Veteran Winner",
    honours: [
      {
        honour_type: "league_champion",
        division: "championship_a",
        honour_label: "Championship A champions",
        season_label: "2021/22",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
      {
        honour_type: "league_champion",
        division: "superleague",
        honour_label: "SuperLeague champions",
        season_label: "2023/24",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
      {
        honour_type: "cup_winner",
        cup_code: "plate",
        honour_label: "Plate winners",
        season_label: "2022/23",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
      {
        honour_type: "cup_winner",
        cup_code: "shield",
        honour_label: "Shield winners",
        season_label: "2020/21",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
      {
        honour_type: "cup_winner",
        cup_code: "bowl",
        honour_label: "Bowl winners",
        season_label: "2019/20",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
    ],
  },
];
