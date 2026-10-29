// clubs_lookup.js

import {
  loadOwnerSupporterMap,
  loadOwnerHolidayStatusMap,
  ownerHolidayStatusForClub,
  setOwnerHolidayByOwnerId,
  ownerTagHtml,
} from "./owner_badge.js";

let clubsMap = new Map();
/** @type {Map<string, string>} upper(ShortName) → Club (case-insensitive lookup) */
let clubsMapUpper = new Map();
let stadiumMap = new Map();
let ownerTagsMap = new Map();
/** @type {Map<string, string>} club ShortName → owner uuid */
let ownerIdsMap = new Map();
/** @type {Map<string, string>} club ShortName → owner_assigned_at ISO */
let ownerAssignedAtMap = new Map();
/** @type {Set<string>} upper ShortName on active season absence */
const seasonAbsentClubs = new Set();

function getSupabase() {
  return window.supabase;
}

/** Sentinel Clubs.ShortName for sell-to-foreign transfer history (not playable). */
export const FOREIGN_BUYER_SHORT = "FOREIGN";

/* ============================================================
   Load all clubs into memory
   ============================================================ */
export async function loadClubsMap() {
  const supabase = getSupabase();
  if (!supabase?.from) {
    console.warn("loadClubsMap: supabase not ready yet");
    return;
  }

  let { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Stadium, owner, owner_id, owner_assigned_at");

  if (error) {
    // Older DBs / schema cache without owner_assigned_at — still load clubs
    const fallback = await supabase
      .from("Clubs")
      .select("ShortName, Club, Stadium, owner, owner_id");
    data = fallback.data;
    error = fallback.error;
  }

  if (error) {
    console.error("Failed to load clubs map:", error);
    return;
  }

  clubsMap.clear();
  clubsMapUpper.clear();
  stadiumMap.clear();
  ownerTagsMap.clear();
  ownerIdsMap.clear();
  ownerAssignedAtMap.clear();
  seasonAbsentClubs.clear();

  data.forEach(row => {
    const short = String(row.ShortName || "").trim();
    if (!short) return;
    clubsMap.set(short, row.Club);
    clubsMapUpper.set(short.toUpperCase(), row.Club);
    if (row.Stadium?.trim()) stadiumMap.set(short, row.Stadium.trim());
    const tag = row.owner?.trim();
    if (tag) {
      ownerTagsMap.set(short, tag);
      ownerTagsMap.set(short.toUpperCase(), tag);
    }
    const oid = row.owner_id ? String(row.owner_id).trim() : "";
    if (oid) {
      ownerIdsMap.set(short, oid);
      ownerIdsMap.set(short.toUpperCase(), oid);
    }
    const assigned = row.owner_assigned_at
      ? String(row.owner_assigned_at).trim()
      : "";
    if (assigned) {
      ownerAssignedAtMap.set(short.toUpperCase(), assigned);
    }
  });

  // Supporter + holiday (UH/OH) marks for owner tags on fixtures / tables / etc.
  try {
    await loadOwnerSupporterMap();
  } catch (err) {
    console.warn("loadClubsMap: supporter map", err);
  }
  try {
    await loadOwnerHolidayStatusMap();
    for (const [short, oid] of ownerIdsMap.entries()) {
      const hol = ownerHolidayStatusForClub(short);
      if (hol) setOwnerHolidayByOwnerId(oid, hol);
    }
  } catch (err) {
    console.warn("loadClubsMap: holiday map", err);
  }
  try {
    await loadSeasonAbsentClubsMap(supabase);
  } catch (err) {
    console.warn("loadClubsMap: season absence map", err);
  }
}

/** Batch-load clubs on active season absence. */
export async function loadSeasonAbsentClubsMap(supabaseClient = null) {
  const supabase = supabaseClient || getSupabase();
  seasonAbsentClubs.clear();
  if (!supabase?.rpc) return seasonAbsentClubs;
  const { data, error } = await supabase.rpc("season_absent_clubs_map");
  if (error) {
    console.warn("season_absent_clubs_map:", error.message || error);
    return seasonAbsentClubs;
  }
  const map = data && typeof data === "object" ? data : {};
  for (const [club, on] of Object.entries(map)) {
    if (on) seasonAbsentClubs.add(String(club).trim().toUpperCase());
  }
  return seasonAbsentClubs;
}

/* ============================================================
   Convert ShortName → Full Club Name
   ============================================================ */
export function fullClubName(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return key;
  return clubsMap.get(key) || clubsMapUpper.get(key.toUpperCase()) || key;
}

export function stadiumName(shortName) {
  return stadiumMap.get(shortName) || null;
}

export function ownerTagForClub(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return ownerTagsMap.get(key) || ownerTagsMap.get(key.toUpperCase()) || null;
}

export function ownerIdForClub(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return ownerIdsMap.get(key) || ownerIdsMap.get(key.toUpperCase()) || null;
}

/** When the current owner was assigned (ISO), if known. */
export function ownerAssignedAtForClub(shortName) {
  const key = String(shortName || "").trim().toUpperCase();
  if (!key) return null;
  return ownerAssignedAtMap.get(key) || null;
}

/** True when the club has a linked owner account (owner_id). */
export function clubHasOwner(shortName) {
  return Boolean(ownerIdForClub(shortName));
}

/** Live check: club on active season absence (finance freeze). */
export async function clubIsSeasonAbsent(supabase, clubShort, seasonId = null) {
  if (!supabase?.rpc || !clubShort) return false;
  const { data, error } = await supabase.rpc("club_is_season_absent", {
    p_club: clubShort,
    p_season_id: seasonId,
  });
  if (error) return false;
  return Boolean(data);
}

/** Sync: from map loaded with loadClubsMap / loadSeasonAbsentClubsMap. */
export function clubIsSeasonAbsentCached(shortName) {
  const key = String(shortName || "").trim().toUpperCase();
  if (!key) return false;
  return seasonAbsentClubs.has(key);
}

/**
 * @param {string} homeShort
 * @param {string} awayShort
 * @returns {{ homeOwned: boolean, awayOwned: boolean, isPartialVacant: boolean, isVacantVsVacant: boolean, homeAbsent: boolean, awayAbsent: boolean, involvesSeasonAbsent: boolean }}
 */
export function fixtureOwnerOccupancy(homeShort, awayShort) {
  const homeOwned = clubHasOwner(homeShort);
  const awayOwned = clubHasOwner(awayShort);
  const homeAbsent = clubIsSeasonAbsentCached(homeShort);
  const awayAbsent = clubIsSeasonAbsentCached(awayShort);
  return {
    homeOwned,
    awayOwned,
    isPartialVacant: homeOwned !== awayOwned,
    isVacantVsVacant: !homeOwned && !awayOwned,
    homeAbsent,
    awayAbsent,
    involvesSeasonAbsent: homeAbsent || awayAbsent,
  };
}

/** Pill shown next to club name when owner is on season absence. */
export function seasonAbsentMarkHtml() {
  return `<span class="club-owner-tag club-owner-tag--absent" title="Season absence — owner away; fixtures awarded to opponents (like vacant)">Away</span>`;
}

/** Owner profile / history page for a club’s current owner. */
export function ownerProfileHref(ownerId) {
  const id = String(ownerId || "").trim();
  if (!id) return null;
  return `owner_profile.html?owner=${encodeURIComponent(id)}`;
}

export function ownerProfileHrefForClub(shortName) {
  return ownerProfileHref(ownerIdForClub(shortName));
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Discord owner tag → owner profile when owner_id is known (+ Supporter / UH·OH marks). */
export function ownerTagLinkHtml(tag, ownerId, clubShortName = null) {
  const label = String(tag || "").trim();
  if (!label) return "";
  const html = ownerTagHtml({
    ownerId,
    ownerTag: label,
    clubShortName,
    link: !!ownerId,
    showBadgeImage: true,
    compact: true,
  });
  return html
    .replace(
      'class="gpsl-link owner-tag-chip"',
      'class="gpsl-link club-owner-tag owner-tag-chip"'
    )
    .replace('class="owner-tag-chip"', 'class="club-owner-tag owner-tag-chip"');
}

/** Club crest thumb from images/club_badges/{ShortName}.png (hidden if missing). */
export function clubBadgeImgHtml(shortName, { className = "club-badge-thumb" } = {}) {
  const short = String(shortName || "").trim().toUpperCase();
  if (!short || short === FOREIGN_BUYER_SHORT) return "";
  const src = `images/club_badges/${escapeHtml(short)}.png`;
  return (
    `<img class="${escapeHtml(className)}" src="${src}" alt="" ` +
    `width="20" height="20" loading="lazy" decoding="async" ` +
    `onerror="this.classList.add('club-badge-thumb--missing')">`
  );
}

/** Club name plus optional Discord owner tag (layout: block = fixtures, inline = tables).
 *  Name → club history; tag → owner profile; crest left of the name when ShortName is known. */
export function clubWithOwnerHtml(clubName, shortName, layout = "inline") {
  const name = escapeHtml(clubName || shortName || "—");
  const tag = ownerTagForClub(shortName);
  const oid = ownerIdForClub(shortName);
  const absent = clubIsSeasonAbsentCached(shortName);
  let tagHtml = ownerTagLinkHtml(tag, oid, shortName);
  if (!tagHtml && layout === "block" && shortName && !oid) {
    tagHtml = `<span class="club-owner-tag club-owner-tag--vacant">Vacant</span>`;
  }
  if (absent) {
    tagHtml = `${tagHtml || ""}${seasonAbsentMarkHtml()}`;
  }
  const href = clubHistoryHref(shortName);
  const linkedName = href
    ? `<a href="${escapeHtml(href)}" class="standings-club-link" title="Club history">${name}</a>`
    : name;
  const badge = clubBadgeImgHtml(shortName);
  const absentCls = absent ? " is-season-absent" : "";

  if (layout === "block") {
    const blockName = href
      ? `<a href="${escapeHtml(href)}" class="fixture-club-link" title="Club history">${name}</a>`
      : name;
    return (
      `<span class="fixture-club${absentCls}">${badge}` +
      `<span class="fixture-club-body"><span class="fixture-club-name">${blockName}</span>${tagHtml}</span>` +
      `</span>`
    );
  }

  return (
    `<span class="standings-club${absentCls}">${badge}` +
    `<span class="standings-club-text">${linkedName}${tagHtml}</span>` +
    `</span>`
  );
}

/** ShortName from Clubs.ShortName, or match legacy full club name in history rows. */
export function resolveClubShortName(shortOrFull) {
  const key = String(shortOrFull || "").trim();
  if (!key) return "";
  if (clubsMap.has(key)) return key;
  for (const [short, full] of clubsMap.entries()) {
    if (full === key) return short;
  }
  return key;
}

/** UI label: ShortName or legacy full name → Clubs.Club (DB still uses short codes). */
export function displayClubName(shortOrFull, foreignBuyerName) {
  const key = String(shortOrFull || "").trim();
  if (!key) return "Free agent";
  if (isForeignBuyerClub(key)) {
    const name = String(foreignBuyerName || "").trim();
    return name || "Foreign club";
  }
  const fromShort =
    clubsMap.get(key) || clubsMapUpper.get(key.toUpperCase());
  if (fromShort) return fromShort;
  for (const [, full] of clubsMap.entries()) {
    if (full === key) return full;
  }
  return key;
}

export function isForeignBuyerClub(shortName) {
  return shortName === FOREIGN_BUYER_SHORT;
}

/** Transfer Centre / history: human label for buyer (incl. foreign sales). */
export function buyerClubLabel(shortName, foreignBuyerName) {
  if (!shortName) return "—";
  if (isForeignBuyerClub(shortName)) {
    const name = String(foreignBuyerName || "").trim();
    return name || "Foreign club";
  }
  return fullClubName(shortName) || shortName;
}

/** Transfer row → buyer display (uses foreign_buyer_name when present). */
export function displayTransferBuyer(row) {
  if (!row) return "—";
  return buyerClubLabel(row.buyer_club_id, row.foreign_buyer_name);
}

/** Season Sales / signings — includes squad overflow and MV releases. */
export function formatSeasonSaleDestination(row) {
  if (!row) return "—";

  const note = String(row.transfer_sale_note || "").trim();
  const foreignName = String(row.foreign_buyer_name || "").trim();

  if (note === "squad_overflow") {
    if (isForeignBuyerClub(row.buyer_club_id) && foreignName) {
      return `${foreignName} (squad over 28)`;
    }
    if (foreignName) return foreignName;
    return "Free agent — squad over 28 (market value)";
  }

  if (note === "contract_expiry") {
    return foreignName || "Contract Run Down - Central Bank Compensation";
  }

  if (note === "emergency_loan") {
    return displayTransferBuyer(row);
  }

  if (note === "emergency_loan_return") {
    return foreignName || "Free agent (emergency loan ended)";
  }

  if (!row.buyer_club_id && foreignName) {
    return foreignName;
  }

  return displayTransferBuyer(row);
}

export function formatSeasonSaleType(row) {
  const note = String(row?.transfer_sale_note || "").trim();
  if (note === "squad_overflow") return "Squad over 28";
  if (note === "contract_expiry") return "Contract Run Down";
  if (note === "emergency_loan") return "Emergency loan";
  if (note === "emergency_loan_return") return "Emergency loan ended";
  if (isForeignBuyerClub(row?.buyer_club_id)) return "Foreign sale";
  if (!row?.buyer_club_id) return "Released";
  return "Transfer";
}

/** Link to club details (squad / stadium). Badge and “club page” targets. */
export function clubPageHref(shortName) {
  if (isForeignBuyerClub(shortName)) return null;
  const short = resolveClubShortName(shortName);
  if (!short || isForeignBuyerClub(short)) return null;
  return `club.html?club=${encodeURIComponent(short)}`;
}

/** Link to club history (owners roster, trophies, seasons). Club name targets. */
export function clubHistoryHref(shortName) {
  if (isForeignBuyerClub(shortName)) return null;
  const short = resolveClubShortName(shortName);
  if (!short || isForeignBuyerClub(short)) return null;
  return `history.html?club=${encodeURIComponent(short)}`;
}
