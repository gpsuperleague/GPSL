import { formatNavLabel } from "./nav_label.js";
import { TESTING_ADMIN_NAV } from "./admin_testing_nav.js";

/**
 * Primary Admin workflow menu (new).
 * # sections → top-level Admin mega subgroups
 * ~ groups → nested headers
 * links → pages (hash when needed)
 *
 * This file is the source of truth for the live Admin mega-menus, Admin
 * checklist, and season / season-break page sidebars.
 *
 * Testing links: maintain only in admin_testing_nav.js (TESTING_ADMIN_NAV).
 *
 * After editing this file (or admin_testing_nav.js), bump APP_VERSION in
 * app_version.js — otherwise browsers keep the old menu via module cache.
 */

function L(label, href, hash = null, page = null, note = null) {
  const item = { label, href };
  if (hash) item.hash = hash;
  if (page) item.page = page;
  else if (href) {
    item.page = href.replace(/\.html.*$/i, "").replace(/-/g, "_");
  }
  if (note) item.note = note;
  return item;
}

function link(label, href, hash = null, note = null) {
  return { type: "link", ...L(label, href, hash, null, note) };
}

function group(label, items = []) {
  return { type: "group", label, items };
}

export const ADMIN_MAIN_NAV = [
  {
    id: "testing",
    label: "Testing",
    // Kept for checklist exclusion / section id only — live menu uses testingMega.
    entries: TESTING_ADMIN_NAV.map((item) => link(item.label, item.href)),
  },
  {
    id: "owners",
    label: "Owners",
    entries: [
      group("Waiting list", [
        L("Manage waiting list", "admin_owners_waiting_list.html"),
        L("Discord join order", "admin_owners_discord.html"),
      ]),
      group("Discord feeds", [
        L("Discord News Feed", "admin_discord_news.html"),
        L("Discord Friendlies", "admin_discord_friendlies.html"),
        L("Transfer Gossip", "admin_discord_transfer_gossip.html"),
      ]),
      group("New owners", [
        L("Create New Owner & Add to Waiting List", "admin_owners_add_member.html"),
        L("Create New Owner & Add Directly to Club", "admin_owners_add_direct.html"),
      ]),
      group("Club assignment", [
        L("Link existing login to club", "admin_owners_link.html"),
        L("Change Owner Club", "admin_owners_change_club.html"),
        L("Remove Owner From Club", "admin_owners_remove.html"),
        L("Assign Manager to club", "admin_test_manager_assign.html"),
      ]),
      group("Archive", [
        L("Archive Owner (left GPSL)", "admin_owners_archive.html"),
        L("Unarchive Owner (return to GPSL)", "admin_owners_unarchive.html"),
      ]),
      group("Login & email", [
        L("Owner Last Login", "owner_last_login.html"),
        L("Set Owner Tag", "admin_owners_tag.html"),
        L("Update Email", "admin_owners_email.html"),
        L("Set Password", "admin_owners_password.html"),
        L("Send Reset Email", "admin_owners_reset.html"),
      ]),
      group("Natter", [L("Remove Natter posts", "admin_natter.html")]),
    ],
  },
  {
    id: "season_break",
    label: "Season Break",
    entries: [
      group("GPDB Update", [
        L("GPDB Player Sync", "admin_gpdb_sync.html"),
        L("GPDB Player Deduplication", "admin_gpdb_dedup.html"),
        L("GPDB Player Exclusions", "admin_gpdb_exclusions.html"),
      ]),
      group("OooO", [L("Homegrown Star Draw", "admin_one_of_our_own.html")]),
      group("Club Kits", [L("Download Latest Kits", "admin_club_kits.html")]),
      group("Prize Money", [
        L("Cup Prize Money", "admin_cup_prizes.html"),
        L("League Prize Money", "admin_league_prizes.html"),
      ]),
      group("Club, Stadium & Manager", [
        L("Club Attendance & Prestige", "admin_club_attendance.html"),
        L("Stadium Settings", "admin_stadium_settings.html"),
        L("Weather & Pitch conditions", "admin_weather.html"),
        L("Manager Contract Targets", "admin_manager_targets.html"),
      ]),
      group("Internationals", [
        L("Nation Setup", "admin_international.html", "sb-nation-setup"),
        L("World Cup Cycle", "admin_international.html", "sb-wc-cycle"),
        L("Open Nation Selection", "admin_international_selection_open.html"),
        L("Manual National Team Selection", "admin_international.html", "sb-nation-assign"),
        L("Close Nation Selection", "admin_international_selection_close.html"),
        L("Clear Nation Assignments", "admin_international_selection_clear.html"),
        L("Verify owner rankings", "admin_international.html", "sb-owner-rankings"),
      ]),
    ],
  },
  {
    id: "create_season",
    label: "Create Season",
    entries: [
      link("Create Pre-Season", "admin_season.html", "wf-kickoff"),
      group("Assign divisions", [
        L("Setup Superleague Teams", "admin_season.html", "wf-divisions"),
        L("Setup Championship Teams", "admin_season.html", "wf-divisions"),
        L("Draw Championship Divisions", "admin_season.html", "wf-divisions"),
      ]),
      link("Create Season Calendar", "admin_season.html", "wf-calendar"),
      link("Create League Fixtures", "admin_fixtures-league.html"),
      link("Setup Cups", "admin_fixtures-cups.html"),
    ],
  },
  {
    id: "pre_season",
    label: "Pre-Season (June & July)",
    entries: [
      group("Challenges", [
        L("Set Initial Season Challenges", "admin_challenges.html"),
      ]),
      group("Bills & Income", [
        L("Set TV Revenue", "admin_tv_revenue.html"),
        L("Set Government Subsidies", "admin_gov_subsidies.html"),
        L("Set 34+ Fee", "admin_tax_34.html"),
        L("Set Star Fee", "admin_star_tax.html"),
        L("Set Wage %", "admin_wage_pct.html"),
        L("Set Tax %", "admin_tax_pct.html"),
        L("Set stadium costs", "admin_stadium_costs.html"),
      ]),
      group("Auctions", [
        L("Set Draft Auction On/Off", "admin_transfers.html"),
        L("Auction Exclusions", "admin_auction_exclusions.html"),
        L("Special Auction", "admin_special-auctions.html"),
      ]),
      group("Transfers", [L("Set on/off", "admin_transfer_window.html")]),
    ],
  },
  {
    id: "season_management",
    label: "Season Management",
    entries: [
      link("Club Season Checklist", "admin_club_checklist.html"),
      link("Owner holidays", "admin_owner_holidays.html"),
      link("Apply fines", "admin_fines.html"),
      link(
        "Inject cash",
        "admin_cash_injection.html",
        null,
        "Credit a fixed ₿ amount to all season clubs or selected clubs (admin_one_off_injection + inbox)."
      ),
      link(
        "Charge Emergency Tax",
        "admin_emergency_tax.html",
        null,
        "Debit a fixed ₿ amount from all or selected clubs (gov_emergency_tax + inbox). Also hosts season-end threshold % formula."
      ),
      link("Red card appeal review", "admin_prize_appeals.html"),
      link("Republish GPSL Sport", "admin_gpsl_sport.html"),
    ],
  },
  {
    id: "season_checklist",
    label: "Season Checklist",
    entries: [
      group("August", [
        L("Special Auction", "admin_special-auctions.html"),
      ]),
      group("September", [
        L("Close Transfer Window", "admin_transfer_window.html", "closed"),
      ]),
      group("October", []),
      group("November", []),
      group("December", [
        L("Start of Season challenge Payouts", "admin_challenges.html"),
      ]),
      group("January", [
        L("Set Mid-Season Challenges", "admin_challenges.html"),
        L("Special Auction", "admin_special-auctions.html"),
        L("Open Transfer Window", "admin_transfer_window.html", "open"),
        L("Close Transfer Window", "admin_transfer_window.html", "closed"),
      ]),
      group("February", []),
      group("March", []),
      group("April", []),
      group("May", [
        L("Lock May (end GPSL month early)", "admin_test_end_month.html"),
        L("Retry May month-lock jobs if timed out", "admin_test_end_month.html"),
        L("Republish GPSL Sport (May)", "admin_gpsl_sport.html"),
        L("Generate playoffs", "admin_fixtures-playoffs.html"),
      ]),
      group("Playoffs", [
        L("Setup Playoffs", "admin_fixtures-playoffs.html"),
        L(
          "Complete playoff fixtures (deploy results)",
          "admin_test_deploy_month.html"
        ),
        L("Apply playoff movements", "admin_fixtures-playoffs.html"),
        L("Push Discord queue (results / news)", "admin_discord_news.html"),
        L(
          "Lock Playoffs month (end GPSL month early)",
          "admin_test_end_month.html",
          null,
          null,
          "Playoffs is the last GPSL month — uncheck “Also unlock next month now”. Confirmation phrase: END GPSL MONTH (not END MONTH OPEN NEXT). Preview → End current month now."
        ),
      ]),
    ],
  },
  {
    id: "close_season",
    label: "Close Season",
    entries: [
      link("Apply playoff movements", "admin_fixtures-playoffs.html"),
      link("Mid-Season Challenge payouts", "admin_challenges.html"),
      link("Pay government subsidies", "admin_gov_subsidies.html"),
      link(
        "Pay league prize money",
        "admin_league_prizes.html",
        null,
        "Confirm amounts per division, then Pay league prizes (only pays divisions with 38/38 played; safe to re-run)."
      ),
      link(
        "Archive season stats & awards",
        "admin_season.html",
        "wf-close-season",
        "Locks tables/awards (and an early finance snapshot). OK to run before Close Finances — Close Finances refreshes the finance archive afterward."
      ),
      link("Process manager contracts (season end)", "admin_season.html", "wf-close-season"),
      link("Charge Emergency Tax", "admin_emergency_tax.html"),
      link(
        "Close Finances",
        "admin_wage_bills.html",
        null,
        "LAST money step: wages + manager salary + 34+ + star tax → stadium maintenance → debt interest → FFP (₿50M + MV releases + next-window buy embargo) → balance interest, then refreshes season finance archive. Safe to re-run (skips posted lines)."
      ),
    ],
  },
  {
    id: "end_of_season",
    label: "End Of Season",
    entries: [
      link("End current season {summer break}", "admin_season.html", "wf-close-season"),
      link("Start Season Break workflow", "admin_season_break.html"),
    ],
  },
];

