/**
 * Matchday squad picker — 23-man squad with drag-and-drop on a virtual pitch.
 */

export const MAX_SQUAD = 23;
export const MAX_PITCH = 11;
export const MAX_BENCH = 12;
export const MAX_RESERVE = 0;

export const DEFAULT_PITCH_SLOTS = [
  { id: "GK", label: "GK", x: 50, y: 86 },
  { id: "LB", label: "LB", x: 12, y: 68 },
  { id: "CB1", label: "CB", x: 36, y: 72 },
  { id: "CB2", label: "CB", x: 64, y: 72 },
  { id: "RB", label: "RB", x: 88, y: 68 },
  { id: "LMF", label: "LM", x: 16, y: 48 },
  { id: "CMF", label: "CM", x: 50, y: 52 },
  { id: "RMF", label: "RM", x: 84, y: 48 },
  { id: "LWF", label: "LW", x: 22, y: 22 },
  { id: "CF", label: "CF", x: 50, y: 12 },
  { id: "RWF", label: "RW", x: 78, y: 22 },
];

/** @deprecated use DEFAULT_PITCH_SLOTS */
export const PITCH_SLOTS = DEFAULT_PITCH_SLOTS;

function clampPct(n) {
  return Math.min(96, Math.max(4, Number(n) || 0));
}

export function normalizePitchLayout(saved) {
  const out = {};
  for (const slot of DEFAULT_PITCH_SLOTS) {
    const s = saved?.[slot.id];
    out[slot.id] = {
      x: clampPct(s?.x ?? slot.x),
      y: clampPct(s?.y ?? slot.y),
    };
  }
  return out;
}

