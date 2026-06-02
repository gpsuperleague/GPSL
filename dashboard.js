// ===============================
// DASHBOARD.JS — Unified Version
// ===============================

import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { fetchActiveSpecialAuction } from "./special_auction.js";

document.addEventListener("DOMContentLoaded", async () => {

  // Load global nav + global settings + countdown
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

  const activeSa = await fetchActiveSpecialAuction(supabase);
  const saTile = document.getElementById("specialAuctionTile");
  if (saTile && activeSa) {
    saTile.style.display = "flex";
    saTile.textContent = `Special Auction: ${activeSa.title}`;
  }
});