export function adminMainNavHref(item) {
  if (!item?.href) return "#";
  if (item.hash) return `${item.href}#${item.hash}`;
  return item.href;
}

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function getAdminMainSection(sectionId) {
  return ADMIN_MAIN_NAV.find((s) => s.id === sectionId) || null;
}

export function isAdminMainNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;

  const hash = (typeof window !== "undefined" ? window.location.hash || "" : "").replace("#", "");
  if (item.hash) return hash === item.hash;
  return true;
}

function entryHasActive(entry, pathname, search) {
  if (entry.type === "link") {
    return isAdminMainNavItemActive(entry, pathname, search);
  }
  if (entry.type === "group") {
    return (entry.items || []).some((item) => isAdminMainNavItemActive(item, pathname, search));
  }
  return false;
}

export function adminMainSectionHasActive(sectionId, pathname, search = "") {
  const section = getAdminMainSection(sectionId);
  if (!section) return false;
  return (section.entries || []).some((e) => entryHasActive(e, pathname, search));
}

export function adminMainNavHasActive(pathname, search = "") {
  return ADMIN_MAIN_NAV.some((s) => adminMainSectionHasActive(s.id, pathname, search));
}

/** Sections omitted from the manual Admin workflow checklist. */
export const ADMIN_CHECKLIST_EXCLUDE_SECTION_IDS = new Set(["testing", "owners"]);