export function buildPitchLayoutPayload(slotPositions) {
  const out = {};
  for (const slot of DEFAULT_PITCH_SLOTS) {
    const pos = slotPositions[slot.id];
    if (pos) {
      out[slot.id] = {
        x: Math.round(pos.x * 10) / 10,
        y: Math.round(pos.y * 10) / 10,
      };
    }
  }
  return out;
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

const FALLBACK_IMG = "https://i.imgur.com/3s8XQ7Y.png";

export function playerCardUrl(konamiId) {
  return `https://pesdb.net/assets/img/card/b${konamiId}.png`;
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
  for (const slot of DEFAULT_PITCH_SLOTS) {
    const p = state.pitch.get(slot.id);
    if (p) {
      out.push({
        player_id: playerKey(p),
        slot_kind: "pitch",
        pitch_slot: slot.id,
        sort_order: DEFAULT_PITCH_SLOTS.indexOf(slot),
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

export function getSquadPlayerIds(savedRows) {
  if (!savedRows?.length) return null;
  return new Set(savedRows.map((r) => String(r.player_id)));
}

function buildStateFromSaved(allPlayers, savedRows) {
  const byId = new Map(allPlayers.map((p) => [playerKey(p), p]));
  const state = {
    pitch: new Map(DEFAULT_PITCH_SLOTS.map((s) => [s.id, null])),
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
    pitch: new Map(DEFAULT_PITCH_SLOTS.map((s) => [s.id, null])),
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

  for (const slot of DEFAULT_PITCH_SLOTS) {
    if (state.pitch.get(slot.id)) continue;
    const next = sorted.find((p) => !used.has(playerKey(p)));
    if (!next) break;
    state.pitch.set(slot.id, clonePlayer(next));
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

function renderPlayerCard(player, { compact = false } = {}) {
  const id = playerKey(player);
  const name = player.Name || player.player_name || id;
  const pos = player.Position || player.player_position || "";
  const card = document.createElement("div");
  card.className = "squad-player-card";
  card.draggable = true;
  card.dataset.playerId = id;
  card.innerHTML = `
    <img src="${playerCardUrl(id)}" alt="" draggable="false"
      onerror="this.src='${FALLBACK_IMG}'">
    <div class="spc-meta">
      <div class="spc-name">${name}</div>
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
function wirePositionDragging(pitchEl, slotPositions, getEditMode, onMoved) {
  let activeSlotId = null;
  let pointerId = null;

  pitchEl.addEventListener("pointerdown", (e) => {
    if (!getEditMode()) return;
    const grip = e.target.closest(".pitch-slot-grip");
    if (!grip) return;
    const wrap = grip.closest(".pitch-slot[data-slot-id]");
    if (!wrap) return;
    e.preventDefault();
    activeSlotId = wrap.dataset.slotId;
    pointerId = e.pointerId;
    grip.setPointerCapture(pointerId);
    wrap.classList.add("dragging-position");
  });

  pitchEl.addEventListener("pointermove", (e) => {
    if (!activeSlotId || e.pointerId !== pointerId) return;
    const rect = pitchEl.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * 100;
    const y = ((e.clientY - rect.top) / rect.height) * 100;
    slotPositions[activeSlotId] = {
      x: clampPct(x),
      y: clampPct(y),
    };
    onMoved();
  });

  const endDrag = (e) => {
    if (!activeSlotId || (e.pointerId != null && e.pointerId !== pointerId)) return;
    pitchEl
      .querySelector(`.pitch-slot[data-slot-id="${activeSlotId}"]`)
      ?.classList.remove("dragging-position");
    activeSlotId = null;
    pointerId = null;
  };

  pitchEl.addEventListener("pointerup", endDrag);
  pitchEl.addEventListener("pointercancel", endDrag);
}

export function initMatchdaySquadPanel({
  root,
  allPlayers,
  savedRows = [],
  savedPitchLayout = null,
  onChange,
  onSave,
}) {
  let editPositionsMode = false;
  let slotPositions = normalizePitchLayout(savedPitchLayout);
  let state =
    savedRows?.length > 0
      ? buildStateFromSaved(allPlayers, savedRows)
      : {
          pitch: new Map(DEFAULT_PITCH_SLOTS.map((s) => [s.id, null])),
          bench: Array(MAX_BENCH).fill(null),
          pool: allPlayers.map(clonePlayer),
        };

  root.innerHTML = `
    <p class="squad-hint">
      Drag player cards onto the pitch (11 starters) and bench (12 subs) for your
      <b>default 23-man matchday squad</b>. Use <b>Move positions</b> to drag formation markers on the pitch.
      Starters auto-tick <b>Started</b> when you submit match stats.
    </p>
    <div class="squad-toolbar">
      <button type="button" class="button secondary" id="squadAutoFillBtn">Auto-fill XI</button>
      <button type="button" class="button secondary" id="squadMovePosBtn">Move positions</button>
      <button type="button" class="button secondary" id="squadResetPosBtn" hidden>Reset layout</button>
      <button type="button" class="button secondary" id="squadClearBtn">Clear squad</button>
      <button type="button" class="button" id="squadSaveBtn">Save default squad</button>
      <span class="squad-status" id="squadStatusText"></span>
    </div>
    <p class="squad-hint" id="squadEditHint" style="display:none;color:#9c9;">
      Drag the <b>⋮⋮</b> handles on each position to arrange your formation. Player cards stay in place.
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

  function applySlotPositionsToDom() {
    for (const slot of DEFAULT_PITCH_SLOTS) {
      const wrap = pitchEl.querySelector(`.pitch-slot[data-slot-id="${slot.id}"]`);
      if (!wrap) continue;
      const pos = slotPositions[slot.id] || { x: slot.x, y: slot.y };
      wrap.style.left = `${pos.x}%`;
      wrap.style.top = `${pos.y}%`;
    }
  }

  function buildPitchSlotElements() {
    pitchEl.querySelectorAll(".pitch-slot").forEach((el) => el.remove());
    for (const slot of DEFAULT_PITCH_SLOTS) {
      const wrap = document.createElement("div");
      wrap.className = "pitch-slot";
      wrap.dataset.slotId = slot.id;
      const pos = slotPositions[slot.id] || { x: slot.x, y: slot.y };
      wrap.style.left = `${pos.x}%`;
      wrap.style.top = `${pos.y}%`;
      wrap.innerHTML = `
        <button type="button" class="pitch-slot-grip" aria-label="Move ${slot.label} position" title="Move position">⋮⋮</button>
        <span class="pitch-slot-label">${slot.label}</span>
        <div class="pitch-slot-drop" data-slot-id="${slot.id}"></div>`;
      pitchEl.appendChild(wrap);
    }
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

    for (const slot of DEFAULT_PITCH_SLOTS) {
      const drop = pitchEl.querySelector(`[data-slot-id="${slot.id}"]`);
      if (!drop) continue;
      drop.innerHTML = "";
      const p = state.pitch.get(slot.id);
      if (p) {
        const card = renderPlayerCard(p, { compact: true });
        if (editPositionsMode) card.draggable = false;
        drop.appendChild(card);
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
  wirePositionDragging(pitchEl, slotPositions, () => editPositionsMode, applySlotPositionsToDom);

  movePosBtn.addEventListener("click", () => setEditPositionsMode(!editPositionsMode));

  resetPosBtn.addEventListener("click", () => {
    slotPositions = normalizePitchLayout(null);
    buildPitchSlotElements();
    rerender();
  });

  root.querySelector("#squadAutoFillBtn").addEventListener("click", () => {
    state = autoFillBestXi(allPlayers);
    rerender();
  });

  root.querySelector("#squadClearBtn").addEventListener("click", () => {
    if (!confirm("Clear your saved matchday squad layout?")) return;
    state = {
      pitch: new Map(DEFAULT_PITCH_SLOTS.map((s) => [s.id, null])),
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
    statusText.textContent = "Saving…";
    try {
      await onSave(payload, buildPitchLayoutPayload(slotPositions));
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
        slotPositions = normalizePitchLayout(layout);
        buildPitchSlotElements();
      }
      rerender();
    },
  };
}
