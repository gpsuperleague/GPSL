import { formatNavLabel } from "./nav_label.js";

/** Season management workflow — shared by admin nav + admin_season.html sidebar */
export const SEASON_ADMIN_NAV_VERSION = "20260622-in-progress-nav";

const SEASON_CALENDAR_NAV_ITEM = {
  label: "GPSL season calendar",
  href: "admin_season.html",
  hash: "wf-calendar",
  page: "admin_season",
};

const CREATE_NEW_SEASON_NAV_ITEM = {
  label: "Create new season",
  href: "admin_season.html",
  hash: "wf-kickoff",
  page: "admin_season",
};

const START_SEASON_NAV_ITEM = {
  label: "Start season",
  href: "admin_season.html",
  hash: "wf-kickoff",
  page: "admin_season",
};

const TRANSFER_WINDOW_NAV_ITEMS = [
  {
    label: "Set transfer window open",
    href: "admin_transfer_window.html",
    hash: "open",
    page: "admin_transfer_window",
  },
  {
    label: "Set transfer window closed",
    href: "admin_transfer_window.html",
    hash: "closed",
    page: "admin_transfer_window",
  },
];

const CHALLENGE_PAYOUTS_NAV_ITEM = {
  label: "Challenge payouts",
  href: "admin_challenges.html",
  page: "admin_challenges",
};

const CLUB_SEASON_CHECKLIST_NAV_ITEM = {
  label: "Club season checklist",
  href: "admin_club_checklist.html",
  page: "admin_club_checklist",
};

/** Shown first inside Pre-Season (direct link, no nested subgroup). */
export const SEASON_ADMIN_NAV_TOP_LINKS = [CLUB_SEASON_CHECKLIST_NAV_ITEM];

export const SEASON_ADMIN_NAV = [
  {
    id: "kickoff",
    label: "Kickoff",
    items: [CREATE_NEW_SEASON_NAV_ITEM],
  },
  {
    id: "divisions",
    label: "Assign Divisions",
    items: [
      {
        label: "Setup superleague teams",
        href: "admin_season.html",
        hash: "wf-divisions",
        page: "admin_season",
      },
      {
        label: "Setup championship teams",
        href: "admin_season.html",
        hash: "wf-divisions",
        page: "admin_season",
      },
      {
        label: "Draw championship divisions",
        href: "admin_season.html",
        hash: "wf-divisions",
        page: "admin_season",
      },
    ],
  },
  {
    id: "kickoff_go_live",
    label: "Kickoff",
    items: [SEASON_CALENDAR_NAV_ITEM, START_SEASON_NAV_ITEM],
  },
  {
    id: "league_fixtures",
    label: "League Fixtures",
    items: [
      {
        label: "Draw league fixtures",
        href: "admin_fixtures-league.html",
        page: "admin_fixtures-league",
      },
    ],
  },
  {
    id: "assign_cups",
    label: "Assign Cups",
    items: [
      {
        label: "Setup Super8",
        href: "admin_fixtures-cups.html",
        cup: "super8",
        page: "admin_fixtures-cups",
      },
      {
        label: "Setup Plate",
        href: "admin_fixtures-cups.html",
        cup: "plate",
        page: "admin_fixtures-cups",
      },
      {
        label: "Setup Shield",
        href: "admin_fixtures-cups.html",
        cup: "shield",
        page: "admin_fixtures-cups",
      },
      {
        label: "Setup Spoon",
        href: "admin_fixtures-cups.html",
        cup: "bowl",
        page: "admin_fixtures-cups",
      },
      {
        label: "Setup League Cup",
        href: "admin_fixtures-cups.html",
        cup: "league_cup",
        page: "admin_fixtures-cups",
      },
    ],
  },
  {
    id: "cup_fixtures",
    label: "Cup Fixtures",
    items: [
      {
        label: "Assign byes",
        href: "admin_fixtures-cups.html",
        cup: "league_cup",
        page: "admin_fixtures-cups",
      },
      {
        label: "Draw cup fixtures",
        href: "admin_fixtures-cups.html",
        page: "admin_fixtures-cups",
      },
      {
        label: "Cup draw ceremony",
        href: "cup_draw.html",
        page: "cup_draw",
      },
    ],
  },
  {
    id: "create",
    label: "Pre-season transfers",
    items: [...TRANSFER_WINDOW_NAV_ITEMS],
  },
];

/** WIP admin tools — add links here as pages are built. */
export const SEASON_MGMT_IN_PROGRESS_NAV = [];

/** Shown first inside Season Management (direct links, no nested subgroup). */
export const SEASON_MGMT_ADMIN_NAV_TOP_LINKS = [
  CLUB_SEASON_CHECKLIST_NAV_ITEM,
  {
    label: "Apply fines",
    href: "admin_fines.html",
    page: "admin_fines",
  },
  {
    label: "Red card appeal review",
    href: "admin_prize_appeals.html",
    page: "admin_prize_appeals",
  },
];

