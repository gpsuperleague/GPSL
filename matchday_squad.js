/**
 * Matchday squad picker — 23-man squad with drag-and-drop on a virtual pitch.
 */

import {
  DEFAULT_FORMATION_ID,
  MATCHDAY_FORMATIONS,
  FORMATION_LIST,
  FORMATION_GROUP_ORDER,
  formationDisplayName,
  getFormation,
  formationLayout,
  resolvePitchLayout,
  buildPitchLayoutPayload,
  normalizePitchLayout,
  pitchLayoutHasSlots,
  validateFormationMirroring,
  PITCH_LABEL_PRESETS,
} from "./matchday_formations.js";
import {
  pesdbPlayerCardUrl,
  pesdbPlayerUrl,
  playerNameLinkHtml,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";

export { buildPitchLayoutPayload } from "./matchday_formations.js";

export const MAX_SQUAD = 23;
export const MAX_PITCH = 11;
export const MAX_BENCH = 12;
export const MAX_RESERVE = 0;

const SLOT_IDS = [
  "GK",
  "LB",
  "CB1",
  "CB2",
  "RB",
  "LMF",
  "CMF",
  "RMF",
  "LWF",
  "CF",
  "RWF",
];

export const DEFAULT_PITCH_SLOTS = getFormation(DEFAULT_FORMATION_ID).slots;
/** @deprecated use formation presets */
export const PITCH_SLOTS = DEFAULT_PITCH_SLOTS;

function clampPct(n) {
  return Math.min(96, Math.max(4, Number(n) || 0));
}

function emptyPitchMap() {
  return new Map(SLOT_IDS.map((id) => [id, null]));
}

const POSITION_TO_PITCH = {
  GK: ["GK"],
  LB: ["LB"],
  CB: ["CB1", "CB2"],
  RB: ["RB"],
  DMF: ["CMF"],
  LMF: ["LMF"],
  CMF: ["CMF"],
  RMF: ["RMF"],
  AMF: ["CMF"],
  LWF: ["LWF"],
  LW: ["LWF"],
  SS: ["CF"],
  RWF: ["RWF"],
  RW: ["RWF"],
  CF: ["CF"],
};

const FALLBACK_IMG = PESDB_FALLBACK_CARD_IMG;

export function playerCardUrl(konamiId) {
  return pesdbPlayerCardUrl(konamiId);
}

function playerKey(p) {
  return String(p?.Konami_ID ?? p?.player_id ?? "");
}

function clonePlayer(p) {
  return { ...p };
}

function squadCount(state) {
  let n = 0;
  for (const p of state.pitch.values()) if (p) n += 1;
  for (const p of state.bench) if (p) n += 1;
  return n;
}

function findPlayerLocation(state, id) {
  for (const [slotId, p] of state.pitch.entries()) {
    if (p && playerKey(p) === id) return { area: "pitch", slotId };
  }
  for (let i = 0; i < state.bench.length; i++) {
    if (state.bench[i] && playerKey(state.bench[i]) === id) {
      return { area: "bench", index: i };
    }
  }
  const pi = state.pool.findIndex((p) => playerKey(p) === id);
  if (pi >= 0) return { area: "pool", index: pi };
  return null;
}

function removePlayerFromState(state, id) {
  const loc = findPlayerLocation(state, id);
  if (!loc) return null;
  let player = null;
  if (loc.area === "pitch") {
    player = state.pitch.get(loc.slotId);
    state.pitch.set(loc.slotId, null);
  } else if (loc.area === "bench") {
    player = state.bench[loc.index];
    state.bench[loc.index] = null;
  } else if (loc.area === "pool") {
    player = state.pool.splice(loc.index, 1)[0];
  }
  return player;
}

function isInSquad(state, id) {
  const loc = findPlayerLocation(state, id);
  return loc != null && loc.area !== "pool";
}

function placePlayer(state, target, player) {
  if (!player) return null;
  const id = playerKey(player);

  if (
    !isInSquad(state, id) &&
    target.area !== "pool" &&
    squadCount(state) >= MAX_SQUAD
  ) {
    return { error: `Matchday squad is full (${MAX_SQUAD} players).` };
  }

  removePlayerFromState(state, id);

  let displaced = null;
  if (target.area === "pitch") {
    displaced = state.pitch.get(target.slotId) || null;
    state.pitch.set(target.slotId, clonePlayer(player));
  } else if (target.area === "bench") {
    displaced = state.bench[target.index] || null;
    state.bench[target.index] = clonePlayer(player);
  } else if (target.area === "pool") {
    state.pool.push(clonePlayer(player));
  }

  if (displaced) {
    state.pool.push(displaced);
  }
  return null;
}

export function buildSlotsPayload(state) {
  const out = [];
  for (const slotId of SLOT_IDS) {
    const p = state.pitch.get(slotId);
    if (p) {
      out.push({
        player_id: playerKey(p),
        slot_kind: "pitch",
        pitch_slot: slotId,
        sort_order: SLOT_IDS.indexOf(slotId),
      });
    }
  }
  state.bench.forEach((p, i) => {
    if (p) {
      out.push({
        player_id: playerKey(p),
        slot_kind: "bench",
        sort_order: i,
      });
    }
  });
  return out;
}

export function getDefaultStarters(savedRows) {
  if (!savedRows?.length) return [];
  return savedRows
    .filter((r) => r.slot_kind === "pitch")
    .map((r) => String(r.player_id));
}

export function getDefaultBenchIds(savedRows) {
  if (!savedRows?.length) return new Set();
  return new Set(
    savedRows
      .filter((r) => r.slot_kind === "bench")
      .map((r) => String(r.player_id))
  );
}

export function getSquadPlayerIds(savedRows) {
  if (!savedRows?.length) return null;
  return new Set(savedRows.map((r) => String(r.player_id)));
}

function buildStateFromSaved(allPlayers, savedRows) {
  const byId = new Map(allPlayers.map((p) => [playerKey(p), p]));
  const state = {
    pitch: emptyPitchMap(),
    bench: Array(MAX_BENCH).fill(null),
    pool: [],
  };

  const used = new Set();
  for (const row of savedRows || []) {
    const p = byId.get(String(row.player_id));
    if (!p) continue;
    const pid = String(row.player_id);
    if (row.slot_kind === "pitch" && row.pitch_slot) {
      state.pitch.set(row.pitch_slot, clonePlayer(p));
      used.add(pid);
    } else if (row.slot_kind === "bench") {
      const idx = Math.min(Math.max(Number(row.sort_order) || 0, 0), MAX_BENCH - 1);
      if (!state.bench[idx]) {
        state.bench[idx] = clonePlayer(p);
        used.add(pid);
      }
    } else if (row.slot_kind === "reserve") {
      const emptyBench = state.bench.findIndex((x) => !x);
      if (emptyBench >= 0) {
        state.bench[emptyBench] = clonePlayer(p);
        used.add(pid);
      }
    }
  }

  for (const p of allPlayers) {
    if (!used.has(playerKey(p))) state.pool.push(clonePlayer(p));
  }

  return state;
}

function autoFillBestXi(allPlayers) {
  const state = {
    pitch: emptyPitchMap(),
    bench: Array(MAX_BENCH).fill(null),
    pool: [],
  };
  const sorted = [...allPlayers].sort(
    (a, b) => Number(b.Rating || 0) - Number(a.Rating || 0)
  );
  const used = new Set();
  const slotFilled = new Set();

  for (const p of sorted) {
    const pos = String(p.Position || "").toUpperCase();
    const targets = POSITION_TO_PITCH[pos] || [];
    for (const slotId of targets) {
      if (slotFilled.has(slotId)) continue;
      state.pitch.set(slotId, clonePlayer(p));
      slotFilled.add(slotId);
      used.add(playerKey(p));
      break;
    }
    if (slotFilled.size >= MAX_PITCH) break;
  }

  for (const slotId of SLOT_IDS) {
    if (state.pitch.get(slotId)) continue;
    const next = sorted.find((p) => !used.has(playerKey(p)));
    if (!next) break;
    state.pitch.set(slotId, clonePlayer(next));
    used.add(playerKey(next));
  }

  const remaining = sorted.filter((p) => !used.has(playerKey(p)));
  let benchIdx = 0;
  for (const p of remaining) {
    if (benchIdx < MAX_BENCH) {
      state.bench[benchIdx++] = clonePlayer(p);
      used.add(playerKey(p));
    }
  }
  for (const p of allPlayers) {
    if (!used.has(playerKey(p))) state.pool.push(clonePlayer(p));
  }
  return state;
}

function renderPlayerCard(player, { compact = false, pitch = false } = {}) {
  const id = playerKey(player);
  const name = player.Name || player.player_name || id;
  const pos = player.Position || player.player_position || "";
  const card = document.createElement("div");
  card.className =
    "squad-player-card" + (pitch ? " squad-player-card--pitch" : "");
  card.draggable = true;
  card.dataset.playerId = id;
  card.innerHTML = `
    <a href="${pesdbPlayerUrl(id)}" target="_blank" rel="noopener" class="squad-player-card-thumb-link">
      <img src="${playerCardUrl(id)}" alt="" draggable="false"
        onerror="this.src='${FALLBACK_IMG}'">
    </a>
    <div class="spc-meta">
      <div class="spc-name">${playerNameLinkHtml(id, name)}</div>
      ${compact ? "" : `<div class="spc-pos">${pos}</div>`}
    </div>`;
  card.addEventListener("dragstart", (e) => {
    e.dataTransfer.setData("text/player-id", id);
    e.dataTransfer.effectAllowed = "move";
    card.classList.add("dragging");
  });
  card.addEventListener("dragend", () => card.classList.remove("dragging"));
  return card;
}

function resolveDropTarget(el) {
  const pitchDrop = el.closest(".pitch-slot-drop[data-slot-id]");
  if (pitchDrop) {
    return { area: "pitch", slotId: pitchDrop.dataset.slotId };
  }
  const benchDrop = el.closest(".bench-slot-drop[data-bench-idx]");
  if (benchDrop) {
    return { area: "bench", index: Number(benchDrop.dataset.benchIdx) };
  }
  if (el.closest("#squadPoolList")) {
    return { area: "pool" };
  }
  return null;
}

function wireDragDrop(root, state, rerender) {
  root.addEventListener("dragover", (e) => {
    const target = resolveDropTarget(e.target);
    if (!target) return;
    e.preventDefault();
    const dropEl =
      e.target.closest(".pitch-slot-drop") ||
      e.target.closest(".bench-slot-drop") ||
      e.target.closest("#squadPoolList");
    dropEl?.classList.add("drag-over");
  });

  root.addEventListener("dragleave", (e) => {
    const dropEl =
      e.target.closest(".pitch-slot-drop") ||
      e.target.closest(".bench-slot-drop") ||
      e.target.closest("#squadPoolList");
    dropEl?.classList.remove("drag-over");
  });

  root.addEventListener("drop", (e) => {
    const target = resolveDropTarget(e.target);
    if (!target) return;
    e.preventDefault();
    root.querySelectorAll(".drag-over").forEach((el) => el.classList.remove("drag-over"));

    const id = e.dataTransfer.getData("text/player-id");
    if (!id) return;
    const loc = findPlayerLocation(state, id);
    if (!loc) return;
    let player = null;
    if (loc.area === "pitch") player = state.pitch.get(loc.slotId);
    else if (loc.area === "bench") player = state.bench[loc.index];
    else if (loc.area === "pool") player = state.pool[loc.index];
    if (!player) return;

    const err = placePlayer(state, target, player);
    if (err?.error) {
      alert(err.error);
      return;
    }
    rerender();
  });
}

/**
 * @param {object} opts
 * @param {HTMLElement} opts.root
 * @param {Array} opts.allPlayers
 * @param {Array} opts.savedRows
 * @param {function} opts.onChange
 * @param {function} opts.onSave
 */
function wirePositionDragging(pitchEl, slotPositions, getEditMode) {
  let activeSlotId = null;
  let pointerId = null;
  let activeWrap = null;

  const onPointerMove = (e) => {
    if (!activeSlotId || e.pointerId !== pointerId || !activeWrap) return;
    const rect = pitchEl.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * 100;
    const y = ((e.clientY - rect.top) / rect.height) * 100;
    slotPositions[activeSlotId] = {
      x: clampPct(x),
      y: clampPct(y),
    };
    activeWrap.style.left = `${slotPositions[activeSlotId].x}%`;
    activeWrap.style.top = `${slotPositions[activeSlotId].y}%`;
  };

  const endDrag = (e) => {
    if (!activeSlotId) return;
    if (e.pointerId != null && pointerId != null && e.pointerId !== pointerId) return;

    activeWrap?.classList.remove("dragging-position");
    if (activeWrap?.hasPointerCapture?.(pointerId)) {
      try {
        activeWrap.releasePointerCapture(pointerId);
      } catch {
        /* ignore */
      }
    }

    activeSlotId = null;
    pointerId = null;
    activeWrap = null;
    document.removeEventListener("pointermove", onPointerMove);
    document.removeEventListener("pointerup", endDrag);
    document.removeEventListener("pointercancel", endDrag);
  };

  pitchEl.addEventListener("pointerdown", (e) => {
    if (!getEditMode()) return;
    if (e.target.closest(".squad-player-card")) return;
    if (e.target.closest(".pitch-slot-label")) return;

    const wrap = e.target.closest(".pitch-slot[data-slot-id]");
    if (!wrap) return;

    e.preventDefault();
    e.stopPropagation();

    activeSlotId = wrap.dataset.slotId;
    pointerId = e.pointerId;
    activeWrap = wrap;
    wrap.classList.add("dragging-position");

    try {
      wrap.setPointerCapture(pointerId);
    } catch {
      /* touch / older browsers */
    }

    document.addEventListener("pointermove", onPointerMove);
    document.addEventListener("pointerup", endDrag);
    document.addEventListener("pointercancel", endDrag);
  });
}

function wirePitchLabelPicker(pitchEl, slotLabels) {
  const pitchStage = pitchEl.closest(".pitch-stage") || pitchEl.parentElement;
  let menu = pitchStage?.querySelector("#pitchLabelMenu");
  if (!menu && pitchStage) {
    menu = document.createElement("div");
    menu.id = "pitchLabelMenu";
    menu.className = "pitch-label-menu";
    menu.hidden = true;
    pitchStage.appendChild(menu);
  }
  if (!menu) return;

  function updateSlotLabelDom(slotId) {
    const wrap = pitchEl.querySelector(`.pitch-slot[data-slot-id="${slotId}"]`);
    const labelEl = wrap?.querySelector(".pitch-slot-label");
    if (labelEl) labelEl.textContent = slotLabels[slotId] || slotId;
  }

  function closeMenu() {
    menu.hidden = true;
  }

  function openMenu(slotId, anchorEl) {
    menu.innerHTML = "";

    const title = document.createElement("div");
    title.className = "pitch-label-menu-title";
    title.textContent = `Change role — ${slotLabels[slotId] || slotId}`;
    menu.appendChild(title);

    const grid = document.createElement("div");
    grid.className = "pitch-label-menu-grid";
    for (const label of PITCH_LABEL_PRESETS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "pitch-label-option" + (slotLabels[slotId] === label ? " selected" : "");
      btn.textContent = label;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        slotLabels[slotId] = label;
        updateSlotLabelDom(slotId);
        closeMenu();
      });
      grid.appendChild(btn);
    }
    menu.appendChild(grid);

    const customBtn = document.createElement("button");
    customBtn.type = "button";
    customBtn.className = "pitch-label-custom";
    customBtn.textContent = "Custom label…";
    customBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const v = prompt("Position label", slotLabels[slotId] || "");
      if (v != null && v.trim()) {
        slotLabels[slotId] = v.trim();
        updateSlotLabelDom(slotId);
      }
      closeMenu();
    });
    menu.appendChild(customBtn);

    menu.hidden = false;
    positionMenuNearAnchor(anchorEl);
  }

  function positionMenuNearAnchor(anchorEl) {
    const anchor = anchorEl.getBoundingClientRect();
    const menuW = menu.offsetWidth || 240;
    const menuH = menu.offsetHeight || 280;
    const gap = 6;
    const pad = 8;

    let left = anchor.left + anchor.width / 2 - menuW / 2;
    let top = anchor.bottom + gap;

    if (top + menuH > window.innerHeight - pad) {
      top = anchor.top - menuH - gap;
    }
    if (top < pad) top = pad;

    left = Math.max(pad, Math.min(left, window.innerWidth - menuW - pad));

    menu.style.left = `${left}px`;
    menu.style.top = `${top}px`;
  }

  pitchEl.addEventListener("contextmenu", (e) => {
    const wrap = e.target.closest(".pitch-slot[data-slot-id]");
    if (!wrap) return;
    e.preventDefault();
    openMenu(wrap.dataset.slotId, wrap);
  });

  pitchEl.addEventListener("click", (e) => {
    const labelEl = e.target.closest(".pitch-slot-label");
    if (labelEl) {
      e.stopPropagation();
      const wrap = labelEl.closest(".pitch-slot[data-slot-id]");
      if (!wrap) return;
      openMenu(wrap.dataset.slotId, labelEl);
      return;
    }

    const card = e.target.closest(".pitch-slot .squad-player-card");
    if (card) {
      e.stopPropagation();
      const wrap = card.closest(".pitch-slot[data-slot-id]");
      if (!wrap) return;
      openMenu(wrap.dataset.slotId, card);
    }
  });

  document.addEventListener("click", (e) => {
    if (!menu.hidden && !menu.contains(e.target)) closeMenu();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeMenu();
  });
}

