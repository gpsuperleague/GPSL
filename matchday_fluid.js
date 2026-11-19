/**
 * Fluid shapes: one starting 11, two formations.
 * The visible side stays in the squad rows. The other side lives in pitch_layout.fluid
 * so target lists and check-in still see each player once.
 */

export const FLUID_SLOT_IDS = [
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

const FAMILY = {
  GK: "gk",
  CB: "cb",
  LB: "fb",
  RB: "fb",
  DMF: "dm",
  CMF: "cm",
  AMF: "am",
  LMF: "wideL",
  RMF: "wideR",
  LWF: "wideL",
  RWF: "wideR",
  LW: "wideL",
  RW: "wideR",
  SS: "st",
  CF: "st",
};

const LINE = {
  gk: 0,
  cb: 1,
  fb: 1,
  dm: 2,
  cm: 2,
  wideL: 2,
  wideR: 2,
  am: 3,
  st: 4,
};

function familyOf(label) {
  const key = String(label || "").toUpperCase();
  return FAMILY[key] || "cm";
}

function playerFamily(player) {
  return familyOf(player?.Position || player?.position || "");
}

function playerId(player) {
  return String(player?.Konami_ID ?? player?.player_id ?? "");
}

export function emptyFluidPlayers() {
  return Object.fromEntries(FLUID_SLOT_IDS.map((id) => [id, null]));
}

function clonePositions(positions) {
  const out = {};
  for (const [id, pos] of Object.entries(positions || {})) {
    if (!pos || typeof pos !== "object") continue;
    out[id] = { x: Number(pos.x) || 0, y: Number(pos.y) || 0 };
  }
  return out;
}

export function captureFluidSide(formationId, positions, labels, pitch) {
  const players = emptyFluidPlayers();
  for (const id of FLUID_SLOT_IDS) {
    const p = pitch?.get?.(id);
    players[id] = p ? playerId(p) : null;
  }
  return {
    formationId: formationId || "custom",
    positions: clonePositions(positions),
    labels: { ...(labels || {}) },
    players,
  };
}

export function cloneFluidSide(side) {
  if (!side) return null;
  return {
    formationId: side.formationId,
    positions: clonePositions(side.positions),
    labels: { ...(side.labels || {}) },
    players: { ...emptyFluidPlayers(), ...(side.players || {}) },
  };
}

/** Other shape stored on a pitch_layout, or null when fluid is off. */
export function readFluidBlock(layout) {
  const fluid = layout?.fluid;
  if (!fluid || fluid.on !== true || !fluid.other) return null;
  const other = fluid.other;
  const players = emptyFluidPlayers();
  for (const id of FLUID_SLOT_IDS) {
    const pid = other.players?.[id];
    players[id] = pid ? String(pid) : null;
  }
  return {
    side: fluid.side === "attacking" ? "attacking" : "defensive",
    other: {
      formationId: other.formation_id || other.formationId || "custom",
      positions: clonePositions(other.positions),
      labels: { ...(other.labels || {}) },
      players,
    },
  };
}

export function fluidBlockPayload(activeSide, otherSide) {
  return {
    on: true,
    side: activeSide === "attacking" ? "attacking" : "defensive",
    other: {
      formation_id: otherSide?.formationId || "custom",
      positions: clonePositions(otherSide?.positions),
      labels: { ...(otherSide?.labels || {}) },
      players: { ...emptyFluidPlayers(), ...(otherSide?.players || {}) },
    },
  };
}

/**
 * Empty slot on the other shape whose role is closest to this player.
 * Goalkeepers only take GK. Outfield players never take GK.
 */
export function bestEmptySlot(player, labels, occupied) {
  const fam = playerFamily(player);
  const empty = FLUID_SLOT_IDS.filter((id) => !occupied.has(id));
  const pool =
    fam === "gk"
      ? empty.filter((id) => id === "GK")
      : empty.filter((id) => id !== "GK");
  const choices = pool.length ? pool : fam === "gk" ? [] : empty;
  let best = null;
  let bestScore = -1;
  for (const id of choices) {
    const labelFam = familyOf(labels?.[id] || id);
    let score = 10;
    if (labelFam === fam) score = 100;
    else if (LINE[labelFam] === LINE[fam]) score = 50;
    if (familyOf(id) === fam) score += 5;
    if (score > bestScore) {
      bestScore = score;
      best = id;
    }
  }
  return best;
}

/**
 * Make the hidden shape's eleven the same players as the pitch.
 * Slots already held by someone who is still in the eleven stay put.
 * Someone new is dropped into the closest empty role.
 */
export function syncFluidPlayers(players, pitchPlayers, labels) {
  const map = { ...emptyFluidPlayers(), ...(players || {}) };
  const byId = new Map();
  for (const player of pitchPlayers || []) {
    const id = playerId(player);
    if (id) byId.set(id, player);
  }
  for (const slot of FLUID_SLOT_IDS) {
    const id = map[slot] ? String(map[slot]) : "";
    if (id && !byId.has(id)) map[slot] = null;
  }

  const assigned = () =>
    new Set(FLUID_SLOT_IDS.map((slot) => (map[slot] ? String(map[slot]) : "")).filter(Boolean));

  const missing = [...byId.keys()].filter((id) => !assigned().has(id));
  missing.sort((a, b) => {
    const ag = playerFamily(byId.get(a)) === "gk" ? 0 : 1;
    const bg = playerFamily(byId.get(b)) === "gk" ? 0 : 1;
    return ag - bg;
  });

  for (const id of missing) {
    const player = byId.get(id);
    if (playerFamily(player) === "gk") {
      const prev = map.GK ? String(map.GK) : "";
      map.GK = id;
      if (prev && prev !== id && byId.has(prev)) {
        const occupied = new Set(
          FLUID_SLOT_IDS.filter((slot) => map[slot])
        );
        const slot = bestEmptySlot(byId.get(prev), labels, occupied);
        if (slot) map[slot] = prev;
      }
      continue;
    }
    const occupied = new Set(FLUID_SLOT_IDS.filter((slot) => map[slot]));
    const slot = bestEmptySlot(player, labels, occupied);
    if (slot) map[slot] = id;
  }

  return map;
}
