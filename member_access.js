/**
 * Pages owners without a club may use until assigned a club.
 * Waiting-list members and club-auction invitees share this surface.
 */

/** Pages always allowed without a club (auth flows). */
export const AUTH_PAGES = new Set([
  "login",
  "reset_password",
  "index",
  "join_gpsl",
]);

/**
 * Pre-club owners (waiting list + club auction invitees):
 * waiting list, owner setup, databases, club draft auction, Learning GPSL.
 */
export const MEMBER_ALLOWED_PAGES = new Set([
  "waiting_list",
  "awaiting_club",
  "club_auction",
  "club_database",
  "gpdb",
  "mgdb",
  "scouting",
  "learning_gpsl",
  "video_tutorials",
]);

/** Discord visitors (read-only spectators, no GPSL owner account). */
export const VISITOR_ALLOWED_PAGES = new Set([
  "progress",
  "cups",
  "draftauction",
  "draftauction_player",
  "club_auction",
  "manager_draftauction",
  "manager_draftauction_manager",
  "all_listings",
  "owner_rankings",
  "learning_gpsl",
  "video_tutorials",
]);

export const VISITOR_NAV_ITEMS = [
  { href: "progress.html", label: "Tables", page: "progress" },
  { href: "cups.html", label: "Cups", page: "cups" },
  { href: "draftauction.html", label: "Player draft auction", page: "draftauction" },
  { href: "manager_draftauction.html", label: "Manager auction", page: "manager_draftauction" },
  { href: "club_auction.html", label: "Club draft auction", page: "club_auction" },
  { href: "all_listings.html", label: "Transfer market", page: "all_listings" },
  { href: "owner_rankings.html", label: "Owner rankings", page: "owner_rankings" },
  { href: "learning_gpsl.html", label: "Handbook", page: "learning_gpsl" },
  { href: "video_tutorials.html", label: "Video tutorials", page: "video_tutorials" },
];

export function visitorHome() {
  return "progress.html";
}

export function isVisitorAllowedPage(page = normalizePageId()) {
  return VISITOR_ALLOWED_PAGES.has(page);
}

/** Visitor sessions carry app_metadata.gpsl_visitor (set server-side, not user-editable). */
export function isVisitorUser(user) {
  return user?.app_metadata?.gpsl_visitor === true;
}

/** Same surface for auction invitees (kept for callers / clarity). */
export const AUCTION_ONBOARDING_PAGES = new Set([...MEMBER_ALLOWED_PAGES]);

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

/** Sticky home for waiting-list / pre-club sessions. */
export function memberDefaultHome() {
  return "waiting_list.html";
}

export function memberHubHome() {
  return "waiting_list.html";
}

export function auctionOnboardingHome() {
  return "awaiting_club.html";
}

export function archivedHome() {
  return "member_home.html?archived=1";
}

/** Flat nav for owners without a club. */
export const PRE_CLUB_NAV_ITEMS = [
  { href: "waiting_list.html", label: "Waiting list", page: "waiting_list" },
  {
    href: "awaiting_club.html",
    label: "Owner details",
    page: "awaiting_club",
  },
  {
    href: "club_database.html",
    label: "Club Database",
    page: "club_database",
  },
  { href: "GPDB.html", label: "Player Database", page: "gpdb" },
  { href: "MGDB.html", label: "Manager Database", page: "mgdb" },
  { href: "scouting.html", label: "Scouting", page: "scouting" },
  {
    href: "club_auction.html",
    label: "Club draft auction",
    page: "club_auction",
  },
  {
    href: "learning_gpsl.html",
    label: "Learning GPSL",
    page: "learning_gpsl",
  },
  {
    href: "video_tutorials.html",
    label: "Video tutorials",
    page: "video_tutorials",
  },
  {
    href: "video_tutorials.html#transfers",
    label: "Transfers",
    page: "video_tutorials",
    hash: "transfers",
    indent: true,
  },
];
