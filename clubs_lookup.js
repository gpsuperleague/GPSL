// Global lookup map: ShortName → Full Name
let CLUBS_MAP = {};
let CLUBS_LOADED = false;

export async function loadClubsMap() {
  if (CLUBS_LOADED) return; // Prevent double-loading

  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club");

  if (error) {
    console.error("❌ Failed to load Clubs map:", error);
    return;
  }

  data.forEach(row => {
    CLUBS_MAP[row.ShortName] = row.Club;
  });

  CLUBS_LOADED = true;
  console.log("📌 Clubs map loaded:", CLUBS_MAP);
}
