import { formatNavLabel } from "./nav_label.js";
import { flattenTestingAdminNav } from "./admin_testing_nav.js";

/**
 * Primary Admin workflow menu (new).
 * # sections → top-level Admin mega subgroups
 * ~ groups → nested headers
 * links → pages (hash when needed)
 *
 * This file is the source of truth for the live Admin mega-menus, Admin
 * checklist, and season / season-break page sidebars.
 *
 * Testing links: maintain only in admin_testing_nav.js (TESTING_ADMIN_NAV).
 *
 * After editing this file (or admin_testing_nav.js), bump APP_VERSION in
 * app_version.js — otherwise browsers keep the old menu via module cache.
 */

function L(label, href, hash = null, page = null, note = null) {
  const item = { label, href };
  if (hash) item.hash = hash;
  if (page) item.page = page;
  else if (href) {
    item.page = href.replace(/\.html.*$/i, "").replace(/-/g, "_");
  }
  if (note) item.note = note;
  return item;
}

function link(label, href, hash = null, note = null) {
  return { type: "link", ...L(label, href, hash, null, note) };
}

function group(label, items = []) {
  return { type: "group", label, items };
}

export const ADMIN_MAIN_NAV = [
  {
    id: "testing",
    label: "Testing",
    // Kept for checklist exclusion / section id only — live menu uses testingMega.
    entries: flattenTestingAdminNav().map((item) => link(item.label, item.href)),
  },
  {
    id: "owners",
    label: "Owners",
    entries: [
      group("Waiting list", [
        L("Staff alerts", "admin_staff_alerts.html"),
        L("Manage waiting list", "admin_owners_waiting_list.html"),
        L("Owner Last Login", "admin_owners_waiting_list.html", "owner-last-login"),
        L("Discord join order", "admin_owners_discord.html"),
      ]),
      group("Mods", [L("Manage mods", "admin_mods.html")]),
      group("Discord feeds", [
        L("Discord News Feed", "admin_discord_news.html"),
        L("Discord Friendlies", "admin_discord_friendlies.html"),
        L("Transfer Gossip", "admin_discord_transfer_gossip.html"),
      ]),
      group("New owners", [
        L("Create New Owner & Add to Waiting List", "admin_owners_add_member.html"),
        L("Create New Owner & Add Directly to Club", "admin_owners_add_direct.html"),
      ]),
      group("Club assignment", [
        L("Link existing login to club", "admin_owners_link.html"),
        L("Change Owner Club", "admin_owners_change_club.html"),
        L("Remove Owner From Club", "admin_owners_remove.html"),
      ]),
      group("Archive", [
        L("Archive Owner (left GPSL)", "admin_owners_archive.html"),
        L("Unarchive Owner (return to GPSL)", "admin_owners_unarchive.html"),
      ]),
      group("Login & email", [
        L("Set Owner Tag", "admin_owners_tag.html"),
        L("Update Email", "admin_owners_email.html"),
        L("Set Password", "admin_owners_password.html"),
        L("Send Reset Email", "admin_owners_reset.html"),
      ]),
      group("Natter", [L("Remove Natter posts", "admin_natter.html")]),
    ],
  },
  {
    id: "create_season",
    label: "Create Season",
    entries: [
      link(
        "Create Pre-Season",
        "admin_season.html",
        "wf-kickoff",
        "Do this AFTER Close Finances + End season. Creates Season N+1 and ticks player contracts: expiry wage bids / FA releases post money to the NEW season (not the closed year). Run patches/contract_expiry_rollover_new_season_ledger.sql first. If the browser times out, use Tick contracts only / SQL catch-up."
      ),
      link(
        "GPDB Player Exclusions",
        "admin_gpdb_exclusions.html",
        null,
        "Needs the new season number (after Create Pre-Season). Exclude players / nations from GPDB import, transfers, and call-ups for that season."
      ),
      group("Internationals", [
        L(
          "Nation Setup",
          "admin_international.html",
          "sb-nation-setup",
          null,
          "Confirm nations and international competition setup."
        ),
        L(
          "Clear Nation Assignments",
          "admin_international_selection_clear.html",
          null,
          null,
          "Clear nation squad assignments (repair / reset)."
        ),
      ]),
      link(
        "Tick player contracts (catch-up)",
        "admin_season.html",
        "wf-kickoff",
        "Only if Create Pre-Season did not finish the tick. Same expiry resolve → new-season ledger. Skips if already logged for that preseason."
      ),
      group("Prize Money", [
        L(
          "Cup Prize Money",
          "admin_cup_prizes.html",
          null,
          null,
          "Review / set cup prize tables for the upcoming season (after Create Pre-Season)."
        ),
        L(
          "League Prize Money",
          "admin_league_prizes.html",
          null,
          null,
          "Review / set league finishing prize tables per division (after Create Pre-Season)."
        ),
      ]),
      group("Assign divisions", [
        L(
          "Setup Superleague Teams",
          "admin_season.html",
          "wf-divisions",
          null,
          "Place / confirm the 20 Super League clubs. Season 1: use Assign from prestige (top 20)."
        ),
        L(
          "Setup Championship Teams",
          "admin_season.html",
          "wf-divisions",
          null,
          "Place remaining clubs into Championship (prestige assign alternates A/B from rank 21, or use pool + random draw)."
        ),
        L(
          "Draw Championship Divisions",
          "admin_season.html",
          "wf-divisions",
          null,
          "Randomly split the Championship pool into Championship A and B (skip if you used Assign from prestige)."
        ),
      ]),
      link(
        "Create Season Calendar",
        "admin_season.html",
        "wf-calendar",
        "Build the GPSL month calendar for the new season (needed before going live)."
      ),
      link(
        "Start season (go live)",
        "admin_season.html",
        "wf-kickoff",
        "After Season Break + Pre-Season setup (divisions, calendar). Makes the new season current/active."
      ),
      link(
        "Create League Fixtures",
        "admin_fixtures-league.html",
        null,
        "Generate the full league fixture list for Super League and both Championships."
      ),
      link(
        "Setup Cups",
        "admin_fixtures-cups.html",
        null,
        "Configure / draw domestic cups for the new season."
      ),
    ],
  },
  {
    id: "season_break",
    label: "Season Break",
    entries: [
      group("GPDB Update", [
        L(
          "GPDB Player Sync",
          "admin_gpdb_sync.html",
          null,
          null,
          "Pull latest player data from GPDB into GPSL (ratings, attributes, etc.)."
        ),
        L(
          "GPDB Player Deduplication",
          "admin_gpdb_dedup.html",
          null,
          null,
          "Merge / resolve duplicate player records after a sync."
        ),
      ]),
      group("Auctions", [
        L(
          "Auction Exclusions",
          "admin_auction_exclusions.html",
          null,
          null,
          "Exclude specific players from draft / auction pools."
        ),
      ]),
      group("Club Management", [
        L(
          "Archive / Add clubs",
          "admin_club_management.html",
          null,
          null,
          "Soft-archive clubs (history kept) or create vacant clubs for assignment / auction."
        ),
        L(
          "Upload Club Badge",
          "admin_club_management.html#upload-badge",
          null,
          null,
          "Upload a Wikipedia PNG/SVG crest to images/club_badges/{ShortName}.png on GitHub."
        ),
        L(
          "Assign Manager to club",
          "admin_test_manager_assign.html",
          null,
          null,
          "Sign a manager directly to a club (bypasses draft / transfer market)."
        ),
        L(
          "Club checker",
          "admin_club_checker.html",
          null,
          null,
          "Freeform lookup: StadiumDB image, COF kits, and Wikipedia club page."
        ),
        L(
          "Download Latest Kits",
          "admin_club_kits.html",
          null,
          null,
          "Refresh club kit images for the new season."
        ),
        L(
          "Download Club Stadiums",
          "admin_club_stadiums.html",
          null,
          null,
          "Fetch stadium photos from StadiumDB into images/stadiums/."
        ),
      ]),
      group("Weather", [
        L(
          "Weather & Pitch conditions",
          "admin_weather.html",
          null,
          null,
          "Configure weather and pitch condition tables used on matchday."
        ),
      ]),
    ],
  },
  {
    id: "pre_season_setup",
    label: "Pre-Season setup",
    entries: [
      group("Youth & Homegrown", [
        L(
          "Refresh Next Gen Youth",
          "admin_nextgen_youth.html",
          null,
          null,
          "Regenerate / refresh the Next Gen youth pool for the coming season."
        ),
        L(
          "Homegrown Star Draw",
          "admin_one_of_our_own.html",
          null,
          null,
          "Run the One of our Own / homegrown star draw for eligible clubs."
        ),
      ]),
      group("Club, Stadium & Manager", [
        L(
          "Club Attendance & Prestige",
          "admin_club_attendance.html",
          null,
          null,
          "Update attendance bands and prestige for clubs."
        ),
        L(
          "Stadium Settings",
          "admin_stadium_settings.html",
          null,
          null,
          "Stadium capacity / upgrade / settings for the new season."
        ),
        L(
          "Manager Contract Targets",
          "admin_manager_targets.html",
          null,
          null,
          "Set or refresh manager board targets for the new season."
        ),
        L(
          "Import manager catalog",
          "admin_managers_import.html",
          null,
          null,
          "Upsert Managers from CSV (ratings/MV). Keeps contracts, career history, and IDs."
        ),
      ]),
      group("Challenges", [
        L(
          "Set Initial Season Challenges",
          "admin_challenges.html",
          null,
          null,
          "Publish start-of-season challenges for clubs."
        ),
      ]),
      group("Bills & Income", [
        L(
          "League finance balance",
          "admin_league_finance_balance.html",
          null,
          null,
          "Season P&L ecosystem check (ops profit vs target; transfers excluded)."
        ),
        L(
          "Set TV Revenue",
          "admin_tv_revenue.html",
          null,
          null,
          "Set TV / broadcast income figures for the season."
        ),
        L(
          "Set Government Subsidies",
          "admin_gov_subsidies.html",
          null,
          null,
          "Configure government subsidy amounts (paid later at close)."
        ),
        L(
          "Set 34+ Fee",
          "admin_tax_34.html",
          null,
          null,
          "Set the over-34 age fee (per player aged at/above the minimum)."
        ),
        L(
          "Set Star Fee",
          "admin_star_tax.html",
          null,
          null,
          "Set star-player fee / tax parameters."
        ),
        L(
          "Set Wage %",
          "admin_wage_pct.html",
          null,
          null,
          "Set wage-bill percentage rules for the season."
        ),
        L(
          "Set Tax %",
          "admin_tax_pct.html",
          null,
          null,
          "Set tax percentage parameters used in close finances."
        ),
        L(
          "Set stadium costs",
          "admin_stadium_costs.html",
          null,
          null,
          "Set stadium maintenance / cost tables for close finances."
        ),
      ]),
      group("Internationals", [
        L(
          "World Cup Cycle",
          "admin_international.html",
          "sb-wc-cycle",
          null,
          "Advance or configure the World Cup cycle when due."
        ),
        L(
          "Open Nation Selection",
          "admin_international_selection_open.html",
          null,
          null,
          "Open the window for owners to pick national team players."
        ),
        L(
          "Manual National Team Selection",
          "admin_international.html",
          "sb-nation-assign",
          null,
          "Admin override / assign national team squads if needed."
        ),
        L(
          "Close Nation Selection",
          "admin_international_selection_close.html",
          null,
          null,
          "Close the owner selection window when the deadline has passed."
        ),
        L(
          "Verify owner rankings",
          "admin_international.html",
          "sb-owner-rankings",
          null,
          "Check owner nation ranking inputs before internationals."
        ),
      ]),
    ],
  },
  {
    id: "pre_season",
    label: "Pre-Season (June & July)",
    entries: [
      group("Transfers", [
        L(
          "Set transfer window on/off",
          "admin_transfer_window.html",
          null,
          null,
          "Open or close the transfer window for pre-season trading."
        ),
      ]),
      group("Auctions", [
        L(
          "Set Draft Auction On/Off",
          "admin_transfers.html",
          null,
          null,
          "Enable or disable the player draft auction for pre-season."
        ),
        L(
          "Special Auction",
          "admin_special-auctions.html",
          null,
          null,
          "Configure or run a special auction event."
        ),
      ]),
      group("Managers", [
        L(
          "Import manager catalog",
          "admin_managers_import.html",
          null,
          null,
          "Upsert Managers from CSV. Keeps contracts and career history."
        ),
        L(
          "Process manager renewal deadline (before August)",
          "admin_season.html",
          "wf-close-season",
          null,
          "End of July / start of August: release managers still on pending renewal (club gets MV). Season-end “Process manager contracts” (Close Season) creates those offers in June/July — this deadline closes the window. Safe to re-run."
        ),
      ]),
    ],
  },
  {
    id: "season_management",
    label: "Season Management",
    entries: [
      group("Clubs & owners", [
        L(
          "Club Season Checklist",
          "admin_club_checklist.html",
          null,
          null,
          "Review owned clubs against season compliance rules (squad, manager, etc.)."
        ),
        L(
          "Season expectations",
          "admin_season_expectations.html",
          null,
          null,
          "Club/owner/manager board: prestige & manager expect vs actual, plus projected end-of-season consequences."
        ),
        L(
          "Owner holidays",
          "admin_owner_holidays.html",
          null,
          null,
          "View / manage owner holiday periods that affect arranging fixtures."
        ),
      ]),
      group("Finances", [
        L(
          "Preview club finances",
          "finances.html",
          null,
          null,
          "Open Finances with a club selector — view any club’s accounts as a staff preview (Admin/Mod)."
        ),
        L(
          "Preview club squad",
          "squad.html",
          null,
          null,
          "Open Squad with a club selector — view any club’s squad read-only (Admin/Mod). Inspect Action options without executing."
        ),
        L(
          "Apply fines",
          "admin_fines.html",
          null,
          null,
          "Issue admin fines to clubs (ledger + inbox)."
        ),
        L(
          "Inject cash",
          "admin_cash_injection.html",
          null,
          null,
          "Credit a fixed ₿ amount to all season clubs or selected clubs (admin_one_off_injection + inbox)."
        ),
        L(
          "Charge Emergency Tax",
          "admin_emergency_tax.html",
          null,
          null,
          "Debit a fixed ₿ amount from all or selected clubs (gov_emergency_tax + inbox). Also hosts season-end threshold % formula."
        ),
      ]),
      group("Appeals", [
        L(
          "Red card appeal review",
          "admin_prize_appeals.html",
          null,
          null,
          "Review owner red-card / prize appeals and apply outcomes."
        ),
      ]),
      group("Owners Shop", [
        L(
          "Shop catalogue & wallets",
          "admin_owners_shop.html",
          null,
          null,
          "Configure Owners Shop sections/prices; credit personal owner wallets. Buys stock items on the owner’s club."
        ),
      ]),
      group("Media", [
        L(
          "Republish GPSL Sport",
          "admin_gpsl_sport.html",
          null,
          null,
          "Rebuild / republish the GPSL Sport public pages after results or awards change."
        ),
      ]),
      group("Transfers", [
        L(
          "Cancel open listings & bids",
          "admin_transfers.html",
          "sb-cancel-open",
          null,
          "Soft-cancel open market/draft listings, bids, and pending direct offers (not completed sales)."
        ),
      ]),
    ],
  },
  {
    id: "season_checklist",
    label: "Season Checklist",
    entries: [
      group("August", [
        L(
          "Special Auction",
          "admin_special-auctions.html",
          null,
          null,
          "Run / close the August special auction if scheduled."
        ),
      ]),
      group("September", [
        L(
          "Close Transfer Window",
          "admin_transfer_window.html",
          "closed",
          null,
          "Close the summer transfer window for September."
        ),
      ]),
      group("October", []),
      group("November", []),
      group("December", [
        L(
          "Start of Season challenge Payouts",
          "admin_challenges.html",
          null,
          null,
          "Pay out start-of-season challenges once December criteria are met."
        ),
      ]),
      group("January", [
        L(
          "Set Mid-Season Challenges",
          "admin_challenges.html",
          null,
          null,
          "Publish mid-season challenges for the second half."
        ),
        L(
          "Special Auction",
          "admin_special-auctions.html",
          null,
          null,
          "Run the January special auction if scheduled."
        ),
        L(
          "Open Transfer Window",
          "admin_transfer_window.html",
          "open",
          null,
          "Open the January transfer window."
        ),
        L(
          "Close Transfer Window",
          "admin_transfer_window.html",
          "closed",
          null,
          "Close the January transfer window when the window ends."
        ),
      ]),
      group("February", []),
      group("March", []),
      group("April", []),
      group("May", [
        L(
          "Generate playoffs",
          "admin_fixtures-playoffs.html",
          null,
          null,
          "Usually auto on May lock — use if ties are missing, then continue under Playoffs."
        ),
      ]),
      group("Playoffs", [
        L(
          "Setup Playoffs",
          "admin_fixtures-playoffs.html",
          null,
          null,
          "Confirm playoff bracket / fixtures are in place."
        ),
        L(
          "Apply playoff movements",
          "admin_fixtures-playoffs.html",
          null,
          null,
          "Usually automatic when the SL playoff final is played. Use only to re-run/repair."
        ),
      ]),
    ],
  },
  {
    id: "close_season",
    label: "Close Season",
    entries: [
      link(
        "Mid-Season Challenge payouts",
        "admin_challenges.html",
        null,
        "Pay mid-season challenges that settle at season close."
      ),
      link(
        "Pay government subsidies",
        "admin_gov_subsidies.html",
        null,
        "Pay the configured government subsidies to clubs for the closing season."
      ),
      link(
        "Pay league prize money",
        "admin_league_prizes.html",
        null,
        "Confirm amounts per division, then Pay league prizes (only pays divisions with 38/38 played; safe to re-run)."
      ),
      link(
        "Archive season stats & awards",
        "admin_season.html",
        "wf-close-season",
        "Locks tables/awards (and an early finance snapshot). OK to run before Close Finances — Close Finances refreshes the finance archive afterward."
      ),
      link(
        "Ballon d'Or settings",
        "admin_ballon_settings.html",
        null,
        "Weights, min appearances, and trophy bonuses for Ballon d'Or / Championship Player of the Season."
      ),
      link(
        "GPFL (fantasy) settings",
        "admin_gpfl_settings.html",
        null,
        "Optional fantasy league: budget, squad slots, scoring (incl. yellows/reds), divisions. Play-money only."
      ),
      link(
        "Process manager contracts (season end)",
        "admin_season.html",
        "wf-close-season",
        "Resolve manager targets / renewals / releases for the ending season."
      ),
      link(
        "Charge Emergency Tax",
        "admin_emergency_tax.html",
        null,
        "Apply end-of-season emergency tax if required before Close Finances."
      ),
      link(
        "Close Finances",
        "admin_wage_bills.html",
        null,
        "LAST money step on the OLD season: wages + manager salary + 34+ + star tax → stadium maintenance → debt interest → FFP → balance interest, then refreshes season finance archive. Do this BEFORE End season / Create Pre-Season. Expiry transfers are NOT here — they post on Create Pre-Season to the new year."
      ),
    ],
  },
  {
    id: "end_of_season",
    label: "End Of Season",
    entries: [
      link(
        "End current season {summer break}",
        "admin_season.html",
        "wf-close-season",
        "Marks the season complete (not current). Next: Create Season → Create Pre-Season (contract tick + new-season ledger). Then work through the Season Break section (GPDB, kits, prizes…) — that is not Create Season."
      ),
    ],
  },
];

