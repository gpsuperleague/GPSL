/** GPSL top navigation — single source of links (pages unchanged). */

import { APP_VERSION } from "./app_version.js";

/** Bumped when admin nav structure changes — keeps dynamic import cache fresh. */
export const NAV_CONFIG_VERSION = APP_VERSION;

const testingNavMod = await import(
  `./admin_testing_nav.js?v=${NAV_CONFIG_VERSION}`
);
const adminMainNavMod = await import(
  `./admin_main_nav.js?v=${NAV_CONFIG_VERSION}`
);
const modNavMod = await import(`./mod_nav.js?v=${NAV_CONFIG_VERSION}`);

export const MOD_NAV_SECTION = modNavMod.MOD_NAV_SECTION;

const { testingAdminNavHasActive, renderTestingAdminNavHtml } = testingNavMod;
const {
  renderAdminMainSectionHtml,
  adminMainSectionHasActive,
} = adminMainNavMod;
const { renderModMenuPreviewHtml, modMenuPreviewHasActive } = modNavMod;

/** Render Admin mega-menu blocks (adminMainMega + Testing + Mod preview). */
export function renderAdminMegaNavHtml(item, pathname, search = "") {
  if (item?.adminMainMega && item.section) {
    return renderAdminMainSectionHtml(item.section, pathname, search);
  }
  if (item?.testingMega) {
    return renderTestingAdminNavHtml(pathname, search);
  }
  if (item?.modPreviewMega) {
    return renderModMenuPreviewHtml(pathname, search);
  }
  return "";
}

