/**
 * Admin preview bundle for owner screens that read "my club" on the server.
 * The signed-in club is unchanged for any save.
 */
import { supabase } from "./global.js";

let previewClub = null;
let bundle = null;
let bundleAt = 0;

export function ownerPreviewClub() {
  return previewClub;
}

export function setOwnerPreviewClub(short) {
  const next = String(short || "").trim().toUpperCase() || null;
  if (next !== previewClub) {
    bundle = null;
    bundleAt = 0;
  }
  previewClub = next;
}

export async function loadOwnerPreviewBundle() {
  if (!previewClub) return null;
  if (bundle && Date.now() - bundleAt < 15000) return bundle;
  const { data, error } = await supabase.rpc("admin_owner_screen_preview", {
    p_club: previewClub,
  });
  if (error) {
    console.warn("admin_owner_screen_preview:", error.message);
    return null;
  }
  bundle = data || null;
  bundleAt = Date.now();
  return bundle;
}

export function withPreviewClub(href) {
  if (!previewClub || !href) return href;
  const url = new URL(href, window.location.href);
  if (!/matchday\.html$|fixture_schedule\.html$/i.test(url.pathname)) return href;
  url.searchParams.set("club", previewClub);
  return `${url.pathname.split("/").pop()}${url.search}`;
}