export function adminMainNavHref(item) {
  if (!item?.href) return "#";
  if (item.hash) return `${item.href}#${item.hash}`;
  return item.href;
}

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function getAdminMainSection(sectionId) {
  return ADMIN_MAIN_NAV.find((s) => s.id === sectionId) || null;
}

export function isAdminMainNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;

  const hash = (typeof window !== "undefined" ? window.location.hash || "" : "").replace("#", "");
  if (item.hash) return hash === item.hash;
  return true;
}

function entryHasActive(entry, pathname, search) {
  if (entry.type === "link") {
    return isAdminMainNavItemActive(entry, pathname, search);
  }
  if (entry.type === "group") {
    return (entry.items || []).some((item) => isAdminMainNavItemActive(item, pathname, search));
  }
  return false;
}

export function adminMainSectionHasActive(sectionId, pathname, search = "") {
  const section = getAdminMainSection(sectionId);
  if (!section) return false;
  if ((section.entries || []).some((e) => entryHasActive(e, pathname, search))) {
    return true;
  }
  // Season Checklist is nested under Season Management in the Admin menu
  if (sectionId === "season_management") {
    const checklist = getAdminMainSection("season_checklist");
    return (checklist?.entries || []).some((e) => entryHasActive(e, pathname, search));
  }
  return false;
}

