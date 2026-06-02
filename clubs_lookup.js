// clubs_lookup.js

// Use the global authenticated Supabase client created in firebase.js
const supabase = window.supabase;

let clubsMap = new Map();

/** Sentinel Clubs.ShortName for sell-to-foreign transfer history (not playable). */
export const FOREIGN_BUYER_SHORT = "FOREIGN";

/* ============================================================
   Load all clubs into memory
   ============================================================ */
export async function loadClubsMap() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club");

  if (error) {
    console.error("Failed to load clubs map:", error);
    return;
  }

  clubsMap.clear();

  data.forEach(row => {
    clubsMap.set(row.ShortName, row.Club);
  });

  console.log("Clubs map loaded:", clubsMap);
}

/* ============================================================
   Convert ShortName → Full Club Name
   ============================================================ */
export function fullClubName(shortName) {
  return clubsMap.get(shortName) || shortName;
}

export function isForeignBuyerClub(shortName) {
  return shortName === FOREIGN_BUYER_SHORT;
}

/** Transfer Centre / history: human label for buyer (incl. foreign sales). */
export function buyerClubLabel(shortName) {
  if (!shortName) return "—";
  if (isForeignBuyerClub(shortName)) return "Foreign club";
  return fullClubName(shortName) || shortName;
}

/** Link to club squad page (same as clubs.html grid). */
export function clubPageHref(shortName) {
  if (isForeignBuyerClub(shortName)) return null;
  const club = fullClubName(shortName);
  return `club.html?club=${encodeURIComponent(club)}`;
}
