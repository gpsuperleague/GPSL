/** GPSL top navigation — single source of links (pages unchanged). */

/** Bumped when admin nav structure changes — keeps dynamic import cache fresh. */
export const NAV_CONFIG_VERSION = "20260621-nav-order";

const seasonNavMod = await import(
  `./admin_season_nav.js?v=${NAV_CONFIG_VERSION}`
);
const seasonBreakNavMod = await import(
  `./admin_season_break_nav.js?v=${NAV_CONFIG_VERSION}`
);
const ownerNavMod = await import(
  `./admin_owners_nav.js?v=${NAV_CONFIG_VERSION}`
);
const testingNavMod = await import(
  `./admin_testing_nav.js?v=${NAV_CONFIG_VERSION}`
);

const {
  seasonAdminNavHasActive,
  renderSeasonAdminNavHtml,
  seasonMgmtAdminNavHasActive,
  renderSeasonMgmtAdminNavHtml,
} = seasonNavMod;
const { seasonBreakNavHasActive, renderSeasonBreakNavHtml } = seasonBreakNavMod;
const { ownerAdminNavHasActive, renderOwnerAdminNavHtml } = ownerNavMod;
const { testingAdminNavHasActive, renderTestingAdminNavHtml } = testingNavMod;

/** Render admin mega-menu blocks (Testing, Season management, Season Break, Owners & accounts). */
export function renderAdminMegaNavHtml(item, pathname, search = "") {
  if (item?.testingMega) return renderTestingAdminNavHtml(pathname, search);
  if (item?.seasonMega) return renderSeasonAdminNavHtml(pathname, search);
  if (item?.seasonMgmtMega) return renderSeasonMgmtAdminNavHtml(pathname, search);
  if (item?.seasonBreakMega) return renderSeasonBreakNavHtml(pathname, search);
  if (item?.ownersMega) return renderOwnerAdminNavHtml(pathname, search);
  return "";
}

export const NAV_SECTIONS = [
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
      { href: "club_fixtures.html", label: "Fixtures", page: "club_fixtures" },
      { href: "transfer_center.html", label: "Transfer Centre", page: "transfer_center" },
      {
        href: "transfer_center.html#scouting-targets",
        label: "Scouting Targets",
        page: "transfer_center",
        hash: "scouting-targets",
        indent: true,
      },
      {
        href: "scouting.html",
        label: "Scouting board",
        page: "scouting",
        indent: true,
      },
    ],
  },
  {
    id: "mynation",
    label: "My Nation",
    items: [
      { href: "national_team.html", label: "National team", page: "national_team" },
      { href: "nation_select.html", label: "Nation selection", page: "nation_select" },
      { href: "nation_player_pool.html", label: "Nation player pool", page: "nation_player_pool" },
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
      // Top-level cup pages (not under Prestige Cups)
      { href: "cups.html?cup=league_cup", label: "League Cup", page: "cups", cup: "league_cup" },
      { href: "world_cup.html", label: "World Cup", page: "world_cup" },
      { heading: true, label: "Prestige Cups" },
      { href: "cups.html?cup=super8", label: "Super8", page: "cups", cup: "super8", indent: true },
      { href: "cups.html?cup=plate", label: "Plate", page: "cups", cup: "plate", indent: true },
      { href: "cups.html?cup=shield", label: "Shield", page: "cups", cup: "shield", indent: true },
      { href: "cups.html?cup=bowl", label: "Bowl", page: "cups", cup: "bowl", indent: true },
    ],
  },
  {
    id: "transfers",
    label: "Transfers",
    items: [
      { heading: true, label: "Players" },
      {
        href: "GPDB.html",
        label: "Player Database",
        page: "gpdb",
        indent: true,
        auctionNav: "player",
      },
      { href: "all_listings.html", label: "Transfer Market", page: "all_listings", indent: true },
      {
        href: "draftauction.html",
        label: "Player Draft Auctions",
        page: "draftauction",
        indent: true,
        auctionNav: "player",
      },
      {
        href: "legacy_players.html",
        label: "Legacy Players",
        page: "legacy_players",
        indent: true,
      },
      {
        href: "expiring_contracts.html",
        label: "Expiring Contracts",
        page: "expiring_contracts",
        indent: true,
      },
      {
        href: "season_transfers.html",
        label: "Seasons Player Transfers",
        page: "season_transfers",
        indent: true,
      },
      { heading: true, label: "Managers" },
      {
        href: "MGDB.html",
        label: "Manager Database",
        page: "mgdb",
        indent: true,
        auctionNav: "manager",
      },
      {
        href: "manager_listings.html",
        label: "Manager Market",
        page: "manager_listings",
        indent: true,
      },
      {
        href: "manager_draftauction.html",
        label: "Manager Draft Auction",
        page: "manager_draftauction",
        indent: true,
        auctionNav: "manager",
      },
      {
        href: "season_manager_transfers.html",
        label: "Seasons Manager Transfers",
        page: "season_manager_transfers",
        indent: true,
      },
      { heading: true, label: "Clubs" },
      {
        href: "club_database.html",
        label: "Club Database",
        page: "club_database",
        indent: true,
        auctionNav: "club",
      },
      {
        href: "club_auction.html",
        label: "Club Auction",
        page: "club_auction",
        indent: true,
        auctionNav: "club",
      },
      {
        href: "season_club_purchases.html",
        label: "Season Club Purchases",
        page: "season_club_purchases",
        indent: true,
      },
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
    id: "owners",
    label: "Owners",
    items: [
      { href: "learning_gpsl.html", label: "Learning GPSL", page: "learning_gpsl" },
      { href: "waiting_list.html", label: "Waiting list", page: "waiting_list" },
      { href: "owner_rankings.html", label: "Owner rankings", page: "owner_rankings" },
      { href: "challenges.html", label: "Season challenges", page: "challenges" },
    ],
  },
];

/** Admins only — appended in buildNav when isGpslAdminUser (same dropdown pattern as other sections). */
export const ADMIN_NAV_SECTION = {
  id: "admin",
  label: "Admin",
  items: [
    { testingMega: true, label: "Testing" },
    { seasonBreakMega: true, label: "Season Break" },
    { seasonMega: true, label: "Pre-Season" },
    { seasonMgmtMega: true, label: "Season Management" },
    { ownersMega: true, label: "Owners & accounts" },
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

  if (file === "admin_fixtures-cups.html" && item.cup) {
    const params = new URLSearchParams(search || window.location.search);
    return (params.get("cup") || "") === item.cup;
  }

  if (file === "admin_season.html") {
    const hash = (window.location.hash || "").replace("#", "");
    if (item.hash) return hash === item.hash;
    if (!item.hash && item.page === "admin_season") return !hash;
  }

  return true;
}

export function sectionHasActiveItem(section, pathname, search) {
  if (!section?.items?.length) return false;
  return section.items.some((item) => {
    if (item.testingMega) return testingAdminNavHasActive(pathname, search);
    if (item.seasonMega) return seasonAdminNavHasActive(pathname, search);
    if (item.seasonMgmtMega) return seasonMgmtAdminNavHasActive(pathname, search);
    if (item.seasonBreakMega) return seasonBreakNavHasActive(pathname, search);
    if (item.ownersMega) return ownerAdminNavHasActive(pathname, search);
    if (item.heading || !item.href) return false;
    return isNavItemActive(item, pathname, search);
  });
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