/**
 * Stable key for checklist persistence (season-scoped in DB / localStorage).
 * @param {string} sectionId
 * @param {string|null} groupLabel
 * @param {{ label: string, href?: string, hash?: string }} item
 */
export function adminChecklistTaskKey(sectionId, groupLabel, item) {
  return [sectionId, groupLabel || "", item.label || "", item.href || "", item.hash || ""].join("|");
}

/**
 * Flatten Admin menu into checklist sections (excludes Testing & Owners).
 * Empty groups (e.g. months with no tasks) are omitted.
 */
export function getAdminWorkflowChecklist() {
  const sections = [];

  for (const section of ADMIN_MAIN_NAV) {
    if (ADMIN_CHECKLIST_EXCLUDE_SECTION_IDS.has(section.id)) continue;

    /** @type {{ groupLabel: string|null, items: Array<Record<string, unknown>> }[]} */
    const blocks = [];

    for (const entry of section.entries || []) {
      if (entry.type === "link") {
        blocks.push({
          groupLabel: null,
          items: [
            {
              ...entry,
              taskKey: adminChecklistTaskKey(section.id, null, entry),
            },
          ],
        });
        continue;
      }
      if (entry.type === "group") {
        const items = (entry.items || [])
          .filter((item) => item?.href)
          .map((item) => ({
            ...item,
            taskKey: adminChecklistTaskKey(section.id, entry.label, item),
          }));
        if (!items.length) continue;
        blocks.push({ groupLabel: entry.label, items });
      }
    }

    if (!blocks.length) continue;
    sections.push({
      id: section.id,
      label: section.label,
      blocks,
    });
  }

  return sections;
}

