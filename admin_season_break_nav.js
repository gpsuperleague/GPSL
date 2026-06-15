import { formatNavLabel } from "./nav_label.js";

/** Season Break workflow — shared by admin nav + admin_season_break.html sidebar */

export const SEASON_BREAK_NAV = [
  {
    id: "transfers_open",
    label: "Transfers",
    items: [
      {
        label: "Set transfer window open",
        href: "admin_transfers.html",
        hash: "sb-transfer-window",
        page: "admin_transfers",
      },
    ],
  },
  {
    id: "prizes",
    label: "Prize Money adjustments",
    items: [
      {
        label: "Cup Prize Money",
        href: "admin_cup_prizes.html",
        page: "admin_cup_prizes",
      },
      {
        label: "Set league prize money",
        href: "admin_money.html",
        hash: "sb-league-prizes",
        page: "admin_money",
      },
    ],
  },
  {
    id: "club_attendance",
    label: "Club attendance & prestige",
    items: [
      {
        label: "Club attendance & prestige",
        href: "admin_club_attendance.html",
        page: "admin_club_attendance",
      },
    ],
  },
  {
    id: "challenges",
    label: "Challenges",
    items: [
      {
        label: "Set initial season challenges",
        href: "admin_challenges.html",
        page: "admin_challenges",
      },
    ],
  },
  {
    id: "bills",
    label: "Bills & Income",
    items: [
      {
        label: "Set TV revenue",
        href: "admin_money.html",
        hash: "sb-tv-revenue",
        page: "admin_money",
      },
      {
        label: "Set government subsidies",
        href: "admin_money.html",
        hash: "sb-gov-subsidies",
        page: "admin_money",
      },
      {
        label: "Set 34+",
        href: "admin_money.html",
        hash: "sb-tax-34",
        page: "admin_money",
      },
      {
        label: "Set star %",
        href: "admin_money.html",
        hash: "sb-star-tax",
        page: "admin_money",
      },
      {
        label: "Set Wage %",
        href: "admin_money.html",
        hash: "sb-wage-pct",
        page: "admin_money",
      },
      {
        label: "Set Tax %",
        href: "admin_money.html",
        hash: "sb-tax-pct",
        page: "admin_money",
      },
      {
        label: "Set fines",
        href: "admin_fines.html",
        page: "admin_fines",
      },
      {
        label: "Set stadium costs",
        href: "admin_money.html",
        hash: "sb-stadium-costs",
        page: "admin_money",
      },
    ],
  },
  {
    id: "auctions",
    label: "Auctions",
    items: [
      {
        label: "Switch on draft",
        href: "admin_transfers.html",
        hash: "sb-transfer-window",
        page: "admin_transfers",
      },
      {
        label: "Switch off draft",
        href: "admin_transfers.html",
        hash: "sb-transfer-window",
        page: "admin_transfers",
      },
      {
        label: "Reset draft",
        href: "admin_transfers.html",
        page: "admin_transfers",
      },
      {
        label: "Setup special auctions",
        href: "admin_special-auctions.html",
        page: "admin_special-auctions",
      },
    ],
  },
  {
    id: "transfers_closed",
    label: "Transfers",
    items: [
      {
        label: "Set transfer window closed",
        href: "admin_transfers.html",
        hash: "sb-transfer-window",
        page: "admin_transfers",
      },
    ],
  },
  {
    id: "internationals",
    label: "Internationals",
    items: [
      {
        label: "Nation setup",
        href: "admin_international.html",
        hash: "sb-nation-setup",
        page: "admin_international",
      },
      {
        label: "Open Nation Selection",
        href: "admin_international.html",
        hash: "sb-nation-selection",
        page: "admin_international",
      },
      {
        label: "Manual National Team Assignment",
        href: "admin_international.html",
        hash: "sb-nation-assign",
        page: "admin_international",
      },
      {
        label: "Close Nation Selection",
        href: "admin_international.html",
        hash: "sb-nation-selection",
        page: "admin_international",
      },
      {
        label: "Clear Nation Selection",
        href: "admin_international.html",
        hash: "sb-nation-selection",
        page: "admin_international",
      },
      {
        label: "Set Owner Rankings",
        href: "admin_international.html",
        hash: "sb-owner-rankings",
        page: "admin_international",
      },
      {
        label: "Nation player pool",
        href: "nation_player_pool.html",
        page: "nation_player_pool",
      },
    ],
  },
  {
    id: "data_tools",
    label: "Data tools",
    items: [
      {
        label: "GPDB PESDB sync",
        href: "admin_gpdb_sync.html",
        page: "admin_gpdb_sync",
      },
      {
        label: "GPDB player deduplication",
        href: "admin_gpdb_dedup.html",
        page: "admin_gpdb_dedup",
      },
    ],
  },
];

export function seasonBreakNavHref(item) {
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

export function seasonBreakNavHasActive(pathname, search = "") {
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  if (file === "admin_season_break.html") return true;
  for (const group of SEASON_BREAK_NAV) {
    for (const item of group.items) {
      if (isSeasonBreakNavItemActive(item, pathname, search)) return true;
    }
  }
  return false;
}

/** Admin flyout: Season Break → category → task link (3 levels). */
export function renderSeasonBreakNavHtml(pathname, search = "") {
  const linkActive = (item) => isSeasonBreakNavItemActive(item, pathname, search);
  const megaOpen = seasonBreakNavHasActive(pathname, search);

  let html = `<div class="nav-subgroup nav-subgroup-mega${megaOpen ? " open" : ""}" data-nav-subgroup>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }">${escapeNavText(formatNavLabel("Season Break"))}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;

  for (const group of SEASON_BREAK_NAV) {
    html += `<div class="nav-subgroup nav-subgroup-nested" data-nav-subgroup>`;
    html += `<button type="button" class="nav-subgroup-summary" aria-expanded="false">${escapeNavText(
      formatNavLabel(group.label)
    )}</button>`;
    html += `<div class="nav-subgroup-panel" role="group">`;
    for (const item of group.items) {
      const href = seasonBreakNavHref(item);
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

export function isSeasonBreakNavItemActive(item, pathname, search = "") {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;

  const hash = (window.location.hash || "").replace("#", "");
  if (item.hash) {
    return hash === item.hash;
  }

  if (file === "admin_season_break.html") {
    return false;
  }

  return true;
}