export function adminMainNavHasActive(pathname, search = "") {
  return ADMIN_MAIN_NAV.some((s) => adminMainSectionHasActive(s.id, pathname, search));
}

/** Sections omitted from the manual Admin workflow checklist. */
export const ADMIN_CHECKLIST_EXCLUDE_SECTION_IDS = new Set(["testing", "owners"]);

/**
 * Checklist section order — same as Admin menu (Testing/Owners excluded).
 * Close Season / End Of Season sit at the end of the season year.
 */
export const ADMIN_CHECKLIST_SECTION_ORDER = [
  "first_season",
  "season_break",
  "create_season",
  "pre_season_setup",
  "pre_season",
  "season_management",
  "season_checklist",
  "close_season",
  "end_of_season",
];

/**
 * Stable key for checklist persistence (season-scoped in DB / localStorage).
 * @param {string} sectionId
 * @param {string|null} groupLabel
 * @param {{ label: string, href?: string, hash?: string }} item
 */
export function adminChecklistTaskKey(sectionId, groupLabel, item) {
  return [sectionId, groupLabel || "", item.label || "", item.href || "", item.hash || ""].join("|");
}

/**
 * Season dependency for Admin checklist highlighting.
 * @returns {"active"|"creates"|"activates"|"ends"|"season_row"|null}
 *   active     — needs a live/current season id
 *   creates    — creates Season N+1 (preseason row)
 *   activates  — makes a season current / go-live
 *   ends       — marks the current season complete
 *   season_row — needs a season id (preseason/setup or closing year OK)
 *   null       — no season id required (global / config / assets)
 */
