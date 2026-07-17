/** Single source of dashboard shortcuts owners can pin and reorder. */

const PANEL_BG = "images/panel_bg";

/** Original GPSL watermark artwork (do not replace with generated placeholders). */
const TILE_IMAGE_BY_ID = {
  club_details: `${PANEL_BG}/Club_Details.png`,
  stadium: `${PANEL_BG}/stadium.png`,
  medical_room: `${PANEL_BG}/MatchDay.png`,
  finances: `${PANEL_BG}/Finances.png`,
  squad: `${PANEL_BG}/Squad.png`,
  transfer_center: `${PANEL_BG}/Transfer.png`,
  matchday: `${PANEL_BG}/MatchDay.png`,
  fixtures: `${PANEL_BG}/Fixtures.png`,
  history: `${PANEL_BG}/History.png`,
  progress: `${PANEL_BG}/Progress.png`,
  league_stats: `${PANEL_BG}/Progress.png`,
  central_bank: `${PANEL_BG}/Central_Bank.png`,
  central_bank_loans: `${PANEL_BG}/Central_Bank.png`,
  central_bank_counter: `${PANEL_BG}/Central_Bank.png`,
  cups: `${PANEL_BG}/Fixtures.png`,
  world_cup: `${PANEL_BG}/Fixtures.png`,
  challenges: `${PANEL_BG}/Progress.png`,
  club_prizes: `${PANEL_BG}/Finances.png`,
  gpdb: `${PANEL_BG}/Squad.png`,
  transfer_market: `${PANEL_BG}/Transfer.png`,
  draftauction: `${PANEL_BG}/Transfer.png`,
  legacy_players: `${PANEL_BG}/Squad.png`,
  expiring_contracts: `${PANEL_BG}/Squad.png`,
  season_transfers: `${PANEL_BG}/Transfer.png`,
  mgdb: `${PANEL_BG}/Squad.png`,
  manager_listings: `${PANEL_BG}/Transfer.png`,
  manager_draftauction: `${PANEL_BG}/Transfer.png`,
  season_manager_transfers: `${PANEL_BG}/Transfer.png`,
  club_database: `${PANEL_BG}/Club_Details.png`,
  club_auction: `${PANEL_BG}/Club_Details.png`,
  season_club_purchases: `${PANEL_BG}/Club_Details.png`,
  clubs: `${PANEL_BG}/Club_Details.png`,
  scouting: `${PANEL_BG}/Transfer.png`,
  special_auction: `${PANEL_BG}/Transfer.png`,
  finances_incoming: `${PANEL_BG}/Finances.png`,
  finances_outgoing: `${PANEL_BG}/Finances.png`,
  finances_ledger: `${PANEL_BG}/Finances.png`,
  finances_accounts: `${PANEL_BG}/Finances.png`,
  inbox: `${PANEL_BG}/History.png`,
  owner_rankings: `${PANEL_BG}/Progress.png`,
  learning_gpsl: `${PANEL_BG}/History.png`,
  waiting_list: `${PANEL_BG}/History.png`,
  member_home: `${PANEL_BG}/Club_Details.png`,
  awaiting_club: `${PANEL_BG}/Club_Details.png`,
  national_team: `${PANEL_BG}/Fixtures.png`,
  nation_select: `${PANEL_BG}/Fixtures.png`,
  nation_player_pool: `${PANEL_BG}/Squad.png`,
  player_career: `${PANEL_BG}/Squad.png`,
  cup_draw: `${PANEL_BG}/Fixtures.png`,
  fixture_schedule: `${PANEL_BG}/Fixtures.png`,
  dashboard: `${PANEL_BG}/Club_Details.png`,
  tc_scouting: `${PANEL_BG}/Transfer.png`,
  tc_active_listings: `${PANEL_BG}/Transfer.png`,
  tc_active_bids: `${PANEL_BG}/Transfer.png`,
  tc_awaiting_seller: `${PANEL_BG}/Transfer.png`,
  tc_seller_review: `${PANEL_BG}/Transfer.png`,
  tc_closed_listings: `${PANEL_BG}/Transfer.png`,
  tc_season_signings: `${PANEL_BG}/Transfer.png`,
  tc_season_sales: `${PANEL_BG}/Transfer.png`,
  admin: `${PANEL_BG}/Central_Bank.png`,
  admin_owners: `${PANEL_BG}/Club_Details.png`,
  admin_transfers: `${PANEL_BG}/Transfer.png`,
  admin_season: `${PANEL_BG}/Progress.png`,
  admin_draft: `${PANEL_BG}/Transfer.png`,
  admin_fixtures_league: `${PANEL_BG}/Fixtures.png`,
  admin_fixtures_cups: `${PANEL_BG}/Fixtures.png`,
  admin_fixtures_playoffs: `${PANEL_BG}/Fixtures.png`,
  admin_challenges: `${PANEL_BG}/Progress.png`,
  admin_prize_appeals: `${PANEL_BG}/Finances.png`,
  admin_club_checklist: `${PANEL_BG}/Club_Details.png`,
  admin_workflow_checklist: `${PANEL_BG}/Progress.png`,
  admin_special_auctions: `${PANEL_BG}/Transfer.png`,
  admin_international: `${PANEL_BG}/Fixtures.png`,
  admin_club_kits: `${PANEL_BG}/Club_Details.png`,
  admin_wage_bills: `${PANEL_BG}/Finances.png`,
  admin_fines: `${PANEL_BG}/Finances.png`,
  admin_cup_prizes: `${PANEL_BG}/Fixtures.png`,
  admin_weather: `${PANEL_BG}/Fixtures.png`,
  admin_gpdb_sync: `${PANEL_BG}/Squad.png`,
  admin_gpdb_dedup: `${PANEL_BG}/Squad.png`,
  admin_season_break: `${PANEL_BG}/Progress.png`,
  admin_one_of_our_own: `${PANEL_BG}/Squad.png`,
  admin_manager_targets: `${PANEL_BG}/Squad.png`,
  admin_club_attendance: `${PANEL_BG}/stadium.png`,
  admin_natter: `${PANEL_BG}/History.png`,
};

