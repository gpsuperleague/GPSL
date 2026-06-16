/**
 * Redirect owners without a club into the club-auction onboarding flow.
 * League admins (isGpslAdminUser) may browse all pages for testing.
 */
import { supabase, isGpslAdminUser } from "./global.js";
import { getAuthUser } from "./supabase_client.js";

const ALLOWED_WITHOUT_CLUB = new Set([
  "awaiting_club",
  "club_auction",
  "season_club_purchases",
  "learning_gpsl",
  "login",
  "reset_password",
  "index",
]);

function pageId() {
  if (window.CURRENT_PAGE) {
    return String(window.CURRENT_PAGE).toLowerCase();
  }
  const file = (window.location.pathname || "")
    .split("/")
    .pop()
    .replace(/\.html$/i, "")
    .toLowerCase();
  return file.replace(/-/g, "_");
}

function pathLooksLike(pageKey) {
  const path = (window.location.pathname || "").toLowerCase();
  const href = (window.location.href || "").toLowerCase();
  if (pageKey === "club_auction") {
    return /club_auction/.test(path) || /club_auction/.test(href);
  }
  if (pageKey === "awaiting_club") {
    return /awaiting_club/.test(path) || /awaiting_club/.test(href);
  }
  if (pageKey === "learning_gpsl") {
    return /learning_gpsl/.test(path) || /learning_gpsl/.test(href);
  }
  return false;
}

export function isAllowedNoClubPage(page = pageId()) {
  if (ALLOWED_WITHOUT_CLUB.has(page)) return true;
  if (pathLooksLike("club_auction")) return true;
  if (pathLooksLike("awaiting_club")) return true;
  if (pathLooksLike("learning_gpsl")) return true;
  return false;
}

function isAwaitingClubAuction(self) {
  if (!self || self.has_club) return false;
  if (self.status === "archived" || self.status === "on_break") return false;
  if (self.needs_club_auction === true) return true;
  if (self.status === "awaiting_club_auction") return true;
  // No registry row yet — still no club; treat as onboarding.
  if (self.status == null && self.has_club === false) return true;
  // active but no club — stale registry; keep them on auction onboarding until linked
  if (self.status === "active" && self.has_club === false) return true;
  return false;
}

function isAdminPath() {
  const p = (window.location.pathname || "").toLowerCase();
  return p.includes("admin") || /^admin[_-]/.test(p);
}

export async function enforceOwnerClubGate() {
  const page = pageId();
  if (isAllowedNoClubPage(page) || isAdminPath()) return;

  const user = await getAuthUser();
  if (!user) return;

  if (isGpslAdminUser(user)) return;

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  if (error) return;

  if (self?.has_club) return;

  if (isAwaitingClubAuction(self) && !isAllowedNoClubPage(page)) {
    window.location = "awaiting_club.html";
  }
}