export function checklistItemSeasonNeed(sectionId, item) {
  const label = String(item?.label || "");
  const href = String(item?.href || "");
  const hash = String(item?.hash || "");

  if (sectionId === "first_season") return null;

  if (sectionId === "create_season") {
    if (/Create Pre-Season/i.test(label)) return "creates";
    if (/Start season/i.test(label)) return "activates";
    if (/Tick player contracts/i.test(label)) return "season_row";
    if (/GPDB Player Exclusions/i.test(label) || /admin_gpdb_exclusions/i.test(href)) {
      return "season_row";
    }
    if (/Create Season Calendar|Create League Fixtures|Setup Cups|Setup Superleague|Setup Championship|Draw Championship/i.test(label)) {
      return "season_row";
    }
    if (/Prize Money|Cup Prize|League Prize/i.test(label)) return "season_row";
    return null;
  }

  if (sectionId === "season_break") {
    // GPDB sync/dedup / kits / weather / auction exclusions — not season-bound
    return null;
  }

  if (sectionId === "pre_season_setup") return "season_row";

  if (sectionId === "pre_season") {
    if (
      /transfer window|Draft Auction On\/Off|Special Auction/i.test(label) ||
      /admin_transfer_window|admin_transfers|admin_special/i.test(href)
    ) {
      return null;
    }
    return "season_row";
  }

  if (sectionId === "season_management") {
    if (/Cancel open listings/i.test(label)) return null;
    if (/Republish GPSL Sport/i.test(label)) return "season_row";
    return "active";
  }

  if (sectionId === "season_checklist") {
    if (/Push Discord|Discord queue/i.test(label)) return null;
    if (/Refresh Next Gen/i.test(label)) return "season_row";
    return "active";
  }

  if (sectionId === "close_season") return "active";

  if (sectionId === "end_of_season") return "ends";

  return null;
}

