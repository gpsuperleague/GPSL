/** GPSL top navigation — single source of links (pages unchanged). */

export const NAV_SECTIONS = [
  {
    id: "transfers",
    label: "Transfers",
    items: [
      { href: "GPDB.html", label: "Player Database", page: "gpdb" },
      { href: "all_listings.html", label: "Transfer Market", page: "all_listings" },
      {
        href: "draftauction.html",
        label: "Draft Auction",
        page: "draftauction",
        requiresDraft: true,
      },
      { href: "expiring_contracts.html", label: "Expiring Contracts", page: "expiring_contracts" },
      { href: "season_transfers.html", label: "Season Transfers", page: "season_transfers" },
    ],
  },
  {
    id: "finances",
    label: "Finances",
    items: [
      { href: "finances.html", label: "Club Finances", page: "finances" },
      { href: "central_bank.html", label: "The Central Bank", page: "central_bank" },
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
    ],
  },
  {
    id: "cups",
    label: "Cups",
    items: [
      { href: "cups.html?cup=league_cup", label: "League Cup", page: "cups", cup: "league_cup" },
      { href: "cups.html?cup=super8", label: "Prestige Cups", page: "cups", cup: "super8" },
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
      { href: "history.html", label: "Club History", page: "history" },
      { href: "stadium.html", label: "Stadium", page: "stadium" },
      { href: "fixtures.html", label: "Fixtures", page: "fixtures" },
      { href: "matchday.html", label: "Match Day", page: "matchday", indent: true },
      { href: "progress.html", label: "Tables", page: "progress" },
      { href: "league_stats.html", label: "Stats", page: "league_stats", indent: true },
      { href: "cups.html", label: "Cups", page: "cups" },
      { href: "transfer_center.html", label: "Transfer Centre", page: "transfer_center" },
      {
        href: "transfer_center.html#scouting-targets",
        label: "Scouting Targets",
        page: "transfer_center",
        hash: "scouting-targets",
        indent: true,
      },
      { href: "squad.html", label: "Squad", page: "squad" },
    ],
  },
];

export function normalizeNavPath(pathname) {
  const p = (pathname || "").toLowerCase().replace(/\\/g, "/");
  const file = p.split("/").pop() || "";
  return file;
}

export function isNavItemActive(item, pathname, search = "") {
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
  return section.items.some((item) => isNavItemActive(item, pathname, search));
}
