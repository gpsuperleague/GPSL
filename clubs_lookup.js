// clubs_lookup.js

let clubsMap = new Map();

// Load all clubs into memory
export async function loadClubsMap() {
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club");

  if (error) {
    console.error("Failed to load clubs map:", error);
    return;
  }

  data.forEach(row => {
    clubsMap.set(row.ShortName, row.Club);
  });

  console.log("Clubs map loaded:", clubsMap);
}

// Return full club name from ShortName
export function fullClubName(shortName) {
  return clubsMap.get(shortName) || shortName;
}
