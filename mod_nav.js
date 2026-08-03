/**
 * Top-nav Mod menu — curated tools for gpsl_site_mods (not full Admin).
 * Keep in sync with agreed Mod scope; bump APP_VERSION after edits.
 */

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
