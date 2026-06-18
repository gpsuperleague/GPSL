/** Winner medals on player career profiles — ribbon medals per competition. */

import { fullClubName } from "./clubs_lookup.js";
import { trophyHonourHref } from "./history_trophies.js";

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** CSS modifier + disc abbreviation for each honour. */
export function medalKindForHonour(h) {
  if (h.honour_type === "league_champion") {
    if (h.division === "superleague") return { kind: "superleague", abbrev: "SL" };
    if (h.division === "championship_a") return { kind: "championship_a", abbrev: "CA" };
    if (h.division === "championship_b") return { kind: "championship_b", abbrev: "CB" };
    return { kind: "championship_a", abbrev: "CH" };
  }
  const cup = h.cup_code === "spoon" ? "bowl" : h.cup_code;
  const cupAbbrevs = {
    league_cup: "LC",
    super8: "S8",
    plate: "PL",
    shield: "SH",
    bowl: "BW",
  };
  return {
    kind: cup || "bowl",
    abbrev: cupAbbrevs[cup] || "CP",
  };
}

export function medalAriaLabel(h) {
  return `${h.honour_label || "Winner"} — ${formatHonourDetail(h)}`;
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

/** CSS ribbon medal (gold / silver / bronze disc + coloured ribbons). */
export function renderMedalHtml(h, { list = false } = {}) {
  const { kind, abbrev } = medalKindForHonour(h);
  const listClass = list ? " gpsl-medal--list" : "";
  return `
    <div class="gpsl-medal gpsl-medal--${esc(kind)}${listClass}" role="img" aria-label="${esc(medalAriaLabel(h))}">
      <div class="gpsl-medal-ribbons" aria-hidden="true">
        <span class="gpsl-medal-ribbon gpsl-medal-ribbon--l"></span>
        <span class="gpsl-medal-ribbon gpsl-medal-ribbon--r"></span>
      </div>
      <div class="gpsl-medal-disc" aria-hidden="true">
        <span class="gpsl-medal-disc-text">${esc(abbrev)}</span>
      </div>
    </div>`;
}

function renderMedalWall(honours) {
  if (!honours?.length) return "";
  return `
    <div class="gpsl-medal-wall" aria-label="Winner medals">
      ${sortHonours(honours)
        .map(
          (h) => `
        <figure class="gpsl-medal-pin">
          ${renderMedalHtml(h)}
          <figcaption>${esc(h.season_label || "")}</figcaption>
        </figure>`
        )
        .join("")}
    </div>`;
}

const DEFAULT_EMPTY =
  "No winner medals yet — league titles and cups appear after season archive (5+ league apps or 1+ cup app with the winning club).";

/** Returns HTML for medals wall + detail list. */
export function renderHonoursHtml(honours, { emptyMessage = DEFAULT_EMPTY } = {}) {
  if (!honours?.length) {
    return `<p class="empty">${emptyMessage}</p>`;
  }

  const sorted = sortHonours(honours);

  return `
    ${renderMedalWall(sorted)}
    <ul class="trophy-list medal-detail-list">
      ${sorted
        .map((h) => {
          const href = trophyHonourHref(h);
          const thumb = renderMedalHtml(h, { list: true });
          const body = `
            <div class="trophy-body">
              <div class="trophy-title">${esc(h.honour_label || "Winner")}</div>
              <div class="trophy-meta">${esc(formatHonourDetail(h))}</div>
            </div>`;
          if (href) {
            return `<li class="trophy-item medal-item">
              <a class="medal-link" href="${esc(href)}">${thumb}${body}</a>
            </li>`;
          }
          return `<li class="trophy-item medal-item">${thumb}${body}</li>`;
        })
        .join("")}
    </ul>`;
}

/** Sample honours for inline preview on a real player profile. */
export const PLAYER_MEDALS_PREVIEW_HONOURS = [
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
  {
    honour_type: "cup_winner",
    cup_code: "super8",
    honour_label: "Super8 winners",
    season_label: "2023/24",
    club_short_name: "BAR",
    club_name: "Barcelona",
  },
];

/** @deprecated Use PLAYER_MEDALS_PREVIEW_HONOURS — kept for preview page. */
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
    honours: [PLAYER_MEDALS_PREVIEW_HONOURS[0]],
  },
  {
    id: "multi_club",
    title: "Titles at two clubs",
    blurb: "Super League and League Cup at Barcelona, then Super League at Kasimpasa.",
    player_name: "Hugo Ekitike",
    honours: PLAYER_MEDALS_PREVIEW_HONOURS.slice(0, 3),
  },
  {
    id: "cup_specialist",
    title: "Cup medals",
    blurb: "Super8 and League Cup — different ribbon colours per competition.",
    player_name: "Cup Final Hero",
    honours: [
      PLAYER_MEDALS_PREVIEW_HONOURS[3],
      PLAYER_MEDALS_PREVIEW_HONOURS[1],
    ],
  },
  {
    id: "full_shelf",
    title: "Full ribbon set",
    blurb: "Every GPSL medal type — gold, silver and bronze discs with competition ribbons.",
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
      {
        honour_type: "cup_winner",
        cup_code: "league_cup",
        honour_label: "League Cup winners",
        season_label: "2024/25",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
      {
        honour_type: "cup_winner",
        cup_code: "super8",
        honour_label: "Super8 winners",
        season_label: "2023/24",
        club_short_name: "LEE",
        club_name: "Leeds United",
      },
    ],
  },
];