function renderLinkHtml(item, pathname, search) {
  const href = adminMainNavHref(item);
  const active = isAdminMainNavItemActive(item, pathname, search);
  return `<a href="${escapeNavText(href)}" class="nav-link nav-link-sub${
    active ? " active" : ""
  }">${escapeNavText(formatNavLabel(item.label))}</a>`;
}

/** One # section under Admin (e.g. Testing, Season Break). */
export function renderAdminMainSectionHtml(sectionId, pathname, search = "") {
  const section = getAdminMainSection(sectionId);
  if (!section) return "";

  const megaOpen = adminMainSectionHasActive(sectionId, pathname, search);
  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel(section.label))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const entry of section.entries || []) {
    if (entry.type === "link") {
      html += renderLinkHtml(entry, pathname, search);
      continue;
    }
    if (entry.type === "group") {
      const nestedOpen = entryHasActive(entry, pathname, search);
      html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
      html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
        nestedOpen ? "true" : "false"
      }">${escapeNavText(formatNavLabel(entry.label))}</button>`;
      html += `<div class="nav-subgroup-panel" role="group">`;
      for (const item of entry.items || []) {
        html += renderLinkHtml(item, pathname, search);
      }
      html += `</div></div>`;
    }
  }

  html += `</div></div>`;
  return html;
}

/**
 * Page sidebars (admin_season / admin_season_break) — same sections as the
 * live Admin mega, so there is only one link tree to maintain.
 * @param {string[]} sectionIds
 */
export function renderAdminSidebarHtml(sectionIds, pathname, search = "") {
  return (sectionIds || [])
    .map((id) => renderAdminMainSectionHtml(id, pathname, search))
    .filter(Boolean)
    .join("");
}

/** Wire expand/collapse for sidebar mega subgroups. */
export function wireAdminSidebarNav(root) {
  if (!root) return;
  root.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
    const btn = subgroup.querySelector(":scope > .nav-subgroup-summary");
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !subgroup.classList.contains("open");
      subgroup.classList.toggle("open", willOpen);
      btn.setAttribute("aria-expanded", willOpen ? "true" : "false");
    });
  });
}
