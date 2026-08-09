import { formatNavLabel } from "./nav_label.js";

/**
 * Canonical Admin → Testing mega-menu.
 * Wired from nav_config.js via `testingMega: true`.
 * Do not maintain a second Testing list in admin_main_nav.js.
 *
 * Structure: top-level link(s) + nested subgroups (Critical / Squad / Fixtures / Owners).
 */

function T(label, href, opts = {}) {
  const page =
    opts.page || href.replace(/\.html.*$/i, "").replace(/-/g, "_");
  const item = { type: "link", label, href, page };
  if (opts.navDanger) item.navDanger = true;
  return item;
}

function group(label, items = []) {
  return { type: "group", label, items };
}

export const TESTING_ADMIN_NAV = [
  T("Site map", "admin_site_map.html"),
  group("Critical", [
    T("Security hardening", "admin_security_hardening.html"),
    T("Reset League (vanilla)", "admin_test_reset.html", { navDanger: true }),
    T("Reset stadium capacity", "admin_test_stadium_reset.html", {
      navDanger: true,
    }),
    T("Inbox test (all clubs)", "admin_test_inbox.html"),
    T("End GPSL month early", "admin_test_end_month.html", { navDanger: true }),
  ]),
  group("Squad", [
    T("Populate squad (24)", "admin_test_populate_squad.html", {
      navDanger: true,
    }),
    T("Set default squad", "admin_test_set_default_squad.html", {
      navDanger: true,
    }),
    T("Draft Auction (Auto) Bids", "admin_test_draft_seed.html", {
      navDanger: true,
    }),
    T("Injuries & suspensions (test seed)", "admin_injuries.html", {
      navDanger: true,
    }),
  ]),
  group("Fixtures", [
    T("Match simulation settings", "admin_match_sim.html", { navDanger: true }),
    T("Deploy month results", "admin_test_deploy_month.html", {
      navDanger: true,
    }),
    T("Deploy single fixture", "admin_test_deploy_fixture.html", {
      navDanger: true,
    }),
  ]),
  group("Owners", [
    T("Club availability & timezone", "admin_test_club_availability.html"),
  ]),
];

/** Flat list of all Testing links (for consumers that expect href/label only). */
export function flattenTestingAdminNav(entries = TESTING_ADMIN_NAV) {
  const out = [];
  for (const entry of entries) {
    if (entry?.type === "link" || (entry?.href && !entry.type)) {
      out.push(entry);
      continue;
    }
    if (entry?.type === "group") {
      for (const item of entry.items || []) out.push(item);
    }
  }
  return out;
}

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

function testingEntryHasActive(entry, pathname) {
  if (entry?.type === "group") {
    return (entry.items || []).some((item) =>
      isTestingAdminNavItemActive(item, pathname)
    );
  }
  return isTestingAdminNavItemActive(entry, pathname);
}

export function testingAdminNavHasActive(pathname) {
  return TESTING_ADMIN_NAV.some((entry) => testingEntryHasActive(entry, pathname));
}

function renderTestingLinkHtml(item, pathname) {
  const active = isTestingAdminNavItemActive(item, pathname);
  const danger = item.navDanger ? " nav-link-danger" : "";
  return `<a href="${escapeNavText(item.href)}" class="nav-link nav-link-sub${danger}${
    active ? " active" : ""
  }">${escapeNavText(formatNavLabel(item.label))}</a>`;
}

/** Admin dropdown: Testing → nested subgroups (same mega style as Season management). */
export function renderTestingAdminNavHtml(pathname) {
  const megaOpen = testingAdminNavHasActive(pathname);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel("Testing"))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const entry of TESTING_ADMIN_NAV) {
    if (entry.type === "group") {
      const nestedOpen = testingEntryHasActive(entry, pathname);
      html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
      html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
        nestedOpen ? "true" : "false"
      }">${escapeNavText(formatNavLabel(entry.label))}</button>`;
      html += `<div class="nav-subgroup-panel" role="group">`;
      for (const item of entry.items || []) {
        html += renderTestingLinkHtml(item, pathname);
      }
      html += `</div></div>`;
      continue;
    }
    html += renderTestingLinkHtml(entry, pathname);
  }

  html += `</div></div>`;
  return html;
}
