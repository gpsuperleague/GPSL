// ===============================
// DASHBOARD.JS — Customizable owner tiles (grouped sections)
// ===============================

import { supabase, initGlobal, isGpslAdminUser, wireDraftCountdownUI } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { fetchActiveSpecialAuction } from "./special_auction.js";
import { getDashboardPanel, getDashboardTileUrl } from "./dashboard_registry.js";
import {
  loadOwnerDashboardLayout,
  saveOwnerDashboardLayout,
  createDashboardSection,
  DEFAULT_SECTION_TITLE,
} from "./dashboard_layout.js";
import { refreshAllDashboardPins } from "./dashboard_pin.js";
import {
  applyClubDashboardTheme,
  loadClubDashboardTheme,
} from "./club_theme_common.js";

let ownerId = null;
let isAdmin = false;
let layoutSections = [];
let editMode = false;
let dragPanelId = null;
let dragFromSectionId = null;
let dragSectionId = null;
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

async function initDashboardGrid(uid, ctx) {
  try {
    layoutSections = await loadOwnerDashboardLayout(supabase, uid);
  } catch (err) {
    console.error("Load dashboard layout:", err);
    const hint = document.getElementById("dashboardLayoutWarn");
    if (hint) {
      hint.hidden = false;
      hint.textContent =
        "Custom layout unavailable — run supabase/sql/owner_dashboard_layout.sql and owner_dashboard_sections.sql. Showing defaults.";
    }
    const { cloneDefaultSections } = await import("./dashboard_layout.js");
    layoutSections = cloneDefaultSections();
  }

  renderDashboardTiles(ctx);
}

function filterVisiblePanelIds(ids, ctx) {
  return ids.filter((id) => {
    const panel = getDashboardPanel(id);
    if (!panel) return false;
    if (panel.adminOnly && !isAdmin) return false;
    if (panel.requiresDraft && !ctx.draftEnabled) return false;
    if (panel.when === "special_auction" && !ctx.specialAuction) return false;
    return true;
  });
}

function visibleSections(ctx) {
  return layoutSections
    .map((sec) => ({
      ...sec,
      panelIds: filterVisiblePanelIds(sec.panelIds, ctx),
    }))
    .filter((sec) => editMode || sec.panelIds.length > 0);
}

function createTileElement(id, ctx) {
  const panel = getDashboardPanel(id);
  if (!panel) return null;

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
  } else {
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
  }

  return tile;
}

function renderDashboardTiles(ctx) {
  const grid = document.getElementById("dashboardGrid");
  const empty = document.getElementById("dashboardEmpty");
  const addSectionBtn = document.getElementById("dashboardAddSectionBtn");
  if (!grid) return;

  const sections = visibleSections(ctx);
  const totalTiles = sections.reduce((n, sec) => n + sec.panelIds.length, 0);

  grid.innerHTML = "";
  grid.classList.toggle("dashboard-edit-mode", editMode);
  if (addSectionBtn) addSectionBtn.hidden = !editMode;

  if (!totalTiles && !editMode) {
    if (empty) empty.hidden = false;
    return;
  }
  if (empty) empty.hidden = true;

  if (editMode && !sections.length) {
    layoutSections = [createDashboardSection()];
    return renderDashboardTiles(ctx);
  }

  for (const sec of sections) {
    const sectionEl = document.createElement("section");
    sectionEl.className = "dashboard-section";
    sectionEl.dataset.sectionId = sec.id;

    const head = document.createElement("div");
    head.className = "dashboard-section-head";

    if (editMode) {
      const grip = document.createElement("span");
      grip.className = "dashboard-section-grip";
      grip.textContent = "⋮⋮";
      grip.title = "Drag to reorder group";
      grip.setAttribute("aria-hidden", "true");
      head.appendChild(grip);

      const titleInput = document.createElement("input");
      titleInput.type = "text";
      titleInput.className = "dashboard-section-title-input";
      titleInput.value = sec.title || DEFAULT_SECTION_TITLE;
      titleInput.maxLength = 48;
      titleInput.placeholder = "Group name";
      titleInput.setAttribute("aria-label", "Group name");
      titleInput.addEventListener("change", () => {
        updateSectionTitle(sec.id, titleInput.value);
      });
      titleInput.addEventListener("blur", () => {
        updateSectionTitle(sec.id, titleInput.value);
      });
      head.appendChild(titleInput);

      if (layoutSections.length > 1) {
        const removeSec = document.createElement("button");
        removeSec.type = "button";
        removeSec.className = "dashboard-section-remove";
        removeSec.setAttribute("aria-label", `Remove group ${sec.title}`);
        removeSec.textContent = "×";
        removeSec.title = "Remove group (tiles move to group above)";
        removeSec.addEventListener("click", (e) => {
          e.stopPropagation();
          removeSection(sec.id, ctx);
        });
        head.appendChild(removeSec);
      }

      wireSectionDrag(head, sec.id, ctx);
    } else {
      const title = document.createElement("h2");
      title.className = "dashboard-section-title";
      title.textContent = sec.title || DEFAULT_SECTION_TITLE;
      head.appendChild(title);
    }

    const sectionGrid = document.createElement("div");
    sectionGrid.className = "tile-grid dashboard-section-grid";
    sectionGrid.dataset.sectionId = sec.id;

    for (const id of sec.panelIds) {
      const tile = createTileElement(id, ctx);
      if (!tile) continue;
      if (editMode) wireTileDrag(tile, sec.id, ctx);
      sectionGrid.appendChild(tile);
    }

    if (editMode) {
      wireSectionGridDrop(sectionGrid, sec.id, ctx);
    }

    sectionEl.appendChild(head);
    sectionEl.appendChild(sectionGrid);
    grid.appendChild(sectionEl);
  }
}

