/**
 * GPSL Admin — sidebar navigation (admins only).
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

export function renderAdminSidebar(activePageId) {
  const active = normalizePageId(activePageId);
  const parts = [];

  parts.push(
    `<a href="admin.html" class="admin-nav-link${active === "hub" ? " active" : ""}"><b>GPSL Admin home</b></a>`
  );

  for (const group of ADMIN_NAV) {
    parts.push(`<div class="admin-nav-group">`);
    parts.push(`<div class="admin-nav-group-title">${group.label}</div>`);
    for (const item of group.items) {
      const id = normalizePageId(item.id);
      const cls =
        id === active ? "admin-nav-link sub active" : "admin-nav-link sub";
      parts.push(`<a href="${item.href}" class="${cls}">${item.label}</a>`);
    }
    parts.push(`</div>`);
  }

  return `<nav class="admin-sidebar" aria-label="GPSL Admin">${parts.join("")}</nav>`;
}

export function renderAdminFlyoutGrouped() {
  const parts = [
    `<a href="admin.html" class="gpsl-admin-flyout-link gpsl-admin-flyout-home"><b>Admin home</b></a>`,
  ];
  for (const group of ADMIN_NAV) {
    parts.push(
      `<div class="gpsl-admin-flyout-group"><div class="gpsl-admin-flyout-title">${group.label}</div>`
    );
    for (const item of group.items) {
      parts.push(
        `<a href="${item.href}" class="gpsl-admin-flyout-link">${item.label}</a>`
      );
    }
    parts.push(`</div>`);
  }
  return parts.join("");
}
