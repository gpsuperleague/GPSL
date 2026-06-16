import { formatNavLabel } from "./nav_label.js";

/** Season management workflow — shared by admin nav + admin_season.html sidebar */
export const SEASON_ADMIN_NAV_VERSION = "20260618-kickoff-first";

export const SEASON_ADMIN_NAV = [
  {
    id: "kickoff",
    label: "Kickoff",
    items: [
      {
        label: "Start new season",
        href: "admin_season.html",
        hash: "wf-kickoff",
        page: "admin_season",
      },
    ],
  },
  {
    id: "create",
    label: "Create New Season",
    items: [
      {
        label: "Set season calendar",
        href: "admin_season.html",
        hash: "wf-calendar",
        page: "admin_season",
      },
    ],
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
    id: "mid_season",
    label: "Mid Season",
    items: [
      {
        label: "Set transfer window open",
        href: "admin_transfers.html",
        page: "admin_transfers",
      },
      {
        label: "Set transfer window closed",
        href: "admin_transfers.html",
        page: "admin_transfers",
      },
    ],
  },
  {
    id: "close",
    label: "Close Season",
    items: [
      {
        label: "Challenge payouts",
        href: "admin_challenges.html",
        page: "admin_challenges",
      },
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

export function seasonAdminNavHasActive(pathname, search = "") {
  for (const group of SEASON_ADMIN_NAV) {
    for (const item of group.items) {
      if (isSeasonAdminNavItemActive(item, pathname, search)) return true;
    }
  }
  return false;
}

/** Admin flyout: Season management → category → task link (3 levels). */
export function renderSeasonAdminNavHtml(pathname, search = "") {
  const linkActive = (item) => isSeasonAdminNavItemActive(item, pathname, search);
  const megaOpen = seasonAdminNavHasActive(pathname, search);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel("Season management"))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const group of SEASON_ADMIN_NAV) {
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