/** Season Management workflow — Mid Season / Playoffs / Close Season. */
export const SEASON_MGMT_ADMIN_NAV = [
  {
    id: "in_progress",
    label: "In Progress",
    items: SEASON_MGMT_IN_PROGRESS_NAV,
  },
  {
    id: "mid_season",
    label: "Mid Season",
    items: [
      ...TRANSFER_WINDOW_NAV_ITEMS,
      CHALLENGE_PAYOUTS_NAV_ITEM,
    ],
  },
  {
    id: "playoffs",
    label: "Playoffs",
    items: [
      {
        label: "Assign playoff positions",
        href: "admin_fixtures-playoffs.html",
        page: "admin_fixtures-playoffs",
      },
    ],
  },
  {
    id: "close",
    label: "Close Season",
    items: [
      CHALLENGE_PAYOUTS_NAV_ITEM,
      {
        label: "Archive season stats & awards",
        href: "admin_season.html",
        hash: "wf-close-season",
        page: "admin_season",
      },
      {
        label: "End current season",
        href: "admin_season.html",
        hash: "wf-close-season",
        page: "admin_season",
      },
    ],
  },
];

export function seasonAdminNavHref(item) {
  if (!item?.href) return "#";
  if (item.cup) {
    return `${item.href}?cup=${encodeURIComponent(item.cup)}`;
  }
  if (item.hash) {
    return `${item.href}#${item.hash}`;
  }
  return item.href;
}

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function navArrayHasActive(navArray, pathname, search = "", topLinks = []) {
  for (const item of topLinks) {
    if (isSeasonAdminNavItemActive(item, pathname, search)) return true;
  }
  for (const group of navArray) {
    for (const item of group.items) {
      if (isSeasonAdminNavItemActive(item, pathname, search)) return true;
    }
  }
  return false;
}

/** Admin flyout: mega label → category → task link (3 levels). */
function renderSeasonMegaNavHtml(
  navArray,
  megaLabel,
  pathname,
  search = "",
  { topLinks = [] } = {}
) {
  const linkActive = (item) => isSeasonAdminNavItemActive(item, pathname, search);
  const megaOpen = navArrayHasActive(navArray, pathname, search, topLinks);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel(megaLabel))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const item of topLinks) {
    const href = seasonAdminNavHref(item);
    const active = linkActive(item);
    html += `<a href="${escapeNavText(href)}" class="nav-link nav-link-sub nav-link-mega-top${
      active ? " active" : ""
    }">${escapeNavText(formatNavLabel(item.label))}</a>`;
  }

  for (const group of navArray) {
    html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
    html += `<button type="button" class="nav-subgroup-summary" aria-expanded="false">${escapeNavText(
      formatNavLabel(group.label)
    )}</button>`;
    html += `<div class="nav-subgroup-panel" role="group">`;
    for (const item of group.items) {
      const href = seasonAdminNavHref(item);
      const active = linkActive(item);
      html += `<a href="${escapeNavText(href)}" class="nav-link nav-link-sub${
        active ? " active" : ""
      }">${escapeNavText(formatNavLabel(item.label))}</a>`;
    }
    html += `</div></div>`;
  }

  html += `</div></div>`;
  return html;
}

export function seasonAdminNavHasActive(pathname, search = "") {
  return navArrayHasActive(SEASON_ADMIN_NAV, pathname, search, SEASON_ADMIN_NAV_TOP_LINKS);
}

export function renderSeasonAdminNavHtml(pathname, search = "") {
  return renderSeasonMegaNavHtml(SEASON_ADMIN_NAV, "Pre-Season", pathname, search, {
    topLinks: SEASON_ADMIN_NAV_TOP_LINKS,
  });
}

export function seasonMgmtAdminNavHasActive(pathname, search = "") {
  return navArrayHasActive(SEASON_MGMT_ADMIN_NAV, pathname, search, SEASON_MGMT_ADMIN_NAV_TOP_LINKS);
}

export function renderSeasonMgmtAdminNavHtml(pathname, search = "") {
  return renderSeasonMegaNavHtml(SEASON_MGMT_ADMIN_NAV, "Season Management", pathname, search, {
    topLinks: SEASON_MGMT_ADMIN_NAV_TOP_LINKS,
  });
}

export function isSeasonAdminNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;

  const hash = (window.location.hash || "").replace("#", "");
  if (item.hash) {
    return hash === item.hash;
  }

  if (item.cup && file === "admin_fixtures-cups.html") {
    const params = new URLSearchParams(search || window.location.search);
    return (params.get("cup") || "") === item.cup;
  }

  if (file === "admin_fixtures-cups.html" && !item.cup) {
    return true;
  }

  return true;
}
