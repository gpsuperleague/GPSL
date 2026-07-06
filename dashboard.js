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
let layoutSaveTimer = null;
let dashboardCtx = null;

/** Survives dragend-before-drop on some browsers. */
let activeTileDrag = null;
let activeSectionDrag = null;
let focusSectionId = null;

const DRAG_SCROLL_EDGE = 80;
const DRAG_SCROLL_MAX_SPEED = 22;
let dragScrollSpeed = 0;
let dragScrollFrame = null;
let dragAutoScrollBound = false;

function bindDragAutoScroll() {
  if (dragAutoScrollBound) return;
  dragAutoScrollBound = true;
  document.addEventListener("dragover", handleDragAutoScroll);
}

function handleDragAutoScroll(e) {
  if (!activeTileDrag && !activeSectionDrag) {
    stopDragAutoScroll();
    return;
  }

  const y = e.clientY;
  const vh = window.innerHeight;
  let speed = 0;

  if (y < DRAG_SCROLL_EDGE) {
    speed = -DRAG_SCROLL_MAX_SPEED * (1 - Math.max(0, y) / DRAG_SCROLL_EDGE);
  } else if (y > vh - DRAG_SCROLL_EDGE) {
    speed = DRAG_SCROLL_MAX_SPEED * (1 - Math.max(0, vh - y) / DRAG_SCROLL_EDGE);
  }

  dragScrollSpeed = speed;
  if (speed && !dragScrollFrame) {
    dragScrollFrame = requestAnimationFrame(runDragAutoScroll);
  } else if (!speed) {
    stopDragAutoScroll();
  }
}

function runDragAutoScroll() {
  if (!dragScrollSpeed || (!activeTileDrag && !activeSectionDrag)) {
    stopDragAutoScroll();
    return;
  }
  window.scrollBy(0, dragScrollSpeed);
  dragScrollFrame = requestAnimationFrame(runDragAutoScroll);
}

function stopDragAutoScroll() {
  dragScrollSpeed = 0;
  if (dragScrollFrame) {
    cancelAnimationFrame(dragScrollFrame);
    dragScrollFrame = null;
  }
}

const DRAG_TILE = "gpsl-tile";
const DRAG_SECTION = "gpsl-section";

function encodeDrag(kind, data) {
  if (kind === DRAG_SECTION) {
    return `${DRAG_SECTION}:${data.sectionId}`;
  }
  return `${kind}:${JSON.stringify(data)}`;
}

function decodeDrag(raw) {
  if (!raw || typeof raw !== "string") return null;
  if (raw.startsWith(`${DRAG_TILE}:`)) {
    try {
      const payload = JSON.parse(raw.slice(DRAG_TILE.length + 1));
      if (payload?.panelId && payload?.fromSectionId) return { kind: DRAG_TILE, payload };
    } catch (_) {
      /* fall through */
    }
  }
  if (raw.startsWith(`${DRAG_SECTION}:`)) {
    const sectionId = raw.slice(DRAG_SECTION.length + 1);
    if (sectionId) return { kind: DRAG_SECTION, payload: { sectionId } };
  }
  return null;
}

function readDragFromEvent(e) {
  const raw = e.dataTransfer?.getData("text/plain");
  const decoded = decodeDrag(raw);
  if (decoded) return decoded;
  if (activeTileDrag) return { kind: DRAG_TILE, payload: activeTileDrag };
  if (activeSectionDrag) return { kind: DRAG_SECTION, payload: activeSectionDrag };
  return null;
}

function isTileDrag(e) {
  if (activeSectionDrag) return false;
  if (activeTileDrag) return true;
  const raw = e.dataTransfer?.getData?.("text/plain");
  if (raw?.startsWith(`${DRAG_TILE}:`)) return true;
  return false;
}

function isSectionDrag(e) {
  if (activeTileDrag) return false;
  if (activeSectionDrag) return true;
  const raw = e.dataTransfer?.getData?.("text/plain");
  return !!raw?.startsWith(`${DRAG_SECTION}:`);
}

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
  dashboardCtx = { draftEnabled, specialAuction };

  await initDashboardGrid(user.id, dashboardCtx);
  wireDashboardToolbar();
  bindDragAutoScroll();

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

async function refreshDashboardCtx() {
  const { data: settings } = await supabase
    .from("global_settings_public")
    .select("draft_auction_enabled")
    .eq("id", 1)
    .maybeSingle();
  const draftEnabled = settings?.draft_auction_enabled === true;
  const specialAuction = await fetchActiveSpecialAuction(supabase);
  dashboardCtx = { draftEnabled, specialAuction };
  return dashboardCtx;
}