const TILE_FALLBACK = `${PANEL_BG}/Progress.png`;

function resolveTileImage(id) {
  return TILE_IMAGE_BY_ID[id] || TILE_FALLBACK;
}

function p(
  id,
  label,
  href,
  {
    page = null,
    defaultOn = false,
    section = false,
    adminOnly = false,
    requiresDraft = false,
    when = null,
    noPagePin = false,
  } = {}
) {
  const pageFile = (page || href.split("?")[0].split("#")[0]).toLowerCase();
  return {
    id,
    label,
    href,
    page: pageFile,
    default: defaultOn,
    section: !!section,
    adminOnly: !!adminOnly,
    requiresDraft: !!requiresDraft,
    when: when || null,
    noPagePin: !!noPagePin,
    tile: resolveTileImage(id),
  };
}

export const DASHBOARD_PANELS = [
  p("club_details", "Club Details", "club_details.html", { defaultOn: true }),
  p("stadium", "Stadium", "stadium.html", { defaultOn: true }),
  p("medical_room", "Medical Room", "medical_room.html", { defaultOn: true }),
  p("finances", "Club Finances", "finances.html", { defaultOn: true }),
  p("squad", "Squad", "squad.html", { defaultOn: true }),
  p("transfer_center", "Transfer Centre", "transfer_center.html", { defaultOn: true }),
  p("matchday", "Match Day", "matchday.html", { defaultOn: true }),
  p("club_fixtures", "My Club Fixtures", "club_fixtures.html", { defaultOn: true }),
  p("fixtures", "Fixtures", "fixtures.html", { defaultOn: true }),
  p("history", "Club History", "history.html", { defaultOn: true }),
  p("progress", "Competition Progress", "progress.html", { defaultOn: true }),
  p("league_stats", "League Stats", "league_stats.html", { defaultOn: true }),
  p("cups", "Cups", "cups.html", { defaultOn: true }),
  p("world_cup", "World Cup", "world_cup.html", { defaultOn: true }),
  p("challenges", "Season Challenges", "challenges.html"),
  p("club_prizes", "Rewards Centre", "club_prizes.html"),
  p("central_bank", "Central Bank", "central_bank.html", { defaultOn: true }),
  p("central_bank_loans", "League Loans", "central_bank_loans.html"),
  p("central_bank_counter", "Service Counter", "central_bank_counter.html"),
  p("gpdb", "Player Database", "GPDB.html", { page: "gpdb.html" }),
  p("transfer_market", "Transfer Market", "all_listings.html", { page: "all_listings.html" }),
  p("draftauction", "Player Draft Auction", "draftauction.html", { requiresDraft: true }),
  p("legacy_players", "Legacy Players", "legacy_players.html"),
  p("expiring_contracts", "Expiring Contracts", "expiring_contracts.html"),
  p("season_transfers", "Season Transfers", "season_transfers.html"),
  p("mgdb", "Manager Database", "MGDB.html", { page: "mgdb.html" }),
  p("manager_listings", "Manager Market", "manager_listings.html"),
  p("manager_draftauction", "Manager Draft Auction", "manager_draftauction.html", {
    requiresDraft: true,
  }),
  p("season_manager_transfers", "Season Manager Transfers", "season_manager_transfers.html"),
  p("club_database", "Club Database", "club_database.html"),
  p("club_auction", "Club Auction", "club_auction.html"),
  p("season_club_purchases", "Season Club Purchases", "season_club_purchases.html"),
  p("clubs", "Clubs", "clubs.html"),
  p("inbox", "Inbox", "inbox.html"),
  p("owner_rankings", "Owner Rankings", "owner_rankings.html"),
  p("learning_gpsl", "Learning GPSL", "learning_gpsl.html"),
  p("waiting_list", "Waiting List", "waiting_list.html"),
  p("member_home", "Member Home", "member_home.html"),
  p("awaiting_club", "Club Auction Setup", "awaiting_club.html"),
  p("scouting", "Scouting Board", "scouting.html"),
  p("national_team", "National Team", "national_team.html"),
  p("international_matchday", "Intl Matchday", "international_matchday.html"),
  p("nation_select", "Nation Selection", "nation_select.html"),
  p("nation_player_pool", "Nation Player Pool", "nation_player_pool.html"),
  p("special_auction", "Special Auction", "special_auction.html", { when: "special_auction" }),
  p("player_career", "Player Career", "player_career.html"),
  p("cup_draw", "Cup Draw", "cup_draw.html"),
  p("fixture_schedule", "Fixture Schedule", "fixture_schedule.html"),
  p("finances_incoming", "Finances Incoming", "finances_incoming.html"),
  p("finances_outgoing", "Finances Outgoing", "finances_outgoing.html"),
  p("finances_ledger", "Finances Ledger", "finances_ledger.html"),
  p("finances_accounts", "Season Accounts", "finances_accounts.html"),
  p("dashboard", "Dashboard", "dashboard.html", { noPagePin: true }),
  p("admin", "GPSL Admin", "admin.html", { adminOnly: true }),
  p("admin_site_map", "Site map", "admin_site_map.html", { adminOnly: true }),
  p("admin_owners", "Owner Admin", "admin_owners.html", { adminOnly: true }),
  p("admin_workflow_checklist", "Admin Checklist", "admin_workflow_checklist.html", {
    adminOnly: true,
  }),
  p("admin_transfers", "Transfer Admin", "admin_transfers.html", { adminOnly: true }),
  p("admin_transfer_window", "Transfer window", "admin_transfer_window.html", { adminOnly: true }),
  p("admin_season", "Season Admin", "admin_season.html", { adminOnly: true }),
  p("admin_draft", "Draft Admin", "admin_draft.html", { adminOnly: true }),
  p("admin_fixtures_league", "League Fixtures", "admin_fixtures-league.html", {
    page: "admin_fixtures-league.html",
    adminOnly: true,
  }),
  p("admin_fixtures_cups", "Cup Fixtures", "admin_fixtures-cups.html", {
    page: "admin_fixtures-cups.html",
    adminOnly: true,
  }),
  p("admin_fixtures_playoffs", "Playoff Fixtures", "admin_fixtures-playoffs.html", {
    page: "admin_fixtures-playoffs.html",
    adminOnly: true,
  }),
  p("admin_challenges", "Challenge Admin", "admin_challenges.html", { adminOnly: true }),
  p("admin_prize_appeals", "Red Card Appeals", "admin_prize_appeals.html", { adminOnly: true }),
  p("admin_club_checklist", "Club Checklist", "admin_club_checklist.html", { adminOnly: true }),
  p("admin_special_auctions", "Special Auctions Admin", "admin_special-auctions.html", {
    page: "admin_special-auctions.html",
    adminOnly: true,
  }),
  p("admin_international", "International Admin", "admin_international.html", { adminOnly: true }),
  p("admin_club_kits", "Club Kits Admin", "admin_club_kits.html", { adminOnly: true }),
  p("admin_wage_bills", "Season wage bills", "admin_wage_bills.html", { adminOnly: true }),
  p("admin_tv_revenue", "TV revenue", "admin_tv_revenue.html", { adminOnly: true }),
  p("admin_gov_subsidies", "Government subsidies", "admin_gov_subsidies.html", { adminOnly: true }),
  p("admin_tax_34", "34+ fee", "admin_tax_34.html", { adminOnly: true }),
  p("admin_star_tax", "Star tax", "admin_star_tax.html", { adminOnly: true }),
  p("admin_wage_pct", "Wage %", "admin_wage_pct.html", { adminOnly: true }),
  p("admin_tax_pct", "Tax %", "admin_tax_pct.html", { adminOnly: true }),
  p("admin_emergency_tax", "Emergency tax", "admin_emergency_tax.html", { adminOnly: true }),
  p("admin_league_prizes", "League prizes", "admin_league_prizes.html", { adminOnly: true }),
  p("admin_stadium_settings", "Stadium settings", "admin_stadium_settings.html", { adminOnly: true }),
  p("admin_stadium_costs", "Stadium costs", "admin_stadium_costs.html", { adminOnly: true }),
  p("admin_fines", "Fines Admin", "admin_fines.html", { adminOnly: true }),
  p("admin_cup_prizes", "Cup Prizes Admin", "admin_cup_prizes.html", { adminOnly: true }),
  p("admin_weather", "Weather Admin", "admin_weather.html", { adminOnly: true }),
  p("admin_gpdb_sync", "GPDB Sync", "admin_gpdb_sync.html", { adminOnly: true }),
  p("admin_gpdb_dedup", "GPDB Dedup", "admin_gpdb_dedup.html", { adminOnly: true }),
  p("admin_season_break", "Season Break Admin", "admin_season_break.html", { adminOnly: true }),
  p("admin_one_of_our_own", "One Of Our Own", "admin_one_of_our_own.html", { adminOnly: true }),
  p("admin_manager_targets", "Manager Targets", "admin_manager_targets.html", { adminOnly: true }),
  p("admin_club_attendance", "Club Attendance", "admin_club_attendance.html", { adminOnly: true }),
  p("admin_natter", "Natter Admin", "admin_natter.html", { adminOnly: true }),
  p("tc_scouting", "Scouting Targets", "transfer_center.html#scouting-targets", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_active_listings", "Active Listings", "transfer_center.html#active-listings", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_active_bids", "Active Bids", "transfer_center.html#active-bids", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_awaiting_seller", "Awaiting Seller", "transfer_center.html#awaiting-seller", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_seller_review", "Seller Review", "transfer_center.html#seller-review", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_closed_listings", "Closed Listings", "transfer_center.html#closed-listings", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_season_signings", "Season Signings", "transfer_center.html#season-signings", {
    page: "transfer_center.html",
    section: true,
  }),
  p("tc_season_sales", "Season Sales", "transfer_center.html#season-sales", {
    page: "transfer_center.html",
    section: true,
  }),
];

export const DEFAULT_DASHBOARD_PANEL_IDS = DASHBOARD_PANELS.filter((x) => x.default).map((x) => x.id);

const panelById = new Map(DASHBOARD_PANELS.map((x) => [x.id, x]));

export function getDashboardPanel(id) {
  return panelById.get(id) || null;
}

export function getDashboardTileUrl(panelOrId) {
  const panel = typeof panelOrId === "string" ? getDashboardPanel(panelOrId) : panelOrId;
  return panel?.tile || null;
}

export function getDashboardPanelsForPage(pageFile) {
  const page = (pageFile || "").toLowerCase();
  return DASHBOARD_PANELS.filter((x) => (x.page || "").toLowerCase() === page);
}

/** Page-level pin (one per page file), not section-only entries. */
export function getPageDashboardPanel(pageFile) {
  const page = (pageFile || "").toLowerCase();
  return (
    DASHBOARD_PANELS.find((x) => (x.page || "").toLowerCase() === page && !x.section) || null
  );
}

export function normalizePageFile(pathname) {
  const p = (pathname || "").toLowerCase().replace(/\\/g, "/");
  return p.split("/").pop() || "";
}
