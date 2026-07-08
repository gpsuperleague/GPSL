/**
 * Pages GPSL members (no club) may view — league & transfers, not My Club.
 */

/** Pages always allowed without a club (auth flows). */
export const AUTH_PAGES = new Set([
  "login",
  "reset_password",
  "index",
]);

/** Members on the waiting list (no club). */
export const MEMBER_ALLOWED_PAGES = new Set([
  "member_home",
  "waiting_list",
  "learning_gpsl",
  "inbox",
  "dashboard",
  // League
  "clubs",
  "fixtures",
  "progress",
  "league_stats",
  "challenges",
  "cups",
  "world_cup",
  "competition",
  // Transfers (market / databases — not club-specific actions)
  "gpdb",
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
  "club",
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

export function memberDefaultHome() {
  return "member_home.html";
}

export function auctionOnboardingHome() {
  return "awaiting_club.html";
}

export function archivedHome() {
  return "member_home.html?archived=1";
}