export const CHECKLIST_SEASON_NEED_META = {
  active: {
    short: "Needs active season",
    tip: "Requires a live/current competition season id.",
  },
  creates: {
    short: "Creates season",
    tip: "Creates the next Season N+1 preseason row.",
  },
  activates: {
    short: "Activates season",
    tip: "Makes the new season current / go-live.",
  },
  ends: {
    short: "Ends season",
    tip: "Marks the current season complete (summer break).",
  },
  season_row: {
    short: "Needs season #",
    tip: "Needs a season id (preseason/setup or the closing year) — not necessarily live.",
  },
};

/**
 * Flatten Admin menu into checklist sections (excludes Testing & Owners).
 * Empty groups (e.g. months with no tasks) are omitted.
 * Order: Season Break → Create Season → … → Close Season → End Of Season.
 * (GPDB exclusions / internationals nation setup / prize money under Create Season, after Create Pre-Season.)
 */
/** Day-zero / first-season setup (not in the normal Admin menu tree). */
function getFirstSeasonChecklistSection() {
  const items = [
    {
      label: "Club auction — seed vacant clubs",
      href: "admin_transfers.html",
      hash: "sb-club-auction",
      note: "Seed listings after owners are invited / awaiting club auction.",
    },
    {
      label: "Club draft auction",
      href: "admin_transfers.html",
      hash: "sb-draft-auctions",
      note: "Turn Club auction (new owners) on/off under Draft auctions & schedule, then Save.",
    },
    {
      label: "Manager draft auction",
      href: "admin_transfers.html",
      hash: "sb-draft-auctions",
      note: "Turn Manager draft auction on/off under Draft auctions & schedule, then Save.",
    },
    {
      label: "Player draft auction",
      href: "admin_transfers.html",
      hash: "sb-draft-auctions",
      note: "Turn Draft auction enabled (players) on/off under Draft auctions & schedule, then Save.",
    },
  ].map((item) => ({
    ...item,
    taskKey: adminChecklistTaskKey("first_season", "Auctions", item),
  }));

  return {
    id: "first_season",
    label: "First Season",
    blocks: [{ groupLabel: "Auctions", items }],
  };
}

