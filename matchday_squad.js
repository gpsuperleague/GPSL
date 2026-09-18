/**
 * Matchday squad picker — 23-man squad with drag-and-drop on a virtual pitch.
 */

import {
  DEFAULT_FORMATION_ID,
  FORMATION_LIST,
  getFormation,
  formationLayout,
  resolvePitchLayout,
  buildPitchLayoutPayload,
  normalizePitchLayout,
  pitchLayoutHasSlots,
  spaceGkFromDefenders,
} from "./matchday_formations.js?v=20260918-cards-narrow";
import {
  loadGpslFormations,
  listSelectableFormations,
  getSelectableFormation,
  formationPickerGroups,
  formationLabel,
  slotRoleOptions,
  validateOwnerPitchLabels,
  isUsingCatalogueFormations,
  getFormationsCache,
} from "./gpsl_formations.js";
import {
  pesdbPlayerCardUrl,
  pesdbPlayerUrl,
  gpdbPlayerUrl,
  playerNameLinkHtml,
  playerNameStackedLinkHtml,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js?v=20260918-cards-narrow";
import { analyseMatchdayComposition } from "./squad_rules.js";

export { buildPitchLayoutPayload } from "./matchday_formations.js?v=20260918-cards-narrow";

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
  if (!player || !target) return null;
  const id = playerKey(player);
  const maxSquad = state.maxSquad ?? MAX_SQUAD;
  const fromLoc = findPlayerLocation(state, id);
  if (!fromLoc) return null;

  const sameSlot =
    target.area === fromLoc.area &&
    ((target.area === "pitch" && target.slotId === fromLoc.slotId) ||
      (target.area === "bench" && Number(target.index) === Number(fromLoc.index)) ||
      target.area === "pool");
  if (sameSlot) return null;

  let displaced = null;
  if (target.area === "pitch") {
    displaced = state.pitch.get(target.slotId) || null;
  } else if (target.area === "bench") {
    displaced = state.bench[target.index] || null;
  }

  if (
    !isInSquad(state, id) &&
    target.area !== "pool" &&
    !displaced &&
    squadCount(state) >= maxSquad
  ) {
    return { error: `Squad is full (${maxSquad} players).` };
  }

  removePlayerFromState(state, id);

  if (target.area === "pitch") {
    state.pitch.set(target.slotId, clonePlayer(player));
  } else if (target.area === "bench") {
    state.bench[target.index] = clonePlayer(player);
  } else if (target.area === "pool") {
    state.pool.push(clonePlayer(player));
  }

  if (displaced && playerKey(displaced) !== id) {
    if (fromLoc.area === "pitch") {
      state.pitch.set(fromLoc.slotId, clonePlayer(displaced));
    } else if (fromLoc.area === "bench") {
      state.bench[fromLoc.index] = clonePlayer(displaced);
    } else {
      state.pool.push(clonePlayer(displaced));
    }
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

function buildStateFromSaved(allPlayers, savedRows, maxBench = MAX_BENCH) {
  const byId = new Map(allPlayers.map((p) => [playerKey(p), p]));
  const benchSize = Math.max(1, Number(maxBench) || MAX_BENCH);
  const state = {
    pitch: emptyPitchMap(),
    bench: Array(benchSize).fill(null),
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
      const idx = Math.min(Math.max(Number(row.sort_order) || 0, 0), benchSize - 1);
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

function autoFillBestXi(allPlayers, maxBench = MAX_BENCH) {
  const benchSize = Math.max(1, Number(maxBench) || MAX_BENCH);
  const state = {
    pitch: emptyPitchMap(),
    bench: Array(benchSize).fill(null),
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
    if (benchIdx < benchSize) {
      state.bench[benchIdx++] = clonePlayer(p);
      used.add(playerKey(p));
    }
  }
  for (const p of allPlayers) {
    if (!used.has(playerKey(p))) state.pool.push(clonePlayer(p));
  }
  return state;
}

function renderPlayerCard(
  player,
  {
    compact = false,
    pitch = false,
    removable = false,
    status = null,
    showGpdbLink = false,
  } = {}
) {
  const id = playerKey(player);
  const name = player.Name || player.player_name || id;
  const pos = player.Position || player.player_position || "";
  const card = document.createElement("div");
  let statusClass = "";
  if (status === "suspended") statusClass = " squad-player-card--suspended";
  else if (status === "injured" || status === "recovery") {
    statusClass = " squad-player-card--injured";
  }
  card.className =
    "squad-player-card" +
    (pitch ? " squad-player-card--pitch" : "") +
    (removable ? " squad-player-card--removable" : "") +
    statusClass;
  if (status === "suspended") card.title = "Suspended";
  else if (status === "injured") card.title = "Injured";
  else if (status === "recovery") card.title = "Gaining match fitness";
  card.draggable = true;
  card.dataset.playerId = id;
  card.innerHTML = `
    ${
      removable
        ? `<button type="button" class="spc-remove" title="Remove to pool" aria-label="Remove ${name}">✕</button>`
        : ""
    }
    <a href="${pesdbPlayerUrl(id)}" target="_blank" rel="noopener" class="squad-player-card-thumb-link" draggable="false">
      <img src="${playerCardUrl(id)}" alt="" draggable="false"
        onerror="this.src='${FALLBACK_IMG}'">
    </a>
    <div class="spc-meta">
      <div class="spc-name">${
        pitch
          ? playerNameStackedLinkHtml(id, name)
          : playerNameLinkHtml(id, name)
      }</div>
      ${compact ? "" : `<div class="spc-pos">${pos}${showGpdbLink ? ` · <a href="${gpdbPlayerUrl(id)}" class="gpsl-player-link" draggable="false">GPDB</a>` : ""}</div>`}
    </div>`;
  const removeBtn = card.querySelector(".spc-remove");
  if (removeBtn) {
    removeBtn.addEventListener("pointerdown", (e) => e.stopPropagation());
    removeBtn.addEventListener("mousedown", (e) => e.stopPropagation());
    removeBtn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
    });
  }
  card.addEventListener("dragstart", (e) => {
    if (e.target.closest?.(".spc-remove")) {
      e.preventDefault();
      return;
    }
    e.dataTransfer.setData("text/plain", id);
    e.dataTransfer.setData("text/player-id", id);
    e.dataTransfer.effectAllowed = "move";
    card.classList.add("dragging");
  });
  card.querySelectorAll("a").forEach((link) => {
    link.draggable = false;
    link.addEventListener("dragstart", (e) => e.preventDefault());
  });
  card.addEventListener("dragend", () => card.classList.remove("dragging"));
  return card;
}

function resolveDropTarget(el) {
  if (!el) return null;

  const pitchDrop = el.closest(".pitch-slot-drop[data-slot-id]");
  if (pitchDrop) {
    return { area: "pitch", slotId: pitchDrop.dataset.slotId };
  }

  const pitchSlot = el.closest(".pitch-slot[data-slot-id]");
  if (pitchSlot) {
    return { area: "pitch", slotId: pitchSlot.dataset.slotId };
  }

  const benchDrop = el.closest(".bench-slot-drop[data-bench-idx]");
  if (benchDrop) {
    return { area: "bench", index: Number(benchDrop.dataset.benchIdx) };
  }

  const benchSlot = el.closest(".bench-slot");
  if (benchSlot) {
    const nested = benchSlot.querySelector(".bench-slot-drop[data-bench-idx]");
    if (nested) {
      return { area: "bench", index: Number(nested.dataset.benchIdx) };
    }
  }

  if (el.closest("#squadPoolList")) {
    return { area: "pool" };
  }

  return null;
}

function dropTargetFromEvent(e) {
  const direct = resolveDropTarget(e.target);
  if (direct) return direct;

  if (typeof e.clientX === "number" && typeof e.clientY === "number") {
    const under = document.elementFromPoint(e.clientX, e.clientY);
    if (under && under !== e.target) {
      return resolveDropTarget(under);
    }
  }

  return null;
}

function dropHighlightEl(el) {
  return (
    el?.closest(".pitch-slot-drop") ||
    el?.closest(".pitch-slot") ||
    el?.closest(".bench-slot-drop") ||
    el?.closest(".bench-slot") ||
    el?.closest("#squadPoolList") ||
    null
  );
}

function wireDragDrop(root, getState, rerender) {
  root.addEventListener("dragover", (e) => {
    const target = dropTargetFromEvent(e);
    if (!target) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const dropEl = dropHighlightEl(
      document.elementFromPoint(e.clientX, e.clientY) || e.target
    );
    dropEl?.classList.add("drag-over");
  });

  root.addEventListener("dragleave", (e) => {
    const dropEl = dropHighlightEl(e.target);
    dropEl?.classList.remove("drag-over");
  });

  root.addEventListener("drop", (e) => {
    const target = dropTargetFromEvent(e);
    if (!target) return;
    e.preventDefault();
    e.stopPropagation();
    root.querySelectorAll(".drag-over").forEach((el) => el.classList.remove("drag-over"));

    const id =
      e.dataTransfer.getData("text/player-id") ||
      e.dataTransfer.getData("text/plain");
    if (!id) return;
    const state = typeof getState === "function" ? getState() : getState;
    if (!state) return;
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

function wirePitchLabelPicker(pitchEl, slotLabels, getOptionsForSlot) {
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

    const options =
      typeof getOptionsForSlot === "function"
        ? getOptionsForSlot(slotId)
        : [slotLabels[slotId] || slotId];
    const locked = options.length <= 1;

    const title = document.createElement("div");
    title.className = "pitch-label-menu-title";
    title.textContent = locked
      ? `Role locked — ${slotLabels[slotId] || slotId}`
      : `Change role — ${slotLabels[slotId] || slotId}`;
    menu.appendChild(title);

    if (locked) {
      const note = document.createElement("div");
      note.className = "pitch-label-menu-note";
      note.style.cssText = "font-size:11px;color:#999;margin:0 0 8px;";
      note.textContent = "This slot is locked for the selected formation.";
      menu.appendChild(note);
    }

    const grid = document.createElement("div");
    grid.className = "pitch-label-menu-grid";
    for (const label of options) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "pitch-label-option" + (slotLabels[slotId] === label ? " selected" : "");
      btn.textContent = label;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        if (locked) {
          closeMenu();
          return;
        }
        slotLabels[slotId] = label;
        updateSlotLabelDom(slotId);
        closeMenu();
      });
      grid.appendChild(btn);
    }
    menu.appendChild(grid);

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
    if (e.target.closest(".spc-remove")) return;

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
  return (
    listSelectableFormations().some((f) => f.id === id) ||
    FORMATION_LIST.some((f) => f.id === id)
  );
}

export function initMatchdaySquadPanel({
  root,
  allPlayers,
  savedRows = [],
  savedPitchLayout = null,
  savedFormations = [],
  maxBench = MAX_BENCH,
  /** First N bench slots labelled Sub; remaining labelled Squad (scouting fillers). */
  benchSubSlots = null,
  maxSquad = null,
  onChange,
  onSave,
  onSaveFormation,
  onLoadFormation,
  onDeleteFormation,
  /** Optional: replace default Auto-fill XI. Receives { allPlayers, maxBench, maxSquad, formationId, labels }. Return state or null. */
  customAutoFill = null,
  autoFillButtonLabel = null,
  /** When true, enforce Match Day HG / U21 / GK mins (live strip + save block). */
  matchdayComposition = false,
  clubNation = null,
  /** @type {Map<string, 'suspended'|'injured'|'recovery'>|null} */
  playerStatusById = null,
  showGpdbLink = false,
}) {
  /** @type {Map<string, 'suspended'|'injured'|'recovery'>} */
  let statusById = playerStatusById instanceof Map ? playerStatusById : new Map();

  const statusFor = (player) => statusById.get(playerKey(player)) || null;
  const benchLimit = Math.max(1, Number(maxBench) || MAX_BENCH);
  const subSlotCount = Math.max(
    0,
    Math.min(
      benchLimit,
      benchSubSlots == null ? benchLimit : Number(benchSubSlots) || benchLimit
    )
  );
  const squadFillerCount = Math.max(0, benchLimit - subSlotCount);
  const effectiveSquadLimit =
    maxSquad != null
      ? Math.max(MAX_PITCH, Number(maxSquad) || MAX_PITCH + benchLimit)
      : MAX_PITCH + benchLimit;

  const resolved = resolvePitchLayout(savedPitchLayout);
  let currentFormationId = resolved.formationId;
  let slotPositions = { ...resolved.positions };
  let slotLabels = { ...resolved.labels };
  let state =
    savedRows?.length > 0
      ? buildStateFromSaved(allPlayers, savedRows, benchLimit)
      : {
          pitch: emptyPitchMap(),
          bench: Array(benchLimit).fill(null),
          pool: allPlayers.map(clonePlayer),
        };
  state.maxBench = benchLimit;
  state.maxSquad = effectiveSquadLimit;
  const subsRangeStart = MAX_PITCH + 1;
  const subsRangeEnd = MAX_PITCH + subSlotCount;
  const squadRangeStart = subsRangeEnd + 1;
  const squadRangeEnd = MAX_PITCH + benchLimit;

  const benchHeading =
    squadFillerCount > 0
      ? `Subs (${subsRangeStart}-${subsRangeEnd}) + Squad (${squadRangeStart}-${squadRangeEnd})`
      : `Bench (${benchLimit} subs)`;

  const benchHtml =
    squadFillerCount > 0
      ? `
        <div class="squad-bench-wrap">
          <div class="squad-bench squad-bench--subs">
            <h4>Subs <span class="bench-count">(${subsRangeStart}-${subsRangeEnd})</span></h4>
            <div class="bench-slots bench-slots-grid" id="benchSlotsSubs"></div>
          </div>
          <div class="squad-bench squad-bench--squad">
            <h4>Squad fillers <span class="bench-count">(${squadRangeStart}-${squadRangeEnd})</span></h4>
            <p class="bench-squad-hint">Not matchday substitutes — planning depth only. Drag here or use ✕ to return to the pool.</p>
            <div class="bench-slots bench-slots-grid" id="benchSlotsSquad"></div>
          </div>
        </div>`
      : `
        <div class="squad-bench">
          <h4>${benchHeading}</h4>
          <div class="bench-slots bench-slots-grid" id="benchSlotsSubs"></div>
        </div>`;

  root.innerHTML = `
    <div class="squad-formations-bar">
      <div class="formation-section-row">
        <span class="formation-section-label">Formations</span>
        <select id="squadFormationSelect" class="formation-select" title="Out-of-the-box formations — Apply resets roles and marker positions"></select>
        <button type="button" class="button secondary" id="squadApplyTemplateBtn">Apply Formation</button>
      </div>
    </div>
    <div class="squad-toolbar">
      <button type="button" class="button secondary" id="squadAutoFillBtn">Auto-fill XI</button>
      <button type="button" class="button secondary" id="squadClearBtn">Clear squad</button>
      <button type="button" class="button" id="squadSaveBtn">Save default squad</button>
      <span class="squad-status" id="squadStatusText"></span>
    </div>
    ${
      matchdayComposition
        ? `<div class="matchday-comp-strip" id="matchdayCompStrip" aria-live="polite"></div>`
        : ""
    }
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
        ${benchHtml}
      </div>
    </div>`;

  const pitchEl = root.querySelector("#footballPitch");
  const poolList = root.querySelector("#squadPoolList");
  const benchSlotsSubs = root.querySelector("#benchSlotsSubs");
  const benchSlotsSquad = root.querySelector("#benchSlotsSquad");
  const statusText = root.querySelector("#squadStatusText");
  const matchdayCompStrip = root.querySelector("#matchdayCompStrip");
  const formationSelect = root.querySelector("#squadFormationSelect");

  function forEachBenchDrop(fn) {
    root.querySelectorAll(".bench-slot-drop").forEach(fn);
  }
  function fillFormationSelect() {
    formationSelect.innerHTML = "";
    for (const { group, formations } of formationPickerGroups()) {
      const og = document.createElement("optgroup");
      og.label = group;
      for (const f of formations) {
        const opt = document.createElement("option");
        opt.value = f.id;
        opt.textContent = formationLabel(f);
        og.appendChild(opt);
      }
      formationSelect.appendChild(og);
    }
    const ids = listSelectableFormations().map((f) => f.id);
    const preferred =
      currentFormationId && currentFormationId !== "custom"
        ? currentFormationId
        : formationSelect.value;
    formationSelect.value = ids.includes(preferred)
      ? preferred
      : ids.includes(currentFormationId)
        ? currentFormationId
        : ids[0] || DEFAULT_FORMATION_ID;
  }

  function updateFormationRulesStatus() {
    const cache = getFormationsCache();
    const using = isUsingCatalogueFormations();
    const selected = formationSelect.value;
    const f = getSelectableFormation(selected);
    const cf = f?.slots?.find((s) => s.id === "CF");
    const cfHint = cf
      ? `CF slot → ${cf.allowRelabel ? (cf.allowedPositions || []).join("/") : cf.label + " (locked)"}`
      : "";
    if (!using) {
      statusText.textContent = cache.error
        ? `Formation catalogue unavailable (${cache.error}). Roles locked to defaults.`
        : "Formation catalogue not loaded — roles locked to defaults. Re-open page or check admin SQL.";
      return;
    }
    statusText.textContent = `Catalogue active · rules from ${selected}${cfHint ? ` · ${cfHint}` : ""}`;
  }

  fillFormationSelect();
  updateFormationRulesStatus();

  // Ensure catalogue is loaded (retry if an earlier call cached an empty miss).
  void loadGpslFormations({ force: true }).then(() => {
    fillFormationSelect();
    updateFormationRulesStatus();
  });

  formationSelect.addEventListener("change", () => {
    // Role rules follow the dropdown immediately (Apply still resets pitch coords/labels).
    updateFormationRulesStatus();
  });

  function applySlotPositionsToDom() {
    replaceSlotMap(slotPositions, spaceGkFromDefenders(slotPositions));
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
    replaceSlotMap(slotPositions, spaceGkFromDefenders(slotPositions));
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

  /**
   * Role rules must follow the formation chosen in the dropdown when possible.
   * Saved layouts often store formation_id "custom", which must NOT fall through
   * to an unrestricted hardcoded preset.
   */
  function formationForRoleRules() {
    const selected = String(formationSelect?.value || "").trim();
    if (selected && selected !== "custom") {
      const fromSelect = getSelectableFormation(selected);
      if (fromSelect) return fromSelect;
    }
    const current = String(currentFormationId || "").trim();
    if (current && current !== "custom") {
      const fromCurrent = getSelectableFormation(current);
      if (fromCurrent) return fromCurrent;
    }
    return getSelectableFormation(DEFAULT_FORMATION_ID);
  }

  function roleOptionsForSlot(slotId) {
    return slotRoleOptions(
      formationForRoleRules(),
      slotId,
      slotLabels[slotId] || slotId
    );
  }

  function guardFormationRules() {
    const formation = formationForRoleRules();
    const result = validateOwnerPitchLabels(formation, slotLabels);
    if (!result.ok) {
      alert(
        `Cannot save — formation rules failed:\n\n${result.errors.join("\n")}`
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
    const sel = getSelectableFormation(formationId);
    if (sel?.slots?.length) {
      currentFormationId = sel.id;
      const positions = {};
      const labels = {};
      for (const s of sel.slots) {
        positions[s.id] = { x: s.x, y: s.y };
        labels[s.id] = s.label;
      }
      replaceSlotMap(slotPositions, spaceGkFromDefenders(positions));
      replaceSlotMap(slotLabels, labels);
    } else {
      const base = formationLayout(formationId);
      currentFormationId = base.formationId;
      replaceSlotMap(slotPositions, base.positions);
      replaceSlotMap(slotLabels, base.labels);
    }
    formationSelect.value = currentFormationId;
    buildPitchSlotElements();
    rerenderPlayerCards();
  }

  buildPitchSlotElements();

  for (let i = 0; i < benchLimit; i++) {
    const wrap = document.createElement("div");
    const isSub = i < subSlotCount;
    wrap.className = isSub ? "bench-slot bench-slot--sub" : "bench-slot bench-slot--squad";
    const label = isSub ? `Sub ${i + 1}` : `Squad ${i + 1}`;
    wrap.innerHTML = `
      <div class="bench-slot-label">${label}</div>
      <div class="bench-slot-drop" data-bench-idx="${i}"></div>`;
    const parent = isSub ? benchSlotsSubs : benchSlotsSquad || benchSlotsSubs;
    parent?.appendChild(wrap);
  }


  function updateStatus() {
    const pitchN = [...state.pitch.values()].filter(Boolean).length;
    const subN = state.bench.slice(0, subSlotCount).filter(Boolean).length;
    const fillerN =
      squadFillerCount > 0
        ? state.bench.slice(subSlotCount).filter(Boolean).length
        : 0;
    const total = squadCount(state);
    statusText.textContent =
      squadFillerCount > 0
        ? `Squad: ${total}/${effectiveSquadLimit} · Pitch ${pitchN}/${MAX_PITCH} · Subs ${subN}/${subSlotCount} · Squad ${fillerN}/${squadFillerCount}`
        : `Squad: ${total}/${effectiveSquadLimit} · Pitch ${pitchN}/${MAX_PITCH} · Bench ${subN}/${benchLimit}`;
    root.querySelector("#squadPoolCount").textContent = `${state.pool.length} players available`;
    updateMatchdayCompositionStrip();
    onChange?.(buildSlotsPayload(state), state);
  }

  function updateMatchdayCompositionStrip() {
    if (!matchdayComposition || !matchdayCompStrip) return;
    const pitchPlayers = [...state.pitch.values()].filter(Boolean);
    const benchPlayers = state.bench.filter(Boolean);
    const c = analyseMatchdayComposition(pitchPlayers, benchPlayers, clubNation);
    const chip = (label, value, min, ok) =>
      `<span class="matchday-comp-chip ${ok ? "ok" : "short"}" title="${label}: ${value} / ${min}">${label} <b>${value}</b><i>/${min}</i></span>`;
    matchdayCompStrip.innerHTML = `
      <span class="matchday-comp-label">Matchday rules</span>
      ${chip("GK", c.goalkeepers, c.minGk, c.gkOk)}
      ${chip("XI HG", c.hgXi, c.minHgXi, c.hgXiOk)}
      ${chip("Squad HG", c.hgTotal, c.minHgSquad, c.hgSquadOk)}
      ${chip("U21", c.under21, c.minU21, c.u21Ok)}
      ${
        c.ok
          ? `<span class="matchday-comp-ok">Ready to save</span>`
          : `<span class="matchday-comp-warn">Fix before save</span>`
      }`;
  }

  function matchdayCompositionErrors() {
    if (!matchdayComposition) return [];
    const pitchPlayers = [...state.pitch.values()].filter(Boolean);
    const benchPlayers = state.bench.filter(Boolean);
    return analyseMatchdayComposition(pitchPlayers, benchPlayers, clubNation)
      .errors;
  }

  function rerenderPlayerCards() {
    poolList.innerHTML = "";
    for (const p of state.pool) {
      poolList.appendChild(renderPlayerCard(p, { status: statusFor(p), showGpdbLink }));
    }

    for (const slotId of SLOT_IDS) {
      const drop = pitchEl.querySelector(`.pitch-slot-drop[data-slot-id="${slotId}"]`);
      if (!drop) continue;
      const p = state.pitch.get(slotId);
      drop.innerHTML = "";
      if (p) {
        const card = renderPlayerCard(p, {
          compact: true,
          pitch: true,
          removable: true,
          status: statusFor(p),
          showGpdbLink,
        });
        card.draggable = true;
        drop.appendChild(card);
      } else {
        drop.innerHTML = '<span class="pitch-slot-placeholder"></span>';
      }
    }

    forEachBenchDrop((drop) => {
      const idx = Number(drop.dataset.benchIdx);
      drop.innerHTML = "";
      const p = state.bench[idx];
      if (p) {
        drop.appendChild(
          renderPlayerCard(p, {
            compact: true,
            removable: true,
            status: statusFor(p),
            showGpdbLink,
          })
        );
      }
    });

    updateStatus();
  }

  function rerender() {
    rerenderPlayerCards();
  }

  wireDragDrop(root, () => state, rerender);
  wirePitchLabelPicker(pitchEl, slotLabels, roleOptionsForSlot);

  // Capture phase so ✕ remove runs before pitch role-picker card clicks
  root.addEventListener(
    "click",
    (e) => {
      const btn = e.target.closest?.(".spc-remove");
      if (!btn || !root.contains(btn)) return;
      e.preventDefault();
      e.stopPropagation();
      const card = btn.closest(".squad-player-card");
      const id = card?.dataset.playerId;
      if (!id) return;
      const player = removePlayerFromState(state, id);
      if (!player) return;
      state.pool.unshift(clonePlayer(player));
      rerender();
    },
    true
  );


  root.querySelector("#squadApplyTemplateBtn").addEventListener("click", () => {
    const templateId = formationSelect.value;
    const name = formationLabel(getSelectableFormation(templateId)) || templateId;
    if (
      !confirm(
        `Apply formation “${name}”? This resets all pitch marker positions and role labels (players stay put).`
      )
    ) {
      return;
    }
    applyFormation(templateId);
  });



  root.querySelector("#squadAutoFillBtn").addEventListener("click", () => {
    if (typeof customAutoFill === "function") {
      const next = customAutoFill({
        allPlayers,
        maxBench: benchLimit,
        maxSquad: effectiveSquadLimit,
        formationId: currentFormationId,
        labels: { ...slotLabels },
        positions: { ...slotPositions },
        getState: () => state,
      });
      if (next) {
        state = next;
        state.maxBench = benchLimit;
        state.maxSquad = effectiveSquadLimit;
        rerender();
      }
      return;
    }
    state = autoFillBestXi(allPlayers, benchLimit);
    state.maxBench = benchLimit;
    state.maxSquad = effectiveSquadLimit;
    rerender();
  });
  if (autoFillButtonLabel) {
    const afBtn = root.querySelector("#squadAutoFillBtn");
    if (afBtn) afBtn.textContent = autoFillButtonLabel;
  }

  root.querySelector("#squadClearBtn").addEventListener("click", () => {
    if (!confirm("Clear your saved matchday squad layout?")) return;
    state = {
      pitch: emptyPitchMap(),
      bench: Array(benchLimit).fill(null),
      pool: allPlayers.map(clonePlayer),
      maxBench: benchLimit,
      maxSquad: effectiveSquadLimit,
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
    if (!guardFormationRules()) return;

    const compErrors = matchdayCompositionErrors();
    if (compErrors.length) {
      alert(`Cannot save matchday squad:\n\n${compErrors.join("\n")}`);
      statusText.textContent = "Composition rules not met";
      updateMatchdayCompositionStrip();
      return;
    }

    statusText.textContent = "Saving…";
    try {
      await onSave(
        payload,
        buildPitchLayoutPayload(
          slotPositions,
          slotLabels,
          // Prefer the selected catalogue formation so role rules stay attached
          formationSelect.value && formationSelect.value !== "custom"
            ? formationSelect.value
            : currentFormationId && currentFormationId !== "custom"
              ? currentFormationId
              : formationSelect.value || DEFAULT_FORMATION_ID
        )
      );
      state = buildStateFromSaved(allPlayers, payload, benchLimit);
      state.maxBench = benchLimit;
      state.maxSquad = effectiveSquadLimit;
      statusText.textContent = `Saved ${payload.length} players.`;
    } catch (err) {
      statusText.textContent = err?.message || "Save failed";
      alert(err?.message || "Save failed");
    }
  });

  rerender();
  return {
    getState: () => state,
    getFormationMeta: () => ({
      formationId: currentFormationId,
      labels: { ...slotLabels },
      positions: { ...slotPositions },
    }),
    applyState: (next) => {
      if (!next) return;
      state = next;
      state.maxBench = benchLimit;
      state.maxSquad = effectiveSquadLimit;
      rerender();
    },
    setSavedRows: (rows, layout) => {
      state = buildStateFromSaved(allPlayers, rows);
      if (layout != null) {
        applyLayoutFromResolved(resolvePitchLayout(layout));
      } else {
        rerender();
      }
    },
    setPlayerStatuses: (nextMap) => {
      statusById = nextMap instanceof Map ? nextMap : new Map();
      rerenderPlayerCards();
    },
    reloadFormations: async () => {
      await loadGpslFormations({ force: true });
      fillFormationSelect();
    },
    refreshSavedFormations: () => {},
  };
}