async function initDashboardGrid(uid, ctx) {
  try {
    layoutSections = await loadOwnerDashboardLayout(supabase, uid);
    hideLayoutWarn();
  } catch (err) {
    console.error("Load dashboard layout:", err);
    showLayoutWarn(
      "Custom layout unavailable — run supabase/sql/owner_dashboard_layout.sql and owner_dashboard_sections.sql. Showing defaults."
    );
    const { cloneDefaultSections } = await import("./dashboard_layout.js");
    layoutSections = cloneDefaultSections();
  }

  renderDashboardTiles(ctx);
}

function showLayoutWarn(msg) {
  const hint = document.getElementById("dashboardLayoutWarn");
  if (hint) {
    hint.hidden = false;
    hint.textContent = msg;
  }
}

function hideLayoutWarn() {
  const hint = document.getElementById("dashboardLayoutWarn");
  if (hint) hint.hidden = true;
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
    grip.title = "Drag to move or drop on another tile to create a group";
    grip.setAttribute("aria-hidden", "true");
    grip.draggable = true;

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
    wireTileGripDrag(grip, tile, id, ctx);
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
      grip.draggable = true;
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
      if (focusSectionId === sec.id) {
        window.requestAnimationFrame(() => {
          titleInput.focus();
          titleInput.select();
          focusSectionId = null;
        });
      }
      head.appendChild(titleInput);

      const dropLabel = document.createElement("span");
      dropLabel.className = "dashboard-section-head-drop-label";
      dropLabel.textContent = "Drop tiles here";
      head.appendChild(dropLabel);

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
    } else {
      const title = document.createElement("h2");
      title.className = "dashboard-section-title";
      title.textContent = sec.title || DEFAULT_SECTION_TITLE;
      head.appendChild(title);
    }

    const sectionGrid = document.createElement("div");
    sectionGrid.className = "tile-grid dashboard-section-grid";
    sectionGrid.dataset.sectionId = sec.id;

    let sectionGrip = null;

    for (const id of sec.panelIds) {
      const tile = createTileElement(id, ctx);
      if (!tile) continue;
      sectionGrid.appendChild(tile);
    }

    if (editMode) {
      sectionGrip = head.querySelector(".dashboard-section-grip");
    }

    sectionEl.appendChild(head);
    sectionEl.appendChild(sectionGrid);

    if (editMode && sectionGrip) {
      wireSectionGripDrag(sectionGrip, sec.id, sectionEl, ctx);
      wireSectionHeadTileDrop(head, sec.id, ctx);
      wireSectionGridDrop(sectionGrid, sec.id, ctx);
    }

    grid.appendChild(sectionEl);
  }
}

function findSectionIndex(sectionId) {
  return layoutSections.findIndex((s) => s.id === sectionId);
}

function removePanelFromAllSections(panelId) {
  return layoutSections.map((sec) => ({
    ...sec,
    panelIds: sec.panelIds.filter((id) => id !== panelId),
  }));
}

function movePanelToSection(panelId, fromSectionId, toSectionId) {
  const fromIdx = findSectionIndex(fromSectionId);
  const toIdx = findSectionIndex(toSectionId);
  if (fromIdx < 0 || toIdx < 0) return;

  let next = layoutSections.map((sec) => ({
    ...sec,
    panelIds: [...sec.panelIds],
  }));

  const fromIds = next[fromIdx].panelIds;
  const pos = fromIds.indexOf(panelId);
  if (pos < 0) return;
  fromIds.splice(pos, 1);

  const toIds = next[toIdx].panelIds;
  if (!toIds.includes(panelId)) toIds.push(panelId);

  layoutSections = next;
}

/** Android-style: drop tile A onto tile B → new named group with both. */
function createFolderFromTiles(draggedPanelId, targetPanelId, targetSectionId) {
  if (!draggedPanelId || !targetPanelId || draggedPanelId === targetPanelId) return;

  const targetIdx = findSectionIndex(targetSectionId);
  if (targetIdx < 0) return;

  let next = removePanelFromAllSections(draggedPanelId);
  next = next.map((sec) => ({
    ...sec,
    panelIds: sec.panelIds.filter((id) => id !== targetPanelId),
  }));

  const folder = createDashboardSection("New group", [targetPanelId, draggedPanelId]);
  next.splice(targetIdx, 0, folder);
  focusSectionId = folder.id;

  if (editMode) {
    layoutSections = next;
  } else {
    layoutSections = next.filter((sec) => sec.panelIds.length > 0);
  }
}

