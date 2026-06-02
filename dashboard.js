// ===============================
// DASHBOARD.JS — Unified Version
// ===============================

import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { fetchActiveSpecialAuction } from "./special_auction.js";
import { refreshDashboardInbox } from "./competition_inbox.js";

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

  // Load club info (maybeSingle avoids 406 when owner has no club row)
  const { data: club, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (error) {
    console.error("Club lookup failed:", error);
  }

  if (!club) {
    document.getElementById("dashboardTitle").textContent = "GPSL Dashboard";
    showNoClubBanner(user.email);
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

  await refreshDashboardInbox(supabase);
});

function showNoClubBanner(email) {
  let banner = document.getElementById("noClubBanner");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "noClubBanner";
    banner.style.cssText =
      "background:#331a1a;border:1px solid #933;color:#fcc;" +
      "padding:14px 16px;border-radius:8px;margin-bottom:20px;font-size:14px;line-height:1.5;";
    const grid = document.querySelector(".tile-grid");
    if (grid?.parentNode) {
      grid.parentNode.insertBefore(banner, grid);
    } else {
      document.querySelector(".page-container")?.prepend(banner);
    }
  }
  banner.innerHTML = `
    <b>No club linked to this login.</b><br>
    Match Day, inbox, and squad need <code>Clubs.owner_id</code> set to this user&apos;s UUID
    (<span style="color:#aaa;font-size:12px;">${email || "signed-in user"}</span>).
    In Supabase → Table Editor → <b>Clubs</b>, set <b>owner_id</b> on the club you are testing as,
    or ask admin to assign it.
  `;
  const badge = document.getElementById("clubBadgeHeader");
  if (badge) badge.style.visibility = "hidden";
}
