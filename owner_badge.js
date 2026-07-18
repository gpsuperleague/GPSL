/** Owner badge helpers — public profile symbol (no email). */
import { supabase } from "./global.js";

export function ownerProfileHref(ownerId) {
  if (!ownerId) return null;
  return `owner_profile.html?owner=${encodeURIComponent(ownerId)}`;
}

export function ownerBadgePublicUrl(badgePath) {
  if (!badgePath) return null;
  const { data } = supabase.storage.from("owner-badges").getPublicUrl(badgePath);
  return data?.publicUrl || null;
}

/** Compact badge + optional link for owner tag references. */
export function ownerTagHtml({
  ownerId,
  ownerTag,
  badgePath,
  size = 18,
  link = true,
} = {}) {
  const label = String(ownerTag || "Owner");
  const escaped = label
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  const url = ownerBadgePublicUrl(badgePath);
  const img = url
    ? `<img src="${url}" alt="" width="${size}" height="${size}" style="width:${size}px;height:${size}px;border-radius:4px;object-fit:cover;vertical-align:middle;margin-right:6px;border:1px solid #444">`
    : "";
  const inner = `${img}<span>${escaped}</span>`;
  const href = link ? ownerProfileHref(ownerId) : null;
  if (!href) return `<span class="owner-tag-chip">${inner}</span>`;
  return `<a class="gpsl-link owner-tag-chip" href="${href}">${inner}</a>`;
}