function reorderSection(fromSectionId, toSectionId) {
  const from = findSectionIndex(fromSectionId);
  const to = findSectionIndex(toSectionId);
  if (from < 0 || to < 0 || from === to) return;

  const next = [...layoutSections];
  const [moved] = next.splice(from, 1);
  next.splice(to, 0, moved);
  layoutSections = next;
}

async function applyLayoutChange(ctx) {
  renderDashboardTiles(ctx);
  await commitLayoutSave();
}

function wireTileGripDrag(grip, tile, panelId, ctx) {
  grip.addEventListener("dragstart", (e) => {
    const sectionId = tile.closest(".dashboard-section-grid")?.dataset.sectionId;
    if (!sectionId) return;

    activeTileDrag = { panelId, fromSectionId: sectionId };
    activeSectionDrag = null;
    tile.classList.add("dashboard-tile-dragging");
    document.body.classList.add("dashboard-tile-dragging");
    bindDragAutoScroll();
    e.dataTransfer.setData(
      "text/plain",
      encodeDrag(DRAG_TILE, { panelId, fromSectionId: sectionId })
    );
    e.dataTransfer.effectAllowed = "move";
    e.stopPropagation();
  });

  grip.addEventListener("dragend", () => {
    tile.classList.remove("dashboard-tile-dragging");
    document.body.classList.remove("dashboard-tile-dragging");
    stopDragAutoScroll();
    window.setTimeout(() => {
      activeTileDrag = null;
    }, 0);
    clearDropHighlights();
  });

  tile.addEventListener("dragover", (e) => {
    if (!isTileDrag(e)) return;
    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_TILE) return;
    if (drag.payload.panelId === panelId) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = "move";
    tile.classList.add("dashboard-tile-folder-target");
  });

  tile.addEventListener("dragleave", (e) => {
    if (tile.contains(e.relatedTarget)) return;
    tile.classList.remove("dashboard-tile-folder-target");
  });

  tile.addEventListener("drop", async (e) => {
    e.preventDefault();
    e.stopPropagation();
    tile.classList.remove("dashboard-tile-folder-target");

    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_TILE) return;
    const { panelId: fromPanelId, fromSectionId } = drag.payload;
    const toSectionId = tile.closest(".dashboard-section-grid")?.dataset.sectionId;
    if (!toSectionId || fromPanelId === panelId) return;

    createFolderFromTiles(fromPanelId, panelId, toSectionId);
    await applyLayoutChange(ctx);
  });
}

function wireSectionHeadTileDrop(head, sectionId, ctx) {
  const onDragOver = (e) => {
    if (!isTileDrag(e)) return;
    if (e.target.closest(".dashboard-section-remove")) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = "move";
    head.classList.add("dashboard-section-head-tile-drop");
  };

  const onDragLeave = (e) => {
    if (head.contains(e.relatedTarget)) return;
    head.classList.remove("dashboard-section-head-tile-drop");
  };

  const onDrop = async (e) => {
    if (!isTileDrag(e)) return;
    if (e.target.closest(".dashboard-section-remove")) return;
    e.preventDefault();
    e.stopPropagation();
    head.classList.remove("dashboard-section-head-tile-drop");

    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_TILE) return;
    const { panelId, fromSectionId } = drag.payload;
    if (!panelId || !fromSectionId || fromSectionId === sectionId) return;

    movePanelToSection(panelId, fromSectionId, sectionId);
    await applyLayoutChange(ctx);
  };

  // Capture so drops work over the title field and grip (whole header bar).
  head.addEventListener("dragover", onDragOver, true);
  head.addEventListener("dragleave", onDragLeave, true);
  head.addEventListener("drop", onDrop, true);
}

function wireSectionGridDrop(sectionGrid, sectionId, ctx) {
  sectionGrid.addEventListener("dragover", (e) => {
    if (e.target.closest(".dashboard-tile")) return;
    if (!isTileDrag(e)) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = "move";
    sectionGrid.classList.add("dashboard-section-grid-drop-target");
  });

  sectionGrid.addEventListener("dragleave", (e) => {
    if (e.currentTarget.contains(e.relatedTarget)) return;
    sectionGrid.classList.remove("dashboard-section-grid-drop-target");
  });

  sectionGrid.addEventListener("drop", async (e) => {
    if (e.target.closest(".dashboard-tile")) return;
    e.preventDefault();
    e.stopPropagation();
    sectionGrid.classList.remove("dashboard-section-grid-drop-target");

    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_TILE) return;
    const { panelId, fromSectionId } = drag.payload;
    if (!panelId || !fromSectionId) return;

    movePanelToSection(panelId, fromSectionId, sectionId);
    await applyLayoutChange(ctx);
  });
}

