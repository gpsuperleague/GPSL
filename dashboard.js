// ===============================
// DASHBOARD.JS — Hub Page Only
// ===============================

import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";

document.addEventListener("DOMContentLoaded", async () => {
  // Global nav + countdown
  await initGlobal();

  // Get user
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  // Get club for this user
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

  await loadClubsMap();

  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club || shortName;

  document.getElementById("dashboardTitle").textContent = `${fullName} Dashboard`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;
});
