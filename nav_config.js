/** GPSL top navigation — single source of links (pages unchanged). */

export const NAV_SECTIONS = [
  {
    id: "transfers",
    label: "Transfers",
    items: [
      { href: "GPDB.html", label: "Player Database", page: "gpdb" },
      { href: "MGDB.html", label: "Manager Database", page: "mgdb" },
      { href: "all_listings.html", label: "Transfer Market", page: "all_listings" },
      { href: "manager_listings.html", label: "Manager Market", page: "manager_listings" },
      {
        href: "draftauction.html",
        label: "Player Draft Auction",
        page: "draftauction",
      },
      {
        href: "manager_draftauction.html",
        label: "Manager Draft Auction",
        page: "manager_draftauction",
      },
      { href: "expiring_contracts.html", label: "Expiring Contracts", page: "expiring_contracts" },
      { href: "season_transfers.html", label: "Season Transfers", page: "season_transfers" },
    ],
  },
  {
    id: "central_bank",
    label: "Central Bank",
    items: [
      { href: "central_bank.html", label: "Bank balance", page: "central_bank", indent: true },
      { href: "central_bank_loans.html", label: "League loans", page: "central_bank_loans", indent: true },
      { href: "central_bank_counter.html", label: "Service counter", page: "central_bank_counter", indent: true },
    ],
  },
  {
    id: "league",
    label: "League",
    items: [
      { href: "clubs.html", label: "Clubs", page: "clubs" },
      { href: "fixtures.html", label: "Fixtures", page: "fixtures" },
      { href: "progress.html", label: "Tables", page: "progress" },
      { href: "league_stats.html", label: "Stats", page: "league_stats" },
      { href: "challenges.html", label: "Challenges", page: "challenges" },
    ],
  },
  {
    id: "cups",
    label: "Cups",
    items: [
      // Top-level cup page (not under Prestige Cups)
      { href: "cups.html?cup=league_cup", label: "League Cup", page: "cups", cup: "league_cup" },
      { heading: true, label: "Prestige Cups" },
      { href: "cups.html?cup=super8", label: "Super8", page: "cups", cup: "super8", indent: true },
      { href: "cups.html?cup=plate", label: "Plate", page: "cups", cup: "plate", indent: true },
      { href: "cups.html?cup=shield", label: "Shield", page: "cups", cup: "shield", indent: true },
      { href: "cups.html?cup=spoon", label: "Spoon", page: "cups", cup: "spoon", indent: true },
    ],
  },
  {
    id: "myclub",
    label: "My Club",
    items: [
      { href: "club_details.html", label: "Club Details", page: "club_details" },
      { href: "finances.html", label: "Finances", page: "finances" },
      { href: "squad.html", label: "Squad", page: "squad" },
      { href: "history.html", label: "Club History", page: "history" },
      { href: "stadium.html", label: "Stadium", page: "stadium" },
      { href: "matchday.html", label: "Match Day", page: "matchday" },
      { href: "transfer_center.html", label: "Transfer Centre", page: "transfer_center" },
      {
        href: "transfer_center.html#scouting-targets",
        label: "Scouting Targets",
        page: "transfer_center",
        hash: "scouting-targets",
        indent: true,
      },
    ],
  },
  {
    id: "owners",
    label: "Owners",
    items: [
      { href: "owner_rankings.html", label: "Owner rankings", page: "owner_rankings" },
      { href: "challenges.html", label: "Season challenges", page: "challenges" },
      { href: "nation_select.html", label: "Nation selection", page: "nation_select" },
      { href: "national_team.html", label: "National team", page: "national_team" },
    ],
  },
];

/** Admins only — appended in buildNav when isGpslAdminUser (same dropdown pattern as other sections). */
export const ADMIN_NAV_SECTION = {
  id: "admin",
  label: "Admin",
  items: [
    { heading: true, label: "Season management" },
    { href: "admin_season.html", label: "Season & calendar" },

    { heading: true, label: "Fixture management" },
    { href: "admin_fixtures-league.html", label: "League fixtures" },
    { href: "admin_fixtures-cups.html", label: "Cup fixtures" },
    { href: "admin_fixtures-playoffs.html", label: "Playoff fixtures" },

    { heading: true, label: "Money management" },
    { href: "admin_money.html", label: "Prizes, wages & gates" },
    { href: "admin_cup_prizes.html", label: "Cup prize money", indent: true },
    { href: "admin_club_attendance.html", label: "Club attendance & prestige" },
    { href: "admin_challenges.html", label: "Season challenges" },
    { href: "admin_fines.html", label: "Fines & compensation" },

    { heading: true, label: "Transfer management" },
    { href: "admin_transfers.html", label: "Transfer window & engine" },
    { href: "admin_draft.html", label: "Draft auction" },
    { href: "admin_manager_targets.html", label: "Manager contract targets" },
    { href: "admin_special-auctions.html", label: "Special auction" },

    { heading: true, label: "Owner administration" },
    { href: "admin_owners.html", label: "Owners & accounts" },

    { heading: true, label: "International" },
    { href: "admin_international.html", label: "World Cup & nations" },
  ],
};

export function normalizeNavPath(pathname) {
  const p = (pathname || "").toLowerCase().replace(/\\/g, "/");
  const file = p.split("/").pop() || "";
  return file;
}

export function isNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = normalizeNavPath(pathname);
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();

  if (file !== itemFile) return false;

  const hash = (window.location.hash || "").replace("#", "");

  if (file === "transfer_center.html") {
    if (item.hash) return hash === item.hash;
    if (hash === "scouting-targets") return false;
  }

  if (item.hash) {
    return hash === item.hash;
  }

  if (file === "cups.html" && item.cup) {
    const params = new URLSearchParams(search || window.location.search);
    const cup = params.get("cup") || "league_cup";
    return cup === item.cup;
  }

  if (file === "cups.html" && !item.cup) {
    return true;
  }

  return true;
}

export function sectionHasActiveItem(section, pathname, search) {
  if (!section?.items?.length) return false;
  return section.items.some((item) => isNavItemActive(item, pathname, search));
}

/**
 * Which nav dropdown to auto-open on load.
 * Shared pages (e.g. league_stats) appear under multiple sections — only open one.
 */
export function firstActiveNavSectionId(sections, pathname, search, resolveItems) {
  for (const section of sections || []) {
    const items = resolveItems ? resolveItems(section) : section.items;
    if (!items?.length) continue;
    if (sectionHasActiveItem({ items }, pathname, search)) {
      return section.id;
    }
  }
  return null;
}