function wireSectionGripDrag(grip, sectionId, sectionEl, ctx) {
  grip.addEventListener("dragstart", (e) => {
    activeSectionDrag = { sectionId };
    activeTileDrag = null;
    sectionEl.classList.add("dashboard-section-dragging");
    bindDragAutoScroll();
    e.dataTransfer.setData("text/plain", encodeDrag(DRAG_SECTION, { sectionId }));
    e.dataTransfer.effectAllowed = "move";
    e.stopPropagation();
  });

  grip.addEventListener("dragend", () => {
    sectionEl.classList.remove("dashboard-section-dragging");
    stopDragAutoScroll();
    window.setTimeout(() => {
      activeSectionDrag = null;
    }, 0);
    clearDropHighlights();
  });

  sectionEl.addEventListener("dragover", (e) => {
    if (!isSectionDrag(e) || isTileDrag(e)) return;
    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_SECTION) return;
    if (drag.payload.sectionId === sectionId) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    sectionEl.classList.add("dashboard-section-drop-target");
  });

  sectionEl.addEventListener("dragleave", (e) => {
    if (sectionEl.contains(e.relatedTarget)) return;
    sectionEl.classList.remove("dashboard-section-drop-target");
  });

  sectionEl.addEventListener("drop", async (e) => {
    if (!isSectionDrag(e) || isTileDrag(e)) return;
    const drag = readDragFromEvent(e);
    if (!drag || drag.kind !== DRAG_SECTION) return;
    const fromId = drag.payload.sectionId;
    if (!fromId || fromId === sectionId) return;

    e.preventDefault();
    e.stopPropagation();
    sectionEl.classList.remove("dashboard-section-drop-target");

    reorderSection(fromId, sectionId);
    await applyLayoutChange(ctx);
  });
}

function clearDropHighlights() {
  document.querySelectorAll(".dashboard-tile-folder-target").forEach((el) => {
    el.classList.remove("dashboard-tile-folder-target");
  });
  document.querySelectorAll(".dashboard-section-drop-target").forEach((el) => {
    el.classList.remove("dashboard-section-drop-target");
  });
  document.querySelectorAll(".dashboard-section-grid-drop-target").forEach((el) => {
    el.classList.remove("dashboard-section-grid-drop-target");
  });
  document.querySelectorAll(".dashboard-section-head-tile-drop").forEach((el) => {
    el.classList.remove("dashboard-section-head-tile-drop");
  });
}

function removePanelFromLayout(panelId, ctx) {
  layoutSections = removePanelFromAllSections(panelId);
  applyLayoutChange(ctx);
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
  applyLayoutChange(ctx);
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

  applyLayoutChange(ctx);
}

async function commitLayoutSave() {
  if (!ownerId) return;
  clearTimeout(layoutSaveTimer);
  try {
    layoutSections = await saveOwnerDashboardLayout(supabase, ownerId, layoutSections);
    hideLayoutWarn();
  } catch (err) {
    console.error("Save dashboard layout:", err);
    showLayoutWarn(
      err?.message?.includes("sections")
        ? "Could not save groups — run supabase/sql/patches/owner_dashboard_sections.sql in Supabase."
        : `Could not save dashboard layout: ${err?.message || err}`
    );
  }
}

function scheduleLayoutSave() {
  clearTimeout(layoutSaveTimer);
  layoutSaveTimer = setTimeout(commitLayoutSave, 400);
}

function wireDashboardToolbar() {
  const btn = document.getElementById("dashboardEditBtn");
  const hint = document.getElementById("dashboardEditHint");
  const addSectionBtn = document.getElementById("dashboardAddSectionBtn");
  if (!btn) return;

  if (addSectionBtn) {
    addSectionBtn.addEventListener("click", async () => {
      const ctx = await refreshDashboardCtx();
      addSection(ctx);
    });
  }

  btn.addEventListener("click", async () => {
    if (editMode) {
      await commitLayoutSave();
    }
    editMode = !editMode;
    btn.textContent = editMode ? "Done arranging" : "Arrange tiles";
    btn.setAttribute("aria-pressed", editMode ? "true" : "false");
    if (hint) hint.hidden = !editMode;

    const ctx = await refreshDashboardCtx();
    renderDashboardTiles(ctx);
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
