// clubs_lookup.js

// Use the global authenticated Supabase client created in firebase.js
const supabase = window.supabase;

let clubsMap = new Map();

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

/** Link to club squad page (same as clubs.html grid). */
export function clubPageHref(shortName) {
  const club = fullClubName(shortName);
  return `club.html?club=${encodeURIComponent(club)}`;
}
