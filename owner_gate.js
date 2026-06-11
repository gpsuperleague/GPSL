/**
 * Redirect owners without a club into the club-auction onboarding flow.
 */
import { supabase } from "./global.js";

const ALLOWED_WITHOUT_CLUB = new Set([
  "awaiting_club",
  "login",
  "reset_password",
  "index",
]);

function pageId() {
  return (window.CURRENT_PAGE || "").toLowerCase();
}

function isAdminPath() {
  const p = (window.location.pathname || "").toLowerCase();
  return p.includes("admin") || /^admin[_-]/.test(p);
}

export async function enforceOwnerClubGate() {
  const page = pageId();
  if (ALLOWED_WITHOUT_CLUB.has(page) || isAdminPath()) return;

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (club?.ShortName) return;

  const { data: self, error } = await supabase.rpc("owner_registry_get_self");
  if (error) return;

  if (self?.needs_club_auction || self?.status === "awaiting_club_auction") {
    if (page !== "awaiting_club") {
      window.location = "awaiting_club.html";
    }
  }
}
