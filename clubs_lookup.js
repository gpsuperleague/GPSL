// clubs_lookup.js

let clubsMap = new Map();
let stadiumMap = new Map();
let ownerTagsMap = new Map();
/** @type {Map<string, string>} club ShortName → owner uuid */
let ownerIdsMap = new Map();

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

  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Stadium, owner, owner_id");

  if (error) {
    console.error("Failed to load clubs map:", error);
    return;
  }

  clubsMap.clear();
  stadiumMap.clear();
  ownerTagsMap.clear();
  ownerIdsMap.clear();

  data.forEach(row => {
    clubsMap.set(row.ShortName, row.Club);
    if (row.Stadium?.trim()) stadiumMap.set(row.ShortName, row.Stadium.trim());
    const tag = row.owner?.trim();
    if (tag) ownerTagsMap.set(row.ShortName, tag);
    const oid = row.owner_id ? String(row.owner_id).trim() : "";
    if (oid) ownerIdsMap.set(row.ShortName, oid);
  });

}

/* ============================================================
   Convert ShortName → Full Club Name
   ============================================================ */
export function fullClubName(shortName) {
  return clubsMap.get(shortName) || shortName;
}

export function stadiumName(shortName) {
  return stadiumMap.get(shortName) || null;
}

export function ownerTagForClub(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return ownerTagsMap.get(key) || null;
}

export function ownerIdForClub(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return ownerIdsMap.get(key) || null;
}

/** True when the club has a linked owner account (owner_id). */
export function clubHasOwner(shortName) {
  return Boolean(ownerIdForClub(shortName));
}

/**
 * @param {string} homeShort
 * @param {string} awayShort
 * @returns {{ homeOwned: boolean, awayOwned: boolean, isPartialVacant: boolean, isVacantVsVacant: boolean }}
 */
export function fixtureOwnerOccupancy(homeShort, awayShort) {
  const homeOwned = clubHasOwner(homeShort);
  const awayOwned = clubHasOwner(awayShort);
  return {
    homeOwned,
    awayOwned,
    isPartialVacant: homeOwned !== awayOwned,
    isVacantVsVacant: !homeOwned && !awayOwned,
  };
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

/** Discord owner tag → owner profile when owner_id is known. */
export function ownerTagLinkHtml(tag, ownerId) {
  const label = String(tag || "").trim();
  if (!label) return "";
  const escaped = escapeHtml(label);
  const href = ownerProfileHref(ownerId);
  if (!href) return `<span class="club-owner-tag">${escaped}</span>`;
  return `<a class="club-owner-tag" href="${escapeHtml(href)}" title="Owner history">${escaped}</a>`;
}

/** Club name plus optional Discord owner tag (layout: block = fixtures, inline = tables).
 *  Name → club history; tag → owner profile; use clubPageHref for details (badge / “club page”). */
export function clubWithOwnerHtml(clubName, shortName, layout = "inline") {
  const name = escapeHtml(clubName || shortName || "—");
  const tag = ownerTagForClub(shortName);
  const oid = ownerIdForClub(shortName);
  let tagHtml = ownerTagLinkHtml(tag, oid);
  if (!tagHtml && layout === "block" && shortName && !oid) {
    tagHtml = `<span class="club-owner-tag club-owner-tag--vacant">Vacant</span>`;
  }
  const href = clubHistoryHref(shortName);
  const linkedName = href
    ? `<a href="${escapeHtml(href)}" class="standings-club-link" title="Club history">${name}</a>`
    : name;

  if (layout === "block") {
    const blockName = href
      ? `<a href="${escapeHtml(href)}" class="fixture-club-link" title="Club history">${name}</a>`
      : name;
    return `<span class="fixture-club"><span class="fixture-club-name">${blockName}</span>${tagHtml}</span>`;
  }

  return `<span class="standings-club">${linkedName}${tagHtml}</span>`;
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
  const fromShort = clubsMap.get(key);
  if (fromShort) return fromShort;
  for (const [short, full] of clubsMap.entries()) {
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

  if (!row.buyer_club_id && foreignName) {
    return foreignName;
  }

  return displayTransferBuyer(row);
}

export function formatSeasonSaleType(row) {
  const note = String(row?.transfer_sale_note || "").trim();
  if (note === "squad_overflow") return "Squad over 28";
  if (note === "contract_expiry") return "Contract Run Down";
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
