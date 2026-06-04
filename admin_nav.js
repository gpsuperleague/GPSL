/**
 * GPSL Admin — one nav group (Admin), same header style as Transfers / League.
 * Dropdown keeps category labels (Season management, Fixture management, …).
 */

export const ADMIN_NAV_SECTION = {
  id: "admin",
  label: "Admin",
  items: [
    { heading: true, label: "Season management" },
    { href: "admin_season.html", label: "Season & calendar" },

    { heading: true, label: "Fixture management" },
    { href: "admin_fixtures-league.html", label: "League fixtures" },
    { href: "admin_fixtures-cups.html", label: "Cup fixtures" },
    { href: "admin_fixtures-playoffs.html", label: "Playoff fixtures" },

    { heading: true, label: "Money management" },
    { href: "admin_money.html", label: "Prizes, wages & gates" },

    { heading: true, label: "Transfer management" },
    { href: "admin_transfers.html", label: "Transfer window & engine" },
    { href: "admin_draft.html", label: "Draft auction" },
    { href: "admin_special-auctions.html", label: "Special auction" },

    { heading: true, label: "Owner administration" },
    { href: "admin_owners.html", label: "Owners & accounts" },
  ],
};