export function getAdminWorkflowChecklist() {
  const byId = new Map();

  byId.set("first_season", getFirstSeasonChecklistSection());

  for (const section of ADMIN_MAIN_NAV) {
    if (ADMIN_CHECKLIST_EXCLUDE_SECTION_IDS.has(section.id)) continue;

    /** @type {{ groupLabel: string|null, items: Array<Record<string, unknown>> }[]} */
    const blocks = [];

    for (const entry of section.entries || []) {
      if (entry.type === "link") {
        blocks.push({
          groupLabel: null,
          items: [
            {
              ...entry,
              taskKey: adminChecklistTaskKey(section.id, null, entry),
            },
          ],
        });
        continue;
      }
      if (entry.type === "group") {
        const items = (entry.items || [])
          .filter((item) => item?.href)
          .map((item) => ({
            ...item,
            taskKey: adminChecklistTaskKey(section.id, entry.label, item),
          }));
        if (!items.length) continue;
        blocks.push({ groupLabel: entry.label, items });
      }
    }

    if (!blocks.length) continue;

    byId.set(section.id, {
      id: section.id,
      label: section.label,
      blocks,
    });
  }

  const sections = [];
  const seen = new Set();
  for (const id of ADMIN_CHECKLIST_SECTION_ORDER) {
    const sec = byId.get(id);
    if (!sec) continue;
    sections.push(sec);
    seen.add(id);
  }
  for (const [id, sec] of byId) {
    if (seen.has(id)) continue;
    sections.push(sec);
  }

  return sections;
}