function findSectionIndex(sectionId) {
  return layoutSections.findIndex((s) => s.id === sectionId);
}

function movePanel(panelId, fromSectionId, toSectionId, beforePanelId = null) {
  const fromIdx = findSectionIndex(fromSectionId);
  const toIdx = findSectionIndex(toSectionId);
  if (fromIdx < 0 || toIdx < 0) return;

  const fromIds = [...layoutSections[fromIdx].panelIds];
  const panelPos = fromIds.indexOf(panelId);
  if (panelPos < 0) return;

  fromIds.splice(panelPos, 1);
  layoutSections[fromIdx] = { ...layoutSections[fromIdx], panelIds: fromIds };

  const toIds = fromIdx === toIdx ? fromIds : [...layoutSections[toIdx].panelIds];
  if (fromIdx !== toIdx) {
    const existing = toIds.indexOf(panelId);
    if (existing >= 0) toIds.splice(existing, 1);
  }

  if (beforePanelId) {
    const insertAt = toIds.indexOf(beforePanelId);
    if (insertAt >= 0) toIds.splice(insertAt, 0, panelId);
    else toIds.push(panelId);
  } else {
    toIds.push(panelId);
  }

  layoutSections[toIdx] = { ...layoutSections[toIdx], panelIds: toIds };
}

function wireTileDrag(tile, sectionId, ctx) {
  tile.addEventListener("dragstart", (e) => {
    dragPanelId = tile.dataset.panelId;
    dragFromSectionId = sectionId;
    dragSectionId = null;
    tile.classList.add("dashboard-tile-dragging");
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", dragPanelId);
  });

  tile.addEventListener("dragend", () => {
    tile.classList.remove("dashboard-tile-dragging");
    dragPanelId = null;
    dragFromSectionId = null;
    clearDropHighlights();
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
    e.stopPropagation();
    tile.classList.remove("dashboard-tile-drop-target");
    const targetId = tile.dataset.panelId;
    const toSectionId = tile.closest(".dashboard-section-grid")?.dataset.sectionId;
    if (!dragPanelId || !targetId || !toSectionId || !dragFromSectionId) return;

    movePanel(dragPanelId, dragFromSectionId, toSectionId, targetId);
    scheduleLayoutSave();
    renderDashboardTiles(ctx);
  });
}

function wireSectionGridDrop(sectionGrid, sectionId, ctx) {
  sectionGrid.addEventListener("dragover", (e) => {
    if (!dragPanelId) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    sectionGrid.classList.add("dashboard-section-grid-drop-target");
  });

  sectionGrid.addEventListener("dragleave", (e) => {
    if (e.currentTarget.contains(e.relatedTarget)) return;
    sectionGrid.classList.remove("dashboard-section-grid-drop-target");
  });

  sectionGrid.addEventListener("drop", (e) => {
    if (!dragPanelId || e.target.closest(".dashboard-tile")) return;
    e.preventDefault();
    sectionGrid.classList.remove("dashboard-section-grid-drop-target");
    if (!dragFromSectionId) return;

    movePanel(dragPanelId, dragFromSectionId, sectionId);
    scheduleLayoutSave();
    renderDashboardTiles(ctx);
  });
}

