import { formatNavLabel } from "./nav_label.js";

/**
 * Canonical Admin → Testing mega-menu links.
 * Wired from nav_config.js via `testingMega: true`.
 * Do not maintain a second Testing list in admin_main_nav.js.
 */
export const TESTING_ADMIN_NAV = [
  {
    label: "Site map",
    href: "admin_site_map.html",
    page: "admin_site_map",
  },
  {
    label: "Reset League (vanilla)",
    href: "admin_test_reset.html",
    page: "admin_test_reset",
    navDanger: true,
  },
  {
    label: "Assign manager to club",
    href: "admin_test_manager_assign.html",
    page: "admin_test_manager_assign",
    navDanger: true,
  },
  {
    label: "Draft Auction (Auto) Bids",
    href: "admin_test_draft_seed.html",
    page: "admin_test_draft_seed",
    navDanger: true,
  },
  {
    label: "Deploy month results",
    href: "admin_test_deploy_month.html",
    page: "admin_test_deploy_month",
    navDanger: true,
  },
  {
    label: "End Month Early",
    href: "admin_test_end_month.html",
    page: "admin_test_end_month",
    navDanger: true,
  },
  {
    label: "Inbox test (all clubs)",
    href: "admin_test_inbox.html",
    page: "admin_test_inbox",
  },
  {
    label: "Club availability & timezone",
    href: "admin_test_club_availability.html",
    page: "admin_test_club_availability",
  },
  {
    label: "Injuries & suspensions (test seed)",
    href: "admin_injuries.html",
    page: "admin_injuries",
    navDanger: true,
  },
];

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function isTestingAdminNavItemActive(item, pathname) {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  return file === itemFile;
}

export function testingAdminNavHasActive(pathname) {
  for (const item of TESTING_ADMIN_NAV) {
    if (isTestingAdminNavItemActive(item, pathname)) return true;
  }
  return false;
}

/** Admin dropdown: Testing → task links (same mega style as Season management). */
export function renderTestingAdminNavHtml(pathname) {
  const megaOpen = testingAdminNavHasActive(pathname);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel("Testing"))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const item of TESTING_ADMIN_NAV) {
    const active = isTestingAdminNavItemActive(item, pathname);
    const danger = item.navDanger ? " nav-link-danger" : "";
    html += `<a href="${escapeNavText(item.href)}" class="nav-link nav-link-sub${danger}${
      active ? " active" : ""
    }">${escapeNavText(formatNavLabel(item.label))}</a>`;
  }

  html += `</div></div>`;
  return html;
}
