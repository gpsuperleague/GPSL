import { formatNavLabel } from "./nav_label.js";

/**
 * Owners sidebar / legacy mega helper.
 *
 * LIVE Admin mega menu for Owners comes from admin_main_nav.js (adminMainMega).
 * Keep this list aligned with that Owners section when editing.
 * nav_config.js only uses this file if `ownersMega: true` is wired (currently unused
 * for the primary Admin menu).
 */

export const OWNER_ADMIN_NAV = [
  {
    id: "waiting_list",
    label: "Waiting list",
    items: [
      {
        label: "Manage waiting list",
        href: "admin_owners_waiting_list.html",
        page: "admin_owners_waiting_list",
      },
      {
        label: "Discord join order",
        href: "admin_owners_discord.html",
        page: "admin_owners_discord",
      },
    ],
  },
  {
    id: "discord_feeds",
    label: "Discord feeds",
    items: [
      {
        label: "Discord News Feed",
        href: "admin_discord_news.html",
        page: "admin_discord_news",
      },
      {
        label: "Discord Friendlies",
        href: "admin_discord_friendlies.html",
        page: "admin_discord_friendlies",
      },
      {
        label: "Transfer Gossip",
        href: "admin_discord_transfer_gossip.html",
        page: "admin_discord_transfer_gossip",
      },
    ],
  },
  {
    id: "new_owners",
    label: "New owners",
    items: [
      {
        label: "Create New Owner & Add to Waiting List",
        href: "admin_owners_add_member.html",
        page: "admin_owners_add_member",
      },
      {
        label: "Create New Owner & Add Directly to Club",
        href: "admin_owners_add_direct.html",
        page: "admin_owners_add_direct",
      },
    ],
  },
  {
    id: "club_assignment",
    label: "Club assignment",
    items: [
      {
        label: "Link existing login to club",
        href: "admin_owners_link.html",
        page: "admin_owners_link",
      },
      {
        label: "Change Owner Club",
        href: "admin_owners_change_club.html",
        page: "admin_owners_change_club",
      },
      {
        label: "Remove Owner From Club",
        href: "admin_owners_remove.html",
        page: "admin_owners_remove",
      },
      {
        label: "Assign Manager to club",
        href: "admin_test_manager_assign.html",
        page: "admin_test_manager_assign",
      },
    ],
  },
  {
    id: "archive",
    label: "Archive",
    items: [
      {
        label: "Archive Owner (left GPSL)",
        href: "admin_owners_archive.html",
        page: "admin_owners_archive",
      },
      {
        label: "Unarchive Owner (return to GPSL)",
        href: "admin_owners_unarchive.html",
        page: "admin_owners_unarchive",
      },
    ],
  },
  {
    id: "account_access",
    label: "Login & email",
    items: [
      {
        label: "Set Owner Tag",
        href: "admin_owners_tag.html",
        page: "admin_owners_tag",
      },
      {
        label: "Update Email",
        href: "admin_owners_email.html",
        page: "admin_owners_email",
      },
      {
        label: "Set Password",
        href: "admin_owners_password.html",
        page: "admin_owners_password",
      },
      {
        label: "Send Reset Email",
        href: "admin_owners_reset.html",
        page: "admin_owners_reset",
      },
    ],
  },
  {
    id: "natter",
    label: "Natter",
    items: [
      {
        label: "Remove Natter posts",
        href: "admin_natter.html",
        page: "admin_natter",
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

function isOwnerAdminPage(file) {
  return (
    file === "admin_owners.html" ||
    /^admin_owners_[a-z0-9_]+\.html$/.test(file) ||
    file === "admin_natter.html" ||
    file === "admin_discord_news.html" ||
    file === "admin_discord_friendlies.html" ||
    file === "admin_discord_transfer_gossip.html" ||
    file === "admin_test_manager_assign.html"
  );
}

export function ownerAdminNavHasActive(pathname, search = "") {
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  if (isOwnerAdminPage(file)) return true;
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
