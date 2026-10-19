/** Owner badge helpers — public profile symbol (no email). */
import { supabase } from "./global.js";

/** @type {Map<string, { is_supporter: boolean, badge_path: string|null }>} */
const supporterByOwnerId = new Map();
/** @type {Map<string, boolean>} lowercased owner_tag → supporter */
const supporterByOwnerTag = new Map();
let supporterMapLoaded = false;

/** @type {Map<string, { code: 'UH'|'OH', status: string, starts_at?: string, ends_at?: string }>} club → holiday */
const holidayByClub = new Map();
/** @type {Map<string, { code: 'UH'|'OH', status: string }>} owner uuid → holiday */
const holidayByOwnerId = new Map();
let holidayMapLoaded = false;

function pathOrEmpty(path) {
  const s = String(path || "").trim();
  return s || null;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function ownerProfileHref(ownerId) {
  if (!ownerId) return null;
  return `owner_profile.html?owner=${encodeURIComponent(ownerId)}`;
}

export function ownerBadgePublicUrl(badgePath) {
  const path = pathOrEmpty(badgePath);
  if (!path) return null;
  const { data } = supabase.storage.from("owner-badges").getPublicUrl(path);
  return data?.publicUrl || null;
}

/** Gold “Supporter” mark for owner tags. */
export function supporterMarkHtml(isSupporter, { compact = true } = {}) {
  if (!isSupporter) return "";
  const cls = compact
    ? "owner-supporter-pill owner-supporter-pill--inline"
    : "owner-supporter-pill";
  return `<span class="${cls}" title="Ko-fi Supporter">Supporter</span>`;
}

/** UH / OH circle next to owner tags. Ended / back from holiday → no mark. */
export function holidayStatusMarkHtml(code, { title } = {}) {
  const c = String(code || "").toUpperCase();
  if (c !== "UH" && c !== "OH") return "";
  const tip =
    title ||
    (c === "OH" ? "On Holiday" : "Upcoming Holiday");
  return `<span class="owner-holiday-pill owner-holiday-pill--${c.toLowerCase()}" title="${escapeHtml(
    tip
  )}">${c}</span>`;
}

/**
 * Load UH/OH holiday status by club (and owner_id when available).
 * Safe to call repeatedly; uses an in-memory cache.
 */
export async function loadOwnerHolidayStatusMap({ force = false } = {}) {
  if (holidayMapLoaded && !force) return holidayByClub;
  holidayByClub.clear();
  holidayByOwnerId.clear();
  try {
    const { data, error } = await supabase.rpc("owner_holiday_status_map");
    if (error) {
      console.warn("loadOwnerHolidayStatusMap:", error.message || error);
      holidayMapLoaded = true;
      return holidayByClub;
    }
    const map = data && typeof data === "object" ? data : {};
    for (const [club, row] of Object.entries(map)) {
      const code = String(row?.code || "").toUpperCase();
      if (code !== "UH" && code !== "OH") continue;
      const entry = {
        code,
        status: String(row?.status || ""),
        starts_at: row?.starts_at || null,
        ends_at: row?.ends_at || null,
      };
      holidayByClub.set(String(club).toUpperCase(), entry);
    }
  } catch (err) {
    console.warn("loadOwnerHolidayStatusMap:", err);
  }
  holidayMapLoaded = true;
  return holidayByClub;
}

/** Optional: link owner uuid → holiday code (from clubs map). */
export function setOwnerHolidayByOwnerId(ownerId, entry) {
  const id = String(ownerId || "").trim();
  if (!id || !entry?.code) return;
  holidayByOwnerId.set(id, entry);
}

export function ownerHolidayStatusForClub(clubShort) {
  const key = String(clubShort || "").trim().toUpperCase();
  if (!key) return null;
  return holidayByClub.get(key) || null;
}

export function ownerHolidayStatusForOwner(ownerId) {
  const id = String(ownerId || "").trim();
  if (!id) return null;
  return holidayByOwnerId.get(id) || null;
}

/**
 * Load active-supporter flags (+ public badge paths) from gpsl_owner_profile_public.
 * Safe to call repeatedly; uses an in-memory cache.
 */
export async function loadOwnerSupporterMap({ force = false } = {}) {
  if (supporterMapLoaded && !force) return supporterByOwnerId;
  const { data, error } = await supabase
    .from("gpsl_owner_profile_public")
    .select("owner_id, owner_tag, is_supporter, badge_path");
  if (error) {
    console.warn("loadOwnerSupporterMap:", error.message || error);
    return supporterByOwnerId;
  }
  supporterByOwnerId.clear();
  supporterByOwnerTag.clear();
  for (const row of data || []) {
    const id = String(row.owner_id || "").trim();
    const tag = String(row.owner_tag || "").trim().toLowerCase();
    if (id) {
      supporterByOwnerId.set(id, {
        is_supporter: !!row.is_supporter,
        badge_path: pathOrEmpty(row.badge_path),
      });
    }
    if (tag) supporterByOwnerTag.set(tag, !!row.is_supporter);
  }
  supporterMapLoaded = true;
  return supporterByOwnerId;
}

export function ownerIsSupporter(ownerId, ownerTag) {
  const id = String(ownerId || "").trim();
  if (id && supporterByOwnerId.get(id)?.is_supporter) return true;
  const tag = String(ownerTag || "").trim().toLowerCase();
  if (tag && supporterByOwnerTag.get(tag)) return true;
  return false;
}

export function ownerPublicBadgePath(ownerId) {
  const id = String(ownerId || "").trim();
  if (!id) return null;
  return supporterByOwnerId.get(id)?.badge_path || null;
}

/**
 * Compact badge image + owner tag + optional Supporter mark.
 * Falls back to the loaded supporter map when isSupporter / badgePath omitted.
 */
export function ownerTagHtml({
  ownerId,
  ownerTag,
  badgePath,
  isSupporter,
  holidayCode,
  clubShortName,
  size = 18,
  link = true,
  showBadgeImage = true,
  compact = true,
} = {}) {
  const label = String(ownerTag || "Owner").trim() || "Owner";
  const escaped = escapeHtml(label);
  const resolvedSupporter =
    typeof isSupporter === "boolean"
      ? isSupporter
      : ownerIsSupporter(ownerId, label);
  const holiday =
    holidayCode ||
    ownerHolidayStatusForClub(clubShortName)?.code ||
    ownerHolidayStatusForOwner(ownerId)?.code ||
    null;
  const resolvedBadge = showBadgeImage
    ? pathOrEmpty(badgePath) || ownerPublicBadgePath(ownerId)
    : null;
  const url = ownerBadgePublicUrl(resolvedBadge);
  const img = url
    ? `<img class="owner-tag-badge-img" src="${escapeHtml(url)}" alt="" width="${size}" height="${size}" style="width:${size}px;height:${size}px;border-radius:4px;object-fit:cover;vertical-align:middle;margin-right:6px;border:1px solid #444">`
    : "";
  const mark = supporterMarkHtml(resolvedSupporter, { compact });
  const holidayMark = holidayStatusMarkHtml(holiday);
  const inner = `${img}<span class="owner-tag-label">${escaped}</span>${holidayMark}${mark}`;
  const href = link ? ownerProfileHref(ownerId) : null;
  if (!href) return `<span class="owner-tag-chip">${inner}</span>`;
  return `<a class="gpsl-link owner-tag-chip" href="${escapeHtml(href)}">${inner}</a>`;
}
