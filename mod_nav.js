/**
 * Top-nav Mod menu — curated tools for gpsl_site_mods (not full Admin).
 * Keep in sync with agreed Mod scope; bump APP_VERSION after edits.
 *
 * Admin also shows this list ghosted under Admin → Mod menu (preview)
 * so you can see/tweak Mod scope without logging in as a mod.
 */

import { formatNavLabel } from "./nav_label.js";

function L(label, href, hash = null) {
  const item = {
    label,
    href,
    page: href.replace(/\.html.*$/i, "").replace(/-/g, "_"),
  };
  if (hash) item.hash = hash;
  return item;
}

export const MOD_NAV_SECTION = {
  id: "mod",
  label: "Mod",
  items: [
    L("Staff alerts", "admin_staff_alerts.html"),
    L("Waiting list", "admin_owners_waiting_list.html"),
    L("Discord join order", "admin_owners_discord.html"),
    L("Set Owner Tag", "admin_owners_tag.html"),
    L("Owner Last Login", "owner_last_login.html"),
    L("Remove Natter", "admin_natter.html"),
    L("Owner holidays", "admin_owner_holidays.html"),
    L("Discord News Feed", "admin_discord_news.html"),
    L("Discord Friendlies", "admin_discord_friendlies.html"),
    L("Transfer Gossip", "admin_discord_transfer_gossip.html"),
    L("Republish GPSL Sport", "admin_gpsl_sport.html"),
    L("Club Season Checklist", "admin_club_checklist.html"),
    L("Apply fines", "admin_fines.html"),
    L("Red card appeal review", "admin_prize_appeals.html"),
    L("Injuries", "admin_injuries.html"),
    L("Cancel open listings & bids", "admin_transfers.html", "sb-cancel-open"),
    L("Open Nation Selection", "admin_international_selection_open.html"),
    L("Close Nation Selection", "admin_international_selection_close.html"),
    L("Manual National Team Selection", "admin_international.html", "sb-nation-assign"),
    L("Verify owner rankings", "admin_international.html", "sb-owner-rankings"),
  ],
};

function escapeNavText(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function modItemHref(item) {
  if (!item?.href) return "#";
  if (item.hash) return `${item.href}#${item.hash}`;
  return item.href;
}

function isModPreviewItemActive(item, pathname) {
  if (!item?.href) return false;
  const file = (pathname || "").toLowerCase().replace(/\\/g, "/").split("/").pop() || "";
  const itemFile = item.href.split("?")[0].split("#")[0].toLowerCase();
  if (file !== itemFile) return false;
  if (!item.hash) return true;
  const hash =
    typeof window !== "undefined" ? (window.location.hash || "").replace("#", "") : "";
  return hash === item.hash;
}

export function modMenuPreviewHasActive(pathname) {
  return (MOD_NAV_SECTION.items || []).some((item) =>
    isModPreviewItemActive(item, pathname)
  );
}

/**
 * Ghosted Mod menu inside Admin dropdown — links still work for admin tweaking.
 */
export function renderModMenuPreviewHtml(pathname) {
  const items = MOD_NAV_SECTION.items || [];
  if (!items.length) return "";

  const megaOpen = modMenuPreviewHasActive(pathname);
  let html = `<div class="nav-subgroup nav-subgroup-mega nav-subgroup-ghost${
    megaOpen ? " open" : ""
  }" data-nav-subgroup data-mod-preview>`;
  html += `<button type="button" class="nav-subgroup-summary" aria-expanded="${
    megaOpen ? "true" : "false"
  }" title="What Mods see in their Mod menu — open any link to edit that tool">${escapeNavText(
    formatNavLabel("Mod menu (preview)")
  )}</button>`;
  html += `<div class="nav-subgroup-panel nav-subgroup-panel-mega" role="group">`;
  html += `<div class="nav-mod-preview-note">Ghosted view of the Mod top-nav. Links still open for admins.</div>`;

  for (const item of items) {
    const active = isModPreviewItemActive(item, pathname);
    html += `<a href="${escapeNavText(modItemHref(item))}" class="nav-link nav-link-sub nav-link-ghost${
      active ? " active" : ""
    }">${escapeNavText(formatNavLabel(item.label))}</a>`;
  }

  html += `</div></div>`;
  return html;
}

/** Pages mods may open (admin always can). */
export const MOD_ALLOWED_PAGES = new Set(
  MOD_NAV_SECTION.items.map((i) =>
    String(i.href || "")
      .split("?")[0]
      .split("#")[0]
      .toLowerCase()
  )
);

export function isModAllowedPage(pathNorm) {
  const p = String(pathNorm || "")
    .toLowerCase()
    .split("/")
    .pop();
  return MOD_ALLOWED_PAGES.has(p);
}
