/**
 * Pages GPSL members (no club) may view — full browse menus, view-only actions.
 */

/** Pages always allowed without a club (auth flows). */
export const AUTH_PAGES = new Set([
  "login",
  "reset_password",
  "index",
  "join_gpsl",
]);

/** Members on the waiting list (no club) — browse / view-only. */
export const MEMBER_ALLOWED_PAGES = new Set([
  "member_home",
  "waiting_list",
  "learning_gpsl",
  "inbox",
  "dashboard",
  // League
  "clubs",
  "club",
  "fixtures",
  "progress",
  "league_stats",
  "challenges",
  "cups",
  "world_cup",
  "international_matchday",
  "competition",
  "friendlies",
  // Transfers (market / databases — mutations blocked in view-only chrome)
  "gpdb",
  "player_career",
  "all_listings",
  "draftauction",
  "legacy_players",
  "expiring_contracts",
  "season_transfers",
  "mgdb",
  "manager_listings",
  "manager_draftauction",
  "season_manager_transfers",
  "manager_career",
  "club_database",
  "season_club_purchases",
  "special_auction",
  // Central bank (league)
  "central_bank",
  "central_bank_loans",
  "central_bank_counter",
  // Owners
  "owner_rankings",
  "owner_profile",
  "owner_last_login",
  "admin_owner_last_login",
  "season_calendar",
  "natter",
]);

/** Club auction onboarding — invited from waiting list only. */
export const AUCTION_ONBOARDING_PAGES = new Set([
  "awaiting_club",
  "club_auction",
  ...MEMBER_ALLOWED_PAGES,
]);

/** Club-specific — owners with a club only (caretakers TBD). */
export const CLUB_OWNER_PAGES = new Set([
  "club_details",
  "finances",
  "squad",
  "history",
  "stadium",
  "matchday",
  "club_fixtures",
  "transfer_center",
  "scouting",
  "national_team",
  "nation_select",
  "nation_player_pool",
]);

export function normalizePageId(page) {
  if (page) return String(page).toLowerCase();
  const file = (window.location.pathname || "")
    .split("/")
    .pop()
    .replace(/\.html$/i, "")
    .toLowerCase();
  return file.replace(/-/g, "_");
}

export function isAuthPage(page = normalizePageId()) {
  return AUTH_PAGES.has(page);
}

export function isClubOwnerPage(page = normalizePageId()) {
  return CLUB_OWNER_PAGES.has(page);
}

export function isMemberAllowedPage(page = normalizePageId()) {
  return MEMBER_ALLOWED_PAGES.has(page);
}

export function isAuctionOnboardingPage(page = normalizePageId()) {
  return AUCTION_ONBOARDING_PAGES.has(page);
}

/** Sticky home for waiting-list browse sessions. */
export function memberDefaultHome() {
  return "waiting_list.html";
}

export function memberHubHome() {
  return "member_home.html";
}

export function auctionOnboardingHome() {
  return "awaiting_club.html";
}

export function archivedHome() {
  return "member_home.html?archived=1";
}