function renderLinkHtml(item, pathname, search) {
  const href = adminMainNavHref(item);
  const active = isAdminMainNavItemActive(item, pathname, search);
  return `<a href="${escapeNavText(href)}" class="nav-link nav-link-sub${
    active ? " active" : ""
  }">${escapeNavText(formatNavLabel(item.label))}</a>`;
}

/** One # section under Admin (e.g. Testing, Season Break). */
export function renderAdminMainSectionHtml(sectionId, pathname, search = "") {
  const section = getAdminMainSection(sectionId);
  if (!section) return "";

  const megaOpen = adminMainSectionHasActive(sectionId, pathname, search);
  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel(section.label))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  html += renderAdminEntriesHtml(section.entries || [], pathname, search);

  // Nest monthly Season Checklist under Season Management in the Admin menu
  if (sectionId === "season_management") {
    const checklist = getAdminMainSection("season_checklist");
    const checklistEntries = (checklist?.entries || []).filter(
      (e) => e.type === "group" && (e.items || []).some((i) => i?.href)
    );
    if (checklistEntries.length) {
      const nestedOpen = checklistEntries.some((e) =>
        entryHasActive(e, pathname, search)
      );
      html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
      html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
        nestedOpen ? "true" : "false"
      }">${escapeNavText(formatNavLabel(checklist?.label || "Season Checklist"))}</button>`;
      html += `<div class="nav-subgroup-panel" role="group">`;
      html += renderAdminEntriesHtml(checklistEntries, pathname, search);
      html += `</div></div>`;
    }
  }

  html += `</div></div>`;
  return html;
}

