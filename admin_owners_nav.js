import { formatNavLabel } from "./nav_label.js";

/** Owner administration — shared by admin nav mega menu */

export const OWNER_ADMIN_NAV = [
  {
    id: "new_owners",
    label: "New owners",
    items: [
      {
        label: "Add owner",
        href: "admin_owners.html",
        hash: "ow-add-owner",
        page: "admin_owners",
      },
      {
        label: "Register for club auction",
        href: "admin_owners.html",
        hash: "ow-club-auction",
        page: "admin_owners",
      },
    ],
  },
  {
    id: "club_assignment",
    label: "Club assignment",
    items: [
      {
        label: "Link existing login to club",
        href: "admin_owners.html",
        hash: "ow-link-club",
        page: "admin_owners",
      },
      {
        label: "Change owner club",
        href: "admin_owners.html",
        hash: "ow-change-club",
        page: "admin_owners",
      },
    ],
  },
  {
    id: "break",
    label: "Short break",
    items: [
      {
        label: "Remove owner from club",
        href: "admin_owners.html",
        hash: "ow-break",
        page: "admin_owners",
      },
    ],
  },
  {
    id: "archive",
    label: "Archive",
    items: [
      {
        label: "Archive owner (left GPSL)",
        href: "admin_owners.html",
        hash: "ow-archive",
        page: "admin_owners",
      },
      {
        label: "Unarchive owner",
        href: "admin_owners.html",
        hash: "ow-unarchive",
        page: "admin_owners",
      },
    ],
  },
  {
    id: "account_access",
    label: "Login & email",
    items: [
      {
        label: "Update email",
        href: "admin_owners.html",
        hash: "ow-update-email",
        page: "admin_owners",
      },
      {
        label: "Send reset email",
        href: "admin_owners.html",
        hash: "ow-reset-password",
        page: "admin_owners",
      },
    ],
  },
];

export function ownerAdminNavHref(item) {
  if (!item?.href) return "#";
  if (item.hash) {
    return `${item.href}#${item.hash}`;
  }
  return item.href;
}

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function ownerAdminNavHasActive(pathname, search = "") {
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  if (file === "admin_owners.html") return true;
  for (const group of OWNER_ADMIN_NAV) {
    for (const item of group.items) {
      if (isOwnerAdminNavItemActive(item, pathname, search)) return true;
    }
  }
  return false;
}

/** Admin flyout: Owners & accounts → category → task link (3 levels). */
export function renderOwnerAdminNavHtml(pathname, search = "") {
  const linkActive = (item) => isOwnerAdminNavItemActive(item, pathname, search);
  const megaOpen = ownerAdminNavHasActive(pathname, search);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel("Owners & accounts"))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const group of OWNER_ADMIN_NAV) {
    html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
    html += `<button type="button" class="nav-subgroup-summary" aria-expanded="false">${escapeNavText(
      formatNavLabel(group.label)
    )}</button>`;
    html += `<div class="nav-subgroup-panel" role="group">`;
    for (const item of group.items) {
      const href = ownerAdminNavHref(item);
      const active = linkActive(item);
      html += `<a href="${escapeNavText(href)}" class="nav-link nav-link-sub${
        active ? " active" : ""
      }">${escapeNavText(formatNavLabel(item.label))}</a>`;
    }
    html += `</div></div>`;
  }

  html += `</div></div>`;
  return html;
}

export function isOwnerAdminNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;

  const hash = (window.location.hash || "").replace("#", "");
  if (item.hash) {
    return hash === item.hash;
  }

  return true;
}
