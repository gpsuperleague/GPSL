// ===============================
// GLOBAL.JS — Shared App Logic
// ===============================

import { supabase } from "./supabase_client.js";
import { formatCountdown } from "./global_ui.js";

// GLOBAL STATE
let draftEnabled = false;
let draftStart = null;
let draftFinish = null;

// ===============================
// LOAD GLOBAL SETTINGS
// ===============================
export async function loadGlobalSettings() {
  const { data } = await supabase
    .from("global_settings")
    .select("draft_auction_enabled, draft_auction_start_time, draft_random_finish_time")
    .eq("id", 1)
    .single();

  draftEnabled = data?.draft_auction_enabled === true;

  if (draftEnabled) {
    draftStart = data.draft_auction_start_time ? new Date(data.draft_auction_start_time) : null;
    draftFinish = data.draft_random_finish_time ? new Date(data.draft_random_finish_time) : null;

    updateDraftCountdown();
    setInterval(updateDraftCountdown, 1000);
  } else {
    document.getElementById("draftCountdown").textContent = "";
  }
}

// ===============================
// COUNTDOWN
// ===============================
function updateDraftCountdown() {
  const el = document.getElementById("draftCountdown");
  if (!draftEnabled || !draftStart || !draftFinish) {
    el.textContent = "";
    return;
  }

  const now = new Date();

  if (now < draftStart) {
    el.textContent = "Draft starts in: " + formatCountdown(draftStart - now);
  } else if (now >= draftStart && now < draftFinish) {
    el.textContent = "Draft ends in: " + formatCountdown(draftFinish - now);
  } else {
    el.textContent = "Draft auction has ended";
  }
}

// ===============================
// NAVIGATION BUILDER
// ===============================
export async function buildNav() {
  const nav = document.getElementById("nav");

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const buttons = [
    { page: "index", label: "Home", href: "index.html" },
    { page: "gpdb", label: "Player Database", href: "GPDB.html" },
    { page: "clubs", label: "Clubs", href: "clubs.html" },
    { page: "listings", label: "Transfer Market", href: "all_listings.html" },
    { page: "dashboard", label: "Dashboard", href: "dashboard.html" }
  ];

  let html = "";

  for (const btn of buttons) {
    if (btn.page !== window.CURRENT_PAGE) {
      html += `<a href="${btn.href}" class="button">${btn.label}</a>`;
    }
  }

  if (user.email === "rotavator66@outlook.com" && window.CURRENT_PAGE !== "admin") {
    html += `<a href="admin.html" class="button">GPSL Admin</a>`;
  }

  if (draftEnabled && window.CURRENT_PAGE !== "draftauction") {
    html += `<a href="draftauction.html" class="button">Draft Auction</a>`;
  }

  html += `<button id="logoutBtn" class="button">Logout</button>`;
  nav.innerHTML = html;

  document.getElementById("logoutBtn").onclick = async () => {
    await supabase.auth.signOut();
    window.location = "login.html";
  };
}

// ===============================
// PAGE INITIALISATION
// ===============================
export async function initGlobal() {
  await loadGlobalSettings();
  await buildNav();
}