export const NAV_SECTIONS = [
  {
    id: "myclub",
    label: "My Club",
    items: [
      {
        href: "boardroom.html",
        label: "Boardroom",
        page: "boardroom",
        navIcon: "boardroom",
      },
      {
        href: "club_details.html",
        label: "Club Details",
        page: "club_details",
        navIcon: "club_details",
      },
      {
        href: "owner_details.html",
        label: "Owner Details",
        page: "owner_details",
        navIcon: "owner_details",
      },
      {
        href: "finances.html",
        label: "Club Finances",
        page: "finances",
        navIcon: "finances",
      },
      {
        href: "owners_bank.html",
        label: "GPSL Building Society",
        page: "owners_bank",
        indent: true,
        navIcon: "building_society",
      },
      { href: "squad.html", label: "Squad", page: "squad" },
      {
        href: "history.html",
        label: "Club History",
        page: "history",
        navIcon: "club_history",
      },
      {
        href: "stadium.html",
        label: "Stadium",
        page: "stadium",
        navIcon: "stadium",
      },
      {
        href: "medical_room.html",
        label: "Medical Room",
        page: "medical_room",
        navIcon: "first_aid",
      },
      {
        href: "club_prizes.html",
        label: "Rewards Centre",
        page: "club_prizes",
        navIcon: "rewards",
      },
      {
        href: "club_challenges.html",
        label: "Challenges",
        page: "club_challenges",
        navIcon: "challenges",
      },
      {
        href: "matchday.html",
        label: "Match Day",
        page: "matchday",
        navIcon: "matchday",
      },
      {
        href: "club_fixtures.html",
        label: "Fixtures",
        page: "club_fixtures",
        navIcon: "fixtures",
      },
      {
        href: "club_friendlies.html",
        label: "Friendlies",
        page: "club_friendlies",
        navIcon: "friendlies",
      },
      {
        href: "transfer_center.html",
        label: "Transfer Centre",
        page: "transfer_center",
        navIcon: "transfer_center",
      },
      {
        href: "transfer_center.html#scouting-targets",
        label: "Scouting Targets",
        page: "transfer_center",
        hash: "scouting-targets",
        indent: true,
        navIcon: "scouting_targets",
      },
      {
        href: "scouting.html",
        label: "Scouting board",
        page: "scouting",
        indent: true,
        navIcon: "scouting_board",
      },
    ],
  },
  {
    id: "mynation",
    label: "My Nation",
    items: [
      { href: "national_team.html", label: "National team", page: "national_team" },
      { href: "international_matchday.html", label: "Intl matchday", page: "international_matchday" },
      {
        href: "nation_select.html",
        label: "Nation selection",
        page: "nation_select",
        navIcon: "nation_select",
      },
      {
        href: "nation_player_pool.html",
        label: "Nation player pool",
        page: "nation_player_pool",
        navIcon: "nation_player_pool",
      },
    ],
  },
  {
    id: "league",
    label: "League",
    items: [
      { href: "clubs.html", label: "Clubs", page: "clubs", navIcon: "clubs" },
      {
        href: "fixtures.html",
        label: "Fixtures",
        page: "fixtures",
        navIcon: "fixtures",
      },
      {
        href: "progress.html",
        label: "Tables",
        page: "progress",
        navIcon: "tables",
      },
      {
        href: "playoffs.html",
        label: "Playoffs",
        page: "playoffs",
        showWhenGpslMonth: "playoffs",
        showForAdmin: true,
        navIcon: "playoffs",
      },
      {
        href: "league_stats.html",
        label: "Stats",
        page: "league_stats",
        navIcon: "stats",
      },
      {
        href: "league_records.html",
        label: "League Records",
        page: "league_records",
        navIcon: "stats",
      },
      {
        href: "owner_of_the_month.html",
        label: "Owner of the Month",
        page: "owner_of_the_month",
        navIcon: "owner_of_the_month",
      },
      {
        href: "league_injuries.html",
        label: "Injuries",
        page: "league_injuries",
        navIcon: "injuries",
      },
      {
        href: "challenges.html",
        label: "Season Challenges",
        page: "challenges",
        navIcon: "challenges",
      },
    ],
  },
  {
    id: "cups",
    label: "Cups",
    items: [
      // Top-level cup pages (not under Prestige Cups)
      {
        href: "cups.html?cup=league_cup",
        label: "League Cup",
        page: "cups",
        cup: "league_cup",
        navIcon: "league_cup",
      },
      {
        href: "world_cup.html",
        label: "World Cup",
        page: "world_cup",
        navIcon: "world_cup",
      },
      {
        href: "cup_records.html",
        label: "Cup Records",
        page: "cup_records",
        navIcon: "stats",
      },
      { heading: true, label: "Prestige Cups" },
      {
        href: "cups.html?cup=super8",
        label: "Super8",
        page: "cups",
        cup: "super8",
        indent: true,
        navIcon: "super8",
      },
      {
        href: "cups.html?cup=plate",
        label: "Plate",
        page: "cups",
        cup: "plate",
        indent: true,
        navIcon: "plate",
      },
      {
        href: "cups.html?cup=shield",
        label: "Shield",
        page: "cups",
        cup: "shield",
        indent: true,
        navIcon: "shield",
      },
      {
        href: "cups.html?cup=bowl",
        label: "Bowl",
        page: "cups",
        cup: "bowl",
        indent: true,
        navIcon: "bowl",
      },
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
        navIcon: "player_database",
      },
      {
        href: "all_listings.html",
        label: "Transfer Market",
        page: "all_listings",
        indent: true,
        listingNav: "player",
        navIcon: "transfer_market",
      },
      {
        href: "handpick_squad.html",
        label: "Handpick Squad",
        page: "handpick_squad",
        indent: true,
        navIcon: "player_database",
      },
      {
        href: "draftauction.html",
        label: "Player Draft Auctions",
        page: "draftauction",
        indent: true,
        auctionNav: "player",
        navIcon: "player_draft",
      },
      {
        href: "legacy_players.html",
        label: "Legacy Players",
        page: "legacy_players",
        indent: true,
        navIcon: "legacy_players",
      },
      {
        href: "expiring_contracts.html",
        label: "Expiring Contracts",
        page: "expiring_contracts",
        indent: true,
        auctionNav: "expiring",
        navIcon: "expiring_contracts",
      },
      {
        href: "season_transfers.html",
        label: "Seasons Player Transfers",
        page: "season_transfers",
        indent: true,
        navIcon: "season_player_transfers",
      },
      {
        href: "special_auction.html",
        label: "Special Auction",
        page: "special_auction",
        indent: true,
        auctionNav: "special",
        requiresSpecialAuction: true,
        navIcon: "special_auction",
      },
      {
        href: "nextgen_youth.html",
        label: "Next Gen Youth",
        page: "nextgen_youth",
        indent: true,
        navIcon: "nextgen_youth",
      },
      { heading: true, label: "Managers" },
      {
        href: "MGDB.html",
        label: "Manager Database",
        page: "mgdb",
        indent: true,
        auctionNav: "manager",
        navIcon: "manager_database",
      },
      {
        href: "manager_listings.html",
        label: "Manager Market",
        page: "manager_listings",
        indent: true,
        listingNav: "manager",
        navIcon: "manager_market",
      },
      {
        href: "manager_draftauction.html",
        label: "Manager Draft Auction",
        page: "manager_draftauction",
        indent: true,
        auctionNav: "manager",
        navIcon: "manager_draft",
      },
      {
        href: "season_manager_transfers.html",
        label: "Seasons Manager Transfers",
        page: "season_manager_transfers",
        indent: true,
        navIcon: "season_manager_transfers",
      },
      { heading: true, label: "Clubs" },
      {
        href: "club_database.html",
        label: "Club Database",
        page: "club_database",
        indent: true,
        auctionNav: "club",
        navIcon: "club_database",
      },
      {
        href: "club_auction.html",
        label: "Club Auction",
        page: "club_auction",
        indent: true,
        auctionNav: "club",
        navIcon: "club_auction",
      },
      {
        href: "season_club_purchases.html",
        label: "Season Club Purchases",
        page: "season_club_purchases",
        indent: true,
        navIcon: "season_club_purchases",
      },
    ],
  },
  {
    id: "central_bank",
    label: "Central Bank",
    items: [
      {
        href: "central_bank.html",
        label: "Bank balance",
        page: "central_bank",
        indent: true,
        navIcon: "bank_balance",
      },
      {
        href: "central_bank_loans.html",
        label: "League loans",
        page: "central_bank_loans",
        indent: true,
        navIcon: "league_loans",
      },
      {
        href: "central_bank_counter.html",
        label: "Service counter",
        page: "central_bank_counter",
        indent: true,
        navIcon: "service_counter",
      },
    ],
  },
  {
    id: "owners",
    label: "Owners",
    items: [
      { heading: true, label: "Knowledge" },
      {
        href: "learning_gpsl.html",
        label: "Learning GPSL",
        page: "learning_gpsl",
        indent: true,
        navIcon: "learning_gpsl",
      },
      {
        href: "video_tutorials.html",
        label: "Video tutorials",
        page: "video_tutorials",
        indent: true,
        navIcon: "video_tutorials",
      },
      { heading: true, label: "Community" },
      {
        href: "natter.html",
        label: "Natter",
        page: "natter",
        indent: true,
        navIcon: "natter",
      },
      {
        href: "feedback_survey.html",
        label: "Feedback survey",
        page: "feedback_survey",
        indent: true,
        navIcon: "feedback_survey",
      },
      { heading: true, label: "Play & spend" },
      {
        href: "bookies.html",
        label: "Bookies",
        page: "bookies",
        indent: true,
        navIcon: "bookies",
      },
      {
        href: "owners_shop.html",
        label: "Owners Shop",
        page: "owners_shop",
        indent: true,
        navIcon: "owners_shop",
      },
      {
        href: "challenges.html",
        label: "Season Challenges",
        page: "challenges",
        indent: true,
        navIcon: "challenges",
      },
      { heading: true, label: "Games" },
      {
        href: "fantasy.html",
        label: "GP Fantasy League",
        page: "fantasy",
        indent: true,
        navIcon: "fantasy",
      },
      {
        href: "https://38-0.app/",
        label: "38-0-0",
        external: true,
        indent: true,
        navIcon: "game_380",
      },
      { heading: true, label: "Season" },
      {
        href: "season_calendar.html",
        label: "Season Calendar",
        page: "season_calendar",
        indent: true,
        navIcon: "season_calendar",
      },
      {
        href: "owner_calendar.html",
        label: "My Calendar",
        page: "owner_calendar",
        indent: true,
        navIcon: "owner_calendar",
      },
      {
        href: "season_review.html",
        label: "Season Review",
        page: "season_review",
        indent: true,
        navIcon: "season_review",
      },
      { heading: true, label: "Owners directory" },
      {
        href: "fun_records.html",
        label: "Fun Records",
        page: "fun_records",
        indent: true,
        navIcon: "owner_rankings",
      },
      {
        href: "owner_rankings.html",
        label: "Rankings",
        page: "owner_rankings",
        indent: true,
        navIcon: "owner_rankings",
      },
      {
        href: "owner_last_login.html",
        label: "Last Login",
        page: "owner_last_login",
        indent: true,
        navIcon: "owner_last_login",
      },
      {
        href: "waiting_list.html",
        label: "Waiting List",
        page: "waiting_list",
        indent: true,
        navIcon: "waiting_list",
      },
      {
        href: "owner_holidays_board.html",
        label: "Owner Holidays",
        page: "owner_holidays_board",
        indent: true,
        navIcon: "owner_holidays",
      },
      {
        href: "owners_match_system.html",
        label: "Match System",
        page: "owners_match_system",
        indent: true,
        navIcon: "match_system",
      },
      { heading: true, label: "My account" },
      {
        href: "owner_profile.html",
        label: "My Profile",
        page: "owner_profile",
        indent: true,
        navIcon: "owner_profile",
      },
    ],
  },
];

