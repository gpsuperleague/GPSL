// ===============================
// DASHBOARD.JS — Customizable owner tiles
// ===============================

import { APP_VERSION } from "./app_version.js";
import { supabase, initGlobal, isGpslAdminUser, wireDraftCountdownUI } from `./global.js?v=${APP_VERSION}`;
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { fetchActiveSpecialAuction } from "./special_auction.js";
import { getDashboardPanel, getDashboardTileUrl } from "./dashboard_registry.js";
import {
  loadOwnerDashboardLayout,
  saveOwnerDashboardLayout,
} from "./dashboard_layout.js";
import { refreshAllDashboardPins } from "./dashboard_pin.js";
import {
  applyClubDashboardTheme,
  loadClubDashboardTheme,
} from "./club_theme_common.js";

let ownerId = null;
let isAdmin = false;
let panelIds = [];
let editMode = false;
let dragPanelId = null;
let layoutSaveTimer = null;

document.addEventListener("DOMContentLoaded", async () => {
  try {
    await initGlobal();
  } catch (err) {
    console.error("initGlobal failed:", err);
    wireDraftCountdownUI();
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  ownerId = user.id;
  isAdmin = isGpslAdminUser(user);
  document.getElementById("userEmail").textContent = user.email;

  const { data: club, error } = await supabase
    .from("Clubs")
    .select("*")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (error) console.error("Club lookup failed:", error);

  const { data: settings } = await supabase
    .from("global_settings_public")
    .select("draft_auction_enabled")
    .eq("id", 1)
    .maybeSingle();

  const draftEnabled = settings?.draft_auction_enabled === true;
  const specialAuction = await fetchActiveSpecialAuction(supabase);

  // Render tiles before optional club-name lookup (avoids blank grid if loadClubsMap fails)
  await initDashboardGrid(user.id, { draftEnabled, specialAuction });
  wireDashboardToolbar();

  if (!club) {
    document.getElementById("dashboardTitle").textContent = "GPSL Dashboard";
    showNoClubBanner(user.email);
    return;
  }

  try {
    await loadClubsMap();
  } catch (err) {
    console.warn("loadClubsMap failed:", err);
  }

  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club || shortName;

  document.getElementById("dashboardTitle").textContent = `${fullName} Dashboard`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  try {
    const theme = await loadClubDashboardTheme(supabase, shortName);
    applyClubDashboardTheme(theme, { pageKey: "dashboard" });
  } catch (err) {
    console.warn("Dashboard theme:", err);
  }
});

async function initDashboardGrid(uid, { draftEnabled, specialAuction }) {
  try {
    panelIds = await loadOwnerDashboardLayout(supabase, uid);
  } catch (err) {
    console.error("Load dashboard layout:", err);
    const hint = document.getElementById("dashboardLayoutWarn");
    if (hint) {
      hint.hidden = false;
      hint.textContent =
        "Custom layout unavailable — run supabase/sql/owner_dashboard_layout.sql. Showing defaults.";
    }
    const { DEFAULT_DASHBOARD_PANEL_IDS } = await import("./dashboard_registry.js");
    panelIds = [...DEFAULT_DASHBOARD_PANEL_IDS];
  }

  renderDashboardTiles({ draftEnabled, specialAuction });
}

function filterVisiblePanelIds(ids, { draftEnabled, specialAuction }) {
  return ids.filter((id) => {
    const panel = getDashboardPanel(id);
    if (!panel) return false;
    if (panel.adminOnly && !isAdmin) return false;
    if (panel.requiresDraft && !draftEnabled) return false;
    if (panel.when === "special_auction" && !specialAuction) return false;
    return true;
  });
}

function renderDashboardTiles(ctx) {
  const grid = document.getElementById("dashboardGrid");
  const empty = document.getElementById("dashboardEmpty");
  if (!grid) return;

  const visible = filterVisiblePanelIds(panelIds, ctx);
  grid.innerHTML = "";
  grid.classList.toggle("dashboard-edit-mode", editMode);

  if (!visible.length) {
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  for (const id of visible) {
    const panel = getDashboardPanel(id);
    if (!panel) continue;

    const tile = document.createElement("div");
    tile.className = "tile dashboard-tile";
    tile.dataset.panelId = id;
    const tileArt = getDashboardTileUrl(panel);
    if (tileArt) {
      tile.dataset.tileImage = "1";
      tile.style.setProperty("--tile-art", `url("${tileArt}")`);
    }
    tile.draggable = editMode;

    const label = document.createElement("span");
    label.className = "dashboard-tile-label";
    label.textContent =
      panel.when === "special_auction" && ctx.specialAuction?.title
        ? `Special Auction: ${ctx.specialAuction.title}`
        : panel.label;
    tile.appendChild(label);

    if (!editMode) {
      tile.addEventListener("click", () => {
        window.location.href = panel.href;
      });
    }

    if (editMode) {
      const grip = document.createElement("span");
      grip.className = "dashboard-tile-grip";
      grip.textContent = "⋮⋮";
      grip.setAttribute("aria-hidden", "true");

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "dashboard-tile-remove";
      remove.setAttribute("aria-label", `Remove ${panel.label} from dashboard`);
      remove.textContent = "×";
      remove.addEventListener("click", (e) => {
        e.stopPropagation();
        removePanelFromLayout(id, ctx);
      });

      tile.prepend(grip);
      tile.appendChild(remove);
      wireTileDrag(tile, ctx);
    }

    grid.appendChild(tile);
  }
}

function wireTileDrag(tile, ctx) {
  tile.addEventListener("dragstart", (e) => {
    dragPanelId = tile.dataset.panelId;
    tile.classList.add("dashboard-tile-dragging");
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", dragPanelId);
  });

  tile.addEventListener("dragend", () => {
    tile.classList.remove("dashboard-tile-dragging");
    dragPanelId = null;
    document.querySelectorAll(".dashboard-tile-drop-target").forEach((el) => {
      el.classList.remove("dashboard-tile-drop-target");
    });
  });

  tile.addEventListener("dragover", (e) => {
    e.preventDefault();
    const overId = tile.dataset.panelId;
    if (!dragPanelId || overId === dragPanelId) return;
    e.dataTransfer.dropEffect = "move";
    tile.classList.add("dashboard-tile-drop-target");
  });

  tile.addEventListener("dragleave", () => {
    tile.classList.remove("dashboard-tile-drop-target");
  });

  tile.addEventListener("drop", (e) => {
    e.preventDefault();
    tile.classList.remove("dashboard-tile-drop-target");
    const targetId = tile.dataset.panelId;
    if (!dragPanelId || !targetId || dragPanelId === targetId) return;

    const from = panelIds.indexOf(dragPanelId);
    const to = panelIds.indexOf(targetId);
    if (from < 0 || to < 0) return;

    const next = [...panelIds];
    next.splice(from, 1);
    next.splice(to, 0, dragPanelId);
    panelIds = next;
    scheduleLayoutSave();
    renderDashboardTiles(ctx);
  });
}

function removePanelFromLayout(panelId, ctx) {
  panelIds = panelIds.filter((id) => id !== panelId);
  scheduleLayoutSave();
  renderDashboardTiles(ctx);
  refreshAllDashboardPins();
}

function scheduleLayoutSave() {
  if (!ownerId) return;
  clearTimeout(layoutSaveTimer);
  layoutSaveTimer = setTimeout(async () => {
    try {
      await saveOwnerDashboardLayout(supabase, ownerId, panelIds);
    } catch (err) {
      console.error("Save dashboard layout:", err);
    }
  }, 400);
}

function wireDashboardToolbar() {
  const btn = document.getElementById("dashboardEditBtn");
  const hint = document.getElementById("dashboardEditHint");
  if (!btn) return;

  btn.addEventListener("click", async () => {
    editMode = !editMode;
    btn.textContent = editMode ? "Done arranging" : "Arrange tiles";
    btn.setAttribute("aria-pressed", editMode ? "true" : "false");
    if (hint) hint.hidden = !editMode;

    const { data: settings } = await supabase
      .from("global_settings_public")
      .select("draft_auction_enabled")
      .eq("id", 1)
      .maybeSingle();
    const draftEnabled = settings?.draft_auction_enabled === true;
    const specialAuction = await fetchActiveSpecialAuction(supabase);

    renderDashboardTiles({ draftEnabled, specialAuction });
  });
}

function showNoClubBanner(email) {
  let banner = document.getElementById("noClubBanner");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "noClubBanner";
    banner.style.cssText =
      "background:#331a1a;border:1px solid #933;color:#fcc;" +
      "padding:14px 16px;border-radius:8px;margin-bottom:20px;font-size:14px;line-height:1.5;";
    const toolbar = document.querySelector(".dashboard-toolbar");
    const grid = document.getElementById("dashboardGrid");
    const anchor = toolbar || grid;
    if (anchor?.parentNode) {
      anchor.parentNode.insertBefore(banner, anchor);
    } else {
      document.querySelector(".page-container")?.prepend(banner);
    }
  }
  const adminNote = isAdmin
    ? `<br><span style="color:#9f9;">League admin — you can open any page from the nav while you wait (Finances has a club preview dropdown).</span>`
    : "";
  banner.innerHTML = `
    <b>No club linked to this login.</b><br>
    New owners join via the <a href="awaiting_club.html" style="color:#ff9900;">club auction</a>
    (starting budget set by admin). Set your owner tag there while you wait.${adminNote}<br>
    <span style="color:#aaa;font-size:12px;">${email || "signed-in user"}</span> —
    admin can register you with <code>admin_owner_register_for_club_auction(email)</code>
    after <code>owner_onboarding_club_auction.sql</code> is applied.
  `;
  const badge = document.getElementById("clubBadgeHeader");
  if (badge) badge.style.visibility = "hidden";
}
