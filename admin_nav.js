/**
 * GPSL Admin — top nav section (admins only, same style as Transfers / League).
 * No separate “Admin home” — first item is Season & calendar.
 */

export const ADMIN_NAV_SECTION = {
  id: "admin",
  label: "Admin",
  items: [
    { href: "admin_season.html", label: "Season & calendar" },
    { href: "admin_fixtures-league.html", label: "League fixtures", indent: true },
    { href: "admin_fixtures-cups.html", label: "Cup fixtures", indent: true },
    { href: "admin_fixtures-playoffs.html", label: "Playoff fixtures", indent: true },
    { href: "admin_money.html", label: "Prizes, wages & gates" },
    { href: "admin_transfers.html", label: "Transfer window & engine", indent: true },
    { href: "admin_draft.html", label: "Draft auction", indent: true },
    { href: "admin_special-auctions.html", label: "Special auction", indent: true },
    { href: "admin_owners.html", label: "Owners & accounts" },
  ],
};