function wireSectionDrag(head, sectionId, ctx) {
  head.draggable = true;

  head.addEventListener("dragstart", (e) => {
    if (e.target.closest("input, button")) {
      e.preventDefault();
      return;
    }
    dragSectionId = sectionId;
    dragPanelId = null;
    dragFromSectionId = null;
    head.closest(".dashboard-section")?.classList.add("dashboard-section-dragging");
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", `section:${sectionId}`);
  });

  head.addEventListener("dragend", () => {
    head.closest(".dashboard-section")?.classList.remove("dashboard-section-dragging");
    dragSectionId = null;
    clearDropHighlights();
  });

  head.addEventListener("dragover", (e) => {
    if (!dragSectionId || dragSectionId === sectionId) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    head.closest(".dashboard-section")?.classList.add("dashboard-section-drop-target");
  });

  head.addEventListener("dragleave", () => {
    head.closest(".dashboard-section")?.classList.remove("dashboard-section-drop-target");
  });

  head.addEventListener("drop", (e) => {
    if (!dragSectionId || dragSectionId === sectionId) return;
    e.preventDefault();
    e.stopPropagation();
    head.closest(".dashboard-section")?.classList.remove("dashboard-section-drop-target");

    const from = findSectionIndex(dragSectionId);
    const to = findSectionIndex(sectionId);
    if (from < 0 || to < 0 || from === to) return;

    const next = [...layoutSections];
    const [moved] = next.splice(from, 1);
    next.splice(to, 0, moved);
    layoutSections = next;
    scheduleLayoutSave();
    renderDashboardTiles(ctx);
  });
}

function clearDropHighlights() {
  document.querySelectorAll(".dashboard-tile-drop-target").forEach((el) => {
    el.classList.remove("dashboard-tile-drop-target");
  });
  document.querySelectorAll(".dashboard-section-drop-target").forEach((el) => {
    el.classList.remove("dashboard-section-drop-target");
  });
  document.querySelectorAll(".dashboard-section-grid-drop-target").forEach((el) => {
    el.classList.remove("dashboard-section-grid-drop-target");
  });
}

function removePanelFromLayout(panelId, ctx) {
  layoutSections = layoutSections.map((sec) => ({
    ...sec,
    panelIds: sec.panelIds.filter((id) => id !== panelId),
  }));
  scheduleLayoutSave();
  renderDashboardTiles(ctx);
  refreshAllDashboardPins();
}

function updateSectionTitle(sectionId, title) {
  const trimmed = (title || "").trim().slice(0, 48) || DEFAULT_SECTION_TITLE;
  layoutSections = layoutSections.map((sec) =>
    sec.id === sectionId ? { ...sec, title: trimmed } : sec
  );
  scheduleLayoutSave();
}

function addSection(ctx) {
  layoutSections = [...layoutSections, createDashboardSection("New group")];
  scheduleLayoutSave();
  renderDashboardTiles(ctx);
}

function removeSection(sectionId, ctx) {
  if (layoutSections.length <= 1) return;
  const idx = findSectionIndex(sectionId);
  if (idx < 0) return;

  const removed = layoutSections[idx];
  const target = layoutSections[Math.max(0, idx - 1)];
  const mergedIds = [...target.panelIds];
  for (const id of removed.panelIds) {
    if (!mergedIds.includes(id)) mergedIds.push(id);
  }

  layoutSections = layoutSections
    .filter((sec) => sec.id !== sectionId)
    .map((sec) => (sec.id === target.id ? { ...sec, panelIds: mergedIds } : sec));

  scheduleLayoutSave();
  renderDashboardTiles(ctx);
}

function scheduleLayoutSave() {
  if (!ownerId) return;
  clearTimeout(layoutSaveTimer);
  layoutSaveTimer = setTimeout(async () => {
    try {
      layoutSections = await saveOwnerDashboardLayout(supabase, ownerId, layoutSections);
    } catch (err) {
      console.error("Save dashboard layout:", err);
    }
  }, 400);
}

function wireDashboardToolbar() {
  const btn = document.getElementById("dashboardEditBtn");
  const hint = document.getElementById("dashboardEditHint");
  const addSectionBtn = document.getElementById("dashboardAddSectionBtn");
  if (!btn) return;

  if (addSectionBtn) {
    addSectionBtn.addEventListener("click", async () => {
      const { data: settings } = await supabase
        .from("global_settings_public")
        .select("draft_auction_enabled")
        .eq("id", 1)
        .maybeSingle();
      const draftEnabled = settings?.draft_auction_enabled === true;
      const specialAuction = await fetchActiveSpecialAuction(supabase);
      addSection({ draftEnabled, specialAuction });
    });
  }

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