/** New primary Admin workflow — # sections from admin_main_nav.js */
export const ADMIN_NAV_SECTION = {
  id: "admin",
  label: "Admin",
  items: [
    {
      href: "admin_workflow_checklist.html",
      label: "Admin checklist",
      page: "admin_workflow_checklist",
      navChecklist: true,
    },
    { testingMega: true, label: "Testing" },
    { adminMainMega: true, section: "owners", label: "Owners" },
    {
      modPreviewMega: true,
      label: "Mod menu (preview)",
    },
    { adminMainMega: true, section: "season_break", label: "Season Break" },
    { adminMainMega: true, section: "create_season", label: "Create Season" },
    { adminMainMega: true, section: "pre_season_setup", label: "Pre-Season setup" },
    { adminMainMega: true, section: "pre_season", label: "Pre-Season (June & July)" },
    { adminMainMega: true, section: "season_management", label: "Season Management" },
    { adminMainMega: true, section: "close_season", label: "Close Season" },
    { adminMainMega: true, section: "end_of_season", label: "End Of Season" },
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
    if (item.adminMainMega && item.section) {
      return adminMainSectionHasActive(item.section, pathname, search);
    }
    if (item.testingMega) {
      return testingAdminNavHasActive(pathname, search);
    }
    if (item.modPreviewMega) {
      return modMenuPreviewHasActive(pathname, search);
    }
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