function isTemplateFormationId(id) {
  return FORMATION_LIST.some((f) => f.id === id);
}

export function initMatchdaySquadPanel({
  root,
  allPlayers,
  savedRows = [],
  savedPitchLayout = null,
  savedFormations = [],
  onChange,
  onSave,
  onSaveFormation,
  onLoadFormation,
  onDeleteFormation,
}) {
  let editPositionsMode = false;
  const resolved = resolvePitchLayout(savedPitchLayout);
  let currentFormationId = resolved.formationId;
  let slotPositions = { ...resolved.positions };
  let slotLabels = { ...resolved.labels };
  let state =
    savedRows?.length > 0
      ? buildStateFromSaved(allPlayers, savedRows)
      : {
          pitch: emptyPitchMap(),
          bench: Array(MAX_BENCH).fill(null),
          pool: allPlayers.map(clonePlayer),
        };

  root.innerHTML = `
    <p class="squad-hint">
      Drag player cards onto the pitch (11 starters) and bench (12 subs) for your
      <b>default 23-man matchday squad</b>. <b>Click</b> a position label or player on the pitch (or <b>right-click</b> the slot) to change its role (DMF, CMF, etc.).
      Use <b>Move positions</b> to drag markers. Save up to <b>5 custom formations</b> (Custom 1–5).
      Formation presets only apply when you click <b>Apply Default Formation</b>. Custom layouts must follow <b>GPSL mirroring</b>
      (LB↔RB, LMF↔RMF, LWF↔RWF; max 2 CF/SS combined). Starters auto-tick <b>Started</b> on match stats.
    </p>
    <div class="squad-formations-bar">
      <div class="formation-section-row">
        <span class="formation-section-label">Default formations</span>
        <select id="squadFormationSelect" class="formation-select" title="Starting layout only — use Apply to reset markers"></select>
        <button type="button" class="button secondary" id="squadApplyTemplateBtn">Apply Default Formation</button>
      </div>
      <div class="formation-section-row">
        <span class="formation-section-label">My Formations</span>
        <select id="squadSavedFormationSelect" class="formation-select" title="Pick Custom 1–5 to load or save"></select>
        <div class="formation-action-group">
          <button type="button" class="button secondary" id="squadLoadFormationBtn">Load Custom Formation</button>
          <button type="button" class="button secondary" id="squadSaveFormationBtn">Save Custom Formation</button>
          <button type="button" class="button danger" id="squadDeleteFormationBtn">Delete Custom Formation</button>
        </div>
        <input type="text" id="squadFormationName" class="formation-name-input" maxlength="40" placeholder="Formation name" />
      </div>
    </div>
    <div class="squad-toolbar">
      <button type="button" class="button secondary" id="squadAutoFillBtn">Auto-fill XI</button>
      <button type="button" class="button secondary" id="squadMovePosBtn">Move positions</button>
      <button type="button" class="button secondary" id="squadResetPosBtn" hidden>Reset layout</button>
      <button type="button" class="button secondary" id="squadClearBtn">Clear squad</button>
      <button type="button" class="button" id="squadSaveBtn">Save default squad</button>
      <span class="squad-status" id="squadStatusText"></span>
    </div>
    <p class="squad-hint" id="squadEditHint" style="display:none;color:#9c9;">
      Drag any <b>position marker</b> (label or empty slot) on the pitch to arrange your layout.
    </p>
    <div class="squad-layout">
      <div class="squad-pool">
        <h4>Squad pool</h4>
        <div class="squad-pool-count" id="squadPoolCount"></div>
        <div id="squadPoolList"></div>
      </div>
      <div class="pitch-stage">
        <div class="football-pitch" id="footballPitch">
          <div class="pitch-center-circle" aria-hidden="true"></div>
        </div>
        <div class="squad-bench">
          <h4>Bench (12 subs)</h4>
          <div class="bench-slots bench-slots-12" id="benchSlots"></div>
        </div>
      </div>
    </div>`;

  const pitchEl = root.querySelector("#footballPitch");
  const poolList = root.querySelector("#squadPoolList");
  const benchSlots = root.querySelector("#benchSlots");
  const statusText = root.querySelector("#squadStatusText");
  const editHint = root.querySelector("#squadEditHint");
  const movePosBtn = root.querySelector("#squadMovePosBtn");
  const resetPosBtn = root.querySelector("#squadResetPosBtn");
  const formationSelect = root.querySelector("#squadFormationSelect");
  const savedFormationSelect = root.querySelector("#squadSavedFormationSelect");
  const formationNameInput = root.querySelector("#squadFormationName");

  formationSelect.innerHTML = "";
  for (const groupLabel of FORMATION_GROUP_ORDER) {
    const groupFormations = Object.values(MATCHDAY_FORMATIONS).filter(
      (f) => f.group === groupLabel
    );
    if (!groupFormations.length) continue;
    const og = document.createElement("optgroup");
    og.label = groupLabel;
    for (const f of groupFormations) {
      const opt = document.createElement("option");
      opt.value = f.id;
      opt.textContent = formationDisplayName(f);
      og.appendChild(opt);
    }
    formationSelect.appendChild(og);
  }
  formationSelect.value = isTemplateFormationId(currentFormationId)
    ? currentFormationId
    : DEFAULT_FORMATION_ID;

  let savedFormationRows = [...savedFormations];

  function savedFormationBySlot(slotNo) {
    return savedFormationRows.find((r) => Number(r.slot_no) === slotNo) || null;
  }

  function renderSavedFormationOptions() {
    savedFormationSelect.innerHTML = "";
    for (let slot = 1; slot <= 5; slot += 1) {
      const row = savedFormationBySlot(slot);
      const opt = document.createElement("option");
      opt.value = String(slot);
      opt.textContent = row?.name
        ? `Custom ${slot} — ${row.name}`
        : `Custom ${slot} — (empty)`;
      savedFormationSelect.appendChild(opt);
    }
    syncFormationNameFromSlot();
  }

  function syncFormationNameFromSlot() {
    const slot = Number(savedFormationSelect.value) || 1;
    const row = savedFormationBySlot(slot);
    formationNameInput.value = row?.name || "";
  }

  renderSavedFormationOptions();

  function applySlotPositionsToDom() {
    for (const slotId of SLOT_IDS) {
      const wrap = pitchEl.querySelector(`.pitch-slot[data-slot-id="${slotId}"]`);
      if (!wrap) continue;
      const pos = slotPositions[slotId];
      if (!pos) continue;
      wrap.style.left = `${pos.x}%`;
      wrap.style.top = `${pos.y}%`;
      const labelEl = wrap.querySelector(".pitch-slot-label");
      if (labelEl) labelEl.textContent = slotLabels[slotId] || slotId;
    }
  }

  function buildPitchSlotElements() {
    pitchEl.querySelectorAll(".pitch-slot").forEach((el) => el.remove());
    for (const slotId of SLOT_IDS) {
      const pos = slotPositions[slotId] || { x: 50, y: 50 };
      const wrap = document.createElement("div");
      wrap.className = "pitch-slot";
      wrap.dataset.slotId = slotId;
      wrap.style.left = `${pos.x}%`;
      wrap.style.top = `${pos.y}%`;
      const label = slotLabels[slotId] || slotId;
      wrap.innerHTML = `
        <button type="button" class="pitch-slot-label" title="Click to change role (or right-click slot)">${label}</button>
        <div class="pitch-slot-drop" data-slot-id="${slotId}">
          <span class="pitch-slot-placeholder" aria-hidden="true"></span>
        </div>`;
      pitchEl.appendChild(wrap);
    }
  }

  function guardMirroring() {
    const result = validateFormationMirroring(slotLabels);
    if (!result.ok) {
      alert(
        `Cannot save — this formation breaks GPSL mirroring rules:\n\n${result.errors.join("\n")}`
      );
      statusText.textContent = result.message;
      return false;
    }
    return true;
  }

  function replaceSlotMap(target, next) {
    for (const key of Object.keys(target)) delete target[key];
    Object.assign(target, next);
  }

  function applyLayoutFromResolved(resolved) {
    currentFormationId = resolved.formationId;
    replaceSlotMap(slotPositions, resolved.positions);
    replaceSlotMap(slotLabels, resolved.labels);
    formationSelect.value = isTemplateFormationId(currentFormationId)
      ? currentFormationId
      : DEFAULT_FORMATION_ID;
    buildPitchSlotElements();
    rerenderPlayerCards();
  }

  function applyFormation(formationId) {
    const base = formationLayout(formationId);
    currentFormationId = base.formationId;
    replaceSlotMap(slotPositions, base.positions);
    replaceSlotMap(slotLabels, base.labels);
    formationSelect.value = currentFormationId;
    buildPitchSlotElements();
    rerenderPlayerCards();
  }

  buildPitchSlotElements();

  for (let i = 0; i < MAX_BENCH; i++) {
    const wrap = document.createElement("div");
    wrap.className = "bench-slot";
    wrap.innerHTML = `
      <div class="bench-slot-label">Sub ${i + 1}</div>
      <div class="bench-slot-drop" data-bench-idx="${i}"></div>`;
    benchSlots.appendChild(wrap);
  }

  function setEditPositionsMode(on) {
    editPositionsMode = on;
    pitchEl.classList.toggle("positions-edit-mode", on);
    movePosBtn.classList.toggle("active", on);
    movePosBtn.textContent = on ? "Done moving" : "Move positions";
    resetPosBtn.hidden = !on;
    editHint.style.display = on ? "block" : "none";
    rerenderPlayerCards();
  }

  function updateStatus() {
    const pitchN = [...state.pitch.values()].filter(Boolean).length;
    const benchN = state.bench.filter(Boolean).length;
    const total = squadCount(state);
    statusText.textContent = `Squad: ${total}/${MAX_SQUAD} · Pitch ${pitchN}/${MAX_PITCH} · Bench ${benchN}/${MAX_BENCH}`;
    root.querySelector("#squadPoolCount").textContent = `${state.pool.length} players available`;
    onChange?.(buildSlotsPayload(state), state);
  }

  function rerenderPlayerCards() {
    poolList.innerHTML = "";
    for (const p of state.pool) {
      poolList.appendChild(renderPlayerCard(p));
    }

    for (const slotId of SLOT_IDS) {
      const drop = pitchEl.querySelector(`.pitch-slot-drop[data-slot-id="${slotId}"]`);
      if (!drop) continue;
      const p = state.pitch.get(slotId);
      drop.innerHTML = "";
      if (p) {
        const card = renderPlayerCard(p, { compact: true, pitch: true });
        card.draggable = !editPositionsMode;
        drop.appendChild(card);
      } else {
        drop.innerHTML = '<span class="pitch-slot-placeholder"></span>';
      }
    }

    benchSlots.querySelectorAll(".bench-slot-drop").forEach((drop) => {
      const idx = Number(drop.dataset.benchIdx);
      drop.innerHTML = "";
      const p = state.bench[idx];
      if (p) drop.appendChild(renderPlayerCard(p, { compact: true }));
    });

    updateStatus();
  }

  function rerender() {
    rerenderPlayerCards();
  }

  wireDragDrop(root, state, rerender);
  wirePositionDragging(pitchEl, slotPositions, () => editPositionsMode);
  wirePitchLabelPicker(pitchEl, slotLabels);

  movePosBtn.addEventListener("click", () => setEditPositionsMode(!editPositionsMode));

  root.querySelector("#squadApplyTemplateBtn").addEventListener("click", () => {
    const templateId = formationSelect.value;
    const name = formationDisplayName(getFormation(templateId));
    if (
      !confirm(
        `Apply default formation “${name}”? This resets all pitch marker positions and role labels (players stay put).`
      )
    ) {
      return;
    }
    applyFormation(templateId);
  });

  savedFormationSelect.addEventListener("change", syncFormationNameFromSlot);

  root.querySelector("#squadLoadFormationBtn").addEventListener("click", async () => {
    const slot = Number(savedFormationSelect.value) || 1;
    statusText.textContent = "Loading formation…";
    try {
      let row = savedFormationBySlot(slot);
      if (onLoadFormation) {
        row = await onLoadFormation(slot);
      }
      if (!row || !pitchLayoutHasSlots(row.pitch_layout)) {
        alert(`Slot ${slot} is empty. Save a custom formation first.`);
        statusText.textContent = "";
        return;
      }
      const layout = normalizePitchLayout(row.pitch_layout);
      applyLayoutFromResolved(resolvePitchLayout(layout));
      formationNameInput.value = row.name || "";
      statusText.textContent = `Loaded “${row.name}”.`;

      const idx = savedFormationRows.findIndex((r) => Number(r.slot_no) === slot);
      const merged = { slot_no: slot, name: row.name, pitch_layout: layout };
      if (idx >= 0) savedFormationRows[idx] = { ...savedFormationRows[idx], ...merged };
      else savedFormationRows.push(merged);
      renderSavedFormationOptions();
      savedFormationSelect.value = String(slot);
    } catch (err) {
      statusText.textContent = err?.message || "Failed to load formation";
      alert(err?.message || "Failed to load custom formation.");
    }
  });

  root.querySelector("#squadSaveFormationBtn").addEventListener("click", async () => {
    if (!onSaveFormation) return;
    const slot = Number(savedFormationSelect.value) || 1;
    const name = formationNameInput.value.trim();
    if (!name) {
      alert("Enter a name for this formation.");
      formationNameInput.focus();
      return;
    }
    if (!guardMirroring()) return;

    const layout = buildPitchLayoutPayload(slotPositions, slotLabels, "custom");
    statusText.textContent = "Saving formation…";
    try {
      await onSaveFormation(slot, name, layout);
      const idx = savedFormationRows.findIndex((r) => Number(r.slot_no) === slot);
      const row = { slot_no: slot, name, pitch_layout: layout };
      if (idx >= 0) savedFormationRows[idx] = row;
      else savedFormationRows.push(row);
      renderSavedFormationOptions();
      savedFormationSelect.value = String(slot);
      statusText.textContent = `Saved “${name}” to slot ${slot}.`;
      syncFormationNameFromSlot();
    } catch (err) {
      statusText.textContent = err?.message || "Formation save failed";
    }
  });

  root.querySelector("#squadDeleteFormationBtn").addEventListener("click", async () => {
    if (!onDeleteFormation) return;
    const slot = Number(savedFormationSelect.value) || 1;
    const row = savedFormationBySlot(slot);
    if (!row) {
      alert(`Custom ${slot} is already empty.`);
      return;
    }
    const label = row.name ? `Custom ${slot} — “${row.name}”` : `Custom ${slot}`;
    if (!confirm(`Delete ${label}? This cannot be undone.`)) return;

    statusText.textContent = "Deleting formation…";
    try {
      await onDeleteFormation(slot);
      savedFormationRows = savedFormationRows.filter(
        (r) => Number(r.slot_no) !== slot
      );
      renderSavedFormationOptions();
      savedFormationSelect.value = String(slot);
      formationNameInput.value = "";
      statusText.textContent = `Deleted ${label}.`;
    } catch (err) {
      statusText.textContent = err?.message || "Formation delete failed";
      alert(err?.message || "Failed to delete custom formation.");
    }
  });

  resetPosBtn.addEventListener("click", () => {
    const templateId = isTemplateFormationId(currentFormationId)
      ? currentFormationId
      : formationSelect.value;
    applyFormation(templateId);
  });

  root.querySelector("#squadAutoFillBtn").addEventListener("click", () => {
    state = autoFillBestXi(allPlayers);
    rerender();
  });

  root.querySelector("#squadClearBtn").addEventListener("click", () => {
    if (!confirm("Clear your saved matchday squad layout?")) return;
    state = {
      pitch: emptyPitchMap(),
      bench: Array(MAX_BENCH).fill(null),
      pool: allPlayers.map(clonePlayer),
    };
    rerender();
  });

  root.querySelector("#squadSaveBtn").addEventListener("click", async () => {
    const payload = buildSlotsPayload(state);
    const pitchN = payload.filter((s) => s.slot_kind === "pitch").length;
    if (pitchN < MAX_PITCH) {
      if (
        !confirm(
          `Only ${pitchN}/${MAX_PITCH} players on the pitch. Save anyway?`
        )
      ) {
        return;
      }
    }
    if (!guardMirroring()) return;

    statusText.textContent = "Saving…";
    try {
      await onSave(
        payload,
        buildPitchLayoutPayload(slotPositions, slotLabels, currentFormationId)
      );
      statusText.textContent = `Saved ${payload.length} players.`;
      setEditPositionsMode(false);
    } catch (err) {
      statusText.textContent = err?.message || "Save failed";
    }
  });

  rerender();
  return {
    getState: () => state,
    setSavedRows: (rows, layout) => {
      state = buildStateFromSaved(allPlayers, rows);
      if (layout != null) {
        applyLayoutFromResolved(resolvePitchLayout(layout));
      } else {
        rerender();
      }
    },
    refreshSavedFormations: (rows) => {
      savedFormationRows = [...(rows || [])];
      renderSavedFormationOptions();
    },
  };
}
