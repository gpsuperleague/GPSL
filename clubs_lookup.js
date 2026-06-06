// clubs_lookup.js

let clubsMap = new Map();
let ownerTagsMap = new Map();

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
    .select("ShortName, Club, owner");

  if (error) {
    console.error("Failed to load clubs map:", error);
    return;
  }

  clubsMap.clear();
  ownerTagsMap.clear();

  data.forEach(row => {
    clubsMap.set(row.ShortName, row.Club);
    const tag = row.owner?.trim();
    if (tag) ownerTagsMap.set(row.ShortName, tag);
  });

  console.log("Clubs map loaded:", clubsMap);
}

/* ============================================================
   Convert ShortName → Full Club Name
   ============================================================ */
export function fullClubName(shortName) {
  return clubsMap.get(shortName) || shortName;
}

export function ownerTagForClub(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return ownerTagsMap.get(key) || null;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Club name plus optional Discord owner tag (layout: block = fixtures, inline = tables). */
export function clubWithOwnerHtml(clubName, shortName, layout = "inline") {
  const name = escapeHtml(clubName || shortName || "—");
  const tag = ownerTagForClub(shortName);
  const tagHtml = tag
    ? `<span class="club-owner-tag">${escapeHtml(tag)}</span>`
    : "";
  const href = clubPageHref(shortName);
  const linkedName = href
    ? `<a href="${escapeHtml(href)}" class="standings-club-link">${name}</a>`
    : name;

  if (layout === "block") {
    const blockName = href
      ? `<a href="${escapeHtml(href)}" class="fixture-club-link">${name}</a>`
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

  if (!row.buyer_club_id && foreignName) {
    return foreignName;
  }

  return displayTransferBuyer(row);
}

export function formatSeasonSaleType(row) {
  const note = String(row?.transfer_sale_note || "").trim();
  if (note === "squad_overflow") return "Squad over 28";
  if (isForeignBuyerClub(row?.buyer_club_id)) return "Foreign sale";
  if (!row?.buyer_club_id) return "Released";
  return "Transfer";
}

/** Link to club squad page (same as clubs.html grid). */
export function clubPageHref(shortName) {
  if (isForeignBuyerClub(shortName)) return null;
  const club = fullClubName(shortName);
  return `club.html?club=${encodeURIComponent(club)}`;
}
