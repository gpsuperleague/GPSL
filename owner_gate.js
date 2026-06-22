/**
 * Access control: owners with a club, waiting-list members, auction invitees, archived.
 */
import { supabase, isGpslAdminUser } from "./global.js";
import { getAuthUser } from "./supabase_client.js";
import {
  isAuthPage,
  isMemberAllowedPage,
  isAuctionOnboardingPage,
  isClubOwnerPage,
  memberDefaultHome,
  auctionOnboardingHome,
  archivedHome,
  normalizePageId,
} from "./member_access.js";

function isAdminPath() {
  const p = (window.location.pathname || "").toLowerCase();
  return p.includes("admin") || /^admin[_-]/.test(p);
}

function redirectTo(url) {
  const target = url.split("?")[0];
  const current = (window.location.pathname || "").split("/").pop() || "";
  if (current.toLowerCase() === target.toLowerCase()) return;
  window.location.assign(url);
}

export async function enforceOwnerClubGate() {
  const page = normalizePageId(
    window.CURRENT_PAGE ? String(window.CURRENT_PAGE) : undefined
  );

  if (isAuthPage(page) || isAdminPath()) return;

  const user = await getAuthUser();
  if (!user) return;

  if (isGpslAdminUser(user)) return;

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  if (error) {
    console.warn("owner_registry_get_self:", error);
    return;
  }

  if (self?.has_club) return;

  if (self?.is_archived) {
    if (page === "member_home") return;
    redirectTo(archivedHome());
    return;
  }

  if (self?.needs_club_auction || self?.status === "awaiting_club_auction") {
    if (isAuctionOnboardingPage(page)) return;
    redirectTo(auctionOnboardingHome());
    return;
  }

  if (self?.is_member) {
    if (isMemberAllowedPage(page)) return;
    if (isClubOwnerPage(page)) {
      redirectTo(memberDefaultHome());
      return;
    }
    redirectTo(memberDefaultHome());
    return;
  }

  // Unknown no-club state — treat as member waiting list
  if (!isMemberAllowedPage(page)) {
    redirectTo(memberDefaultHome());
  }
}

export { isMemberAllowedPage, isClubOwnerPage, normalizePageId } from "./member_access.js";
