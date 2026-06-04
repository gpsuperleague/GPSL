/**
 * GPSL Admin — top-bar flyout menu (admins only).
 */

export const ADMIN_NAV = [
  {
    id: "season",
    label: "Season management",
    items: [
      { id: "season", href: "admin_season.html", label: "Season & calendar" },
    ],
  },
  {
    id: "fixtures",
    label: "Fixture management",
    items: [
      { id: "fixtures-league", href: "admin_fixtures-league.html", label: "League fixtures" },
      { id: "fixtures-cups", href: "admin_fixtures-cups.html", label: "Cup fixtures" },
      { id: "fixtures-playoffs", href: "admin_fixtures-playoffs.html", label: "Playoff fixtures" },
    ],
  },
  {
    id: "money",
    label: "Money management",
    items: [
      { id: "money", href: "admin_money.html", label: "Prizes, wages & gates" },
    ],
  },
  {
    id: "transfers",
    label: "Transfer management",
    items: [
      { id: "transfers", href: "admin_transfers.html", label: "Transfer window & engine" },
      { id: "draft", href: "admin_draft.html", label: "Draft auction" },
      { id: "special", href: "admin_special-auctions.html", label: "Special auction" },
    ],
  },
  {
    id: "owners",
    label: "Owner administration",
    items: [
      { id: "owners", href: "admin_owners.html", label: "Owners & accounts" },
    ],
  },
];

export function currentAdminPageId() {
  const path = (window.location.pathname || "").split("/").pop() || "";
  if (path === "admin.html") return "hub";
  const m = path.match(/^admin_([^.]+)\.html$/);
  if (!m) return "";
  return m[1].replace(/-/g, "-");
}

function normalizePageId(pageId) {
  return String(pageId || "").replace(/_/g, "-");
}

export function renderAdminFlyoutGrouped() {
  const path = (window.location.pathname || "").split("/").pop() || "";
  const activeHref = path || "admin.html";
  const homeActive = activeHref === "admin.html" ? " gpsl-admin-flyout-link-active" : "";
  const parts = [
    `<a href="admin.html" class="gpsl-admin-flyout-link gpsl-admin-flyout-home${homeActive}"><b>Admin home</b></a>`,
  ];
  for (const group of ADMIN_NAV) {
    parts.push(
      `<div class="gpsl-admin-flyout-group"><div class="gpsl-admin-flyout-title">${group.label}</div>`
    );
    for (const item of group.items) {
      const active = item.href === activeHref ? " gpsl-admin-flyout-link-active" : "";
      parts.push(
        `<a href="${item.href}" class="gpsl-admin-flyout-link${active}">${item.label}</a>`
      );
    }
    parts.push(`</div>`);
  }
  return parts.join("");
}
