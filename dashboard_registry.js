/** Single source of dashboard shortcuts owners can pin and reorder. */

export const DASHBOARD_PANELS = [
  { id: "club_details", label: "Club Details", href: "club_details.html", page: "club_details.html", default: true },
  { id: "stadium", label: "Stadium", href: "stadium.html", page: "stadium.html", default: true },
  { id: "finances", label: "Club Finances", href: "finances.html", page: "finances.html", default: true },
  { id: "challenges", label: "Season Challenges", href: "challenges.html", page: "challenges.html", default: false },
  { id: "central_bank", label: "Central Bank", href: "central_bank.html", page: "central_bank.html", default: true },
  { id: "squad", label: "Squad", href: "squad.html", page: "squad.html", default: true },
  { id: "transfer_center", label: "Transfer Centre", href: "transfer_center.html", page: "transfer_center.html", default: true },
  { id: "matchday", label: "Match Day", href: "matchday.html", page: "matchday.html", default: true },
  { id: "fixtures", label: "Fixtures", href: "fixtures.html", page: "fixtures.html", default: true },
  { id: "history", label: "Club History", href: "history.html", page: "history.html", default: true },
  { id: "progress", label: "Competition Progress", href: "progress.html", page: "progress.html", default: true },
  { id: "league_stats", label: "League Stats", href: "league_stats.html", page: "league_stats.html", default: true },
  { id: "cups", label: "Cups", href: "cups.html", page: "cups.html", default: true },
  { id: "world_cup", label: "World Cup", href: "world_cup.html", page: "world_cup.html", default: true },
  { id: "owner_rankings", label: "Owner Rankings", href: "owner_rankings.html", page: "owner_rankings.html", default: false },
  {
    id: "special_auction",
    label: "Special Auction",
    href: "special_auction.html",
    page: "special_auction.html",
    default: false,
    when: "special_auction",
  },
  { id: "gpdb", label: "Player Database", href: "GPDB.html", page: "gpdb.html", default: false },
  { id: "transfer_market", label: "Transfer Market", href: "all_listings.html", page: "all_listings.html", default: false },
  {
    id: "draftauction",
    label: "Draft Auction",
    href: "draftauction.html",
    page: "draftauction.html",
    default: false,
    requiresDraft: true,
  },
  { id: "expiring_contracts", label: "Expiring Contracts", href: "expiring_contracts.html", page: "expiring_contracts.html", default: false },
  { id: "season_transfers", label: "Season Transfers", href: "season_transfers.html", page: "season_transfers.html", default: false },
  {
    id: "season_club_purchases",
    label: "Season Club Purchases",
    href: "season_club_purchases.html",
    page: "season_club_purchases.html",
    default: false,
  },
  { id: "clubs", label: "Clubs", href: "clubs.html", page: "clubs.html", default: false },
  { id: "inbox", label: "Inbox", href: "inbox.html", page: "inbox.html", default: false },
  {
    id: "admin",
    label: "GPSL Admin",
    href: "admin.html",
    page: "admin.html",
    default: false,
    adminOnly: true,
  },
  { id: "tc_scouting", label: "Scouting Targets", href: "transfer_center.html#scouting-targets", page: "transfer_center.html", section: true },
  { id: "tc_active_listings", label: "Active Listings", href: "transfer_center.html#active-listings", page: "transfer_center.html", section: true },
  { id: "tc_active_bids", label: "Active Bids", href: "transfer_center.html#active-bids", page: "transfer_center.html", section: true },
  { id: "tc_awaiting_seller", label: "Awaiting Seller", href: "transfer_center.html#awaiting-seller", page: "transfer_center.html", section: true },
  { id: "tc_seller_review", label: "Seller Review", href: "transfer_center.html#seller-review", page: "transfer_center.html", section: true },
  { id: "tc_closed_listings", label: "Closed Listings", href: "transfer_center.html#closed-listings", page: "transfer_center.html", section: true },
  { id: "tc_season_signings", label: "Season Signings", href: "transfer_center.html#season-signings", page: "transfer_center.html", section: true },
  { id: "tc_season_sales", label: "Season Sales", href: "transfer_center.html#season-sales", page: "transfer_center.html", section: true },
];

export const DEFAULT_DASHBOARD_PANEL_IDS = DASHBOARD_PANELS.filter((p) => p.default).map((p) => p.id);

const panelById = new Map(DASHBOARD_PANELS.map((p) => [p.id, p]));

export function getDashboardPanel(id) {
  return panelById.get(id) || null;
}

export function getDashboardPanelsForPage(pageFile) {
  const page = (pageFile || "").toLowerCase();
  return DASHBOARD_PANELS.filter((p) => (p.page || "").toLowerCase() === page);
}

/** Page-level pin (one per page file), not section-only entries. */
export function getPageDashboardPanel(pageFile) {
  const page = (pageFile || "").toLowerCase();
  return (
    DASHBOARD_PANELS.find(
      (p) => (p.page || "").toLowerCase() === page && !p.section
    ) || null
  );
}

export function normalizePageFile(pathname) {
  const p = (pathname || "").toLowerCase().replace(/\\/g, "/");
  return p.split("/").pop() || "";
}
