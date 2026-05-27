// ===============================
// DASHBOARD.JS — Live, Modern Version
// ===============================

import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";   // ⬅ FIXED: removed startDraftCountdown
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

document.addEventListener("DOMContentLoaded", async () => {
  // Load global nav + countdown container
  // ⬅ This now ALSO starts the draft countdown automatically
  await initGlobal();

  // Get user
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  // Load club info
  const { data: club, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("owner_id", user.id)
    .single();

  if (error || !club) {
    console.error("No club for user:", error);
    document.getElementById("dashboardTitle").textContent = "GPSL Dashboard";
    return;
  }

  // Load club map for full names
  await loadClubsMap();

  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club || shortName;

  // Update header
  document.getElementById("dashboardTitle").textContent = `${fullName} Dashboard`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  // ⭐ No need to call startDraftCountdown()
  // initGlobal() already handles the countdown
});
