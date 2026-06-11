/** Season management workflow — shared by admin nav + admin_season.html sidebar */

export const SEASON_ADMIN_NAV = [
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
        cup: "spoon",
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
        label: "Challenge payouts",
        href: "admin_challenges.html",
        page: "admin_challenges",
      },
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

/** Flat list for Admin dropdown (nav_config). */
export function seasonAdminNavItemsForFlyout() {
  const out = [
    { href: "admin_season.html", label: "Season management", page: "admin_season" },
  ];
  for (const group of SEASON_ADMIN_NAV) {
    out.push({ heading: true, label: group.label });
    for (const item of group.items) {
      out.push({
        ...item,
        href: seasonAdminNavHref(item),
        indent: true,
      });
    }
  }
  return out;
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