function renderAdminEntriesHtml(entries, pathname, search = "") {
  let html = "";
  for (const entry of entries || []) {
    if (entry.type === "link") {
      html += renderLinkHtml(entry, pathname, search);
      continue;
    }
    if (entry.type === "group") {
      const nestedOpen = entryHasActive(entry, pathname, search);
      html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
      html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
        nestedOpen ? "true" : "false"
      }">${escapeNavText(formatNavLabel(entry.label))}</button>`;
      html += `<div class="nav-subgroup-panel" role="group">`;
      for (const item of entry.items || []) {
        html += renderLinkHtml(item, pathname, search);
      }
      html += `</div></div>`;
    }
  }
  return html;
}

/**
 * Page sidebars (admin_season / admin_season_break) — same sections as the
 * live Admin mega, so there is only one link tree to maintain.
 * @param {string[]} sectionIds
 */
export function renderAdminSidebarHtml(sectionIds, pathname, search = "") {
  return (sectionIds || [])
    .map((id) => renderAdminMainSectionHtml(id, pathname, search))
    .filter(Boolean)
    .join("");
}

/** Wire expand/collapse for sidebar mega subgroups. */
export function wireAdminSidebarNav(root) {
  if (!root) return;
  root.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
    const btn = subgroup.querySelector(":scope > .nav-subgroup-summary");
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !subgroup.classList.contains("open");
      subgroup.classList.toggle("open", willOpen);
      btn.setAttribute("aria-expanded", willOpen ? "true" : "false");
    });
  });
}
