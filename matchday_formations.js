/**
 * Default pitch formations — add more here anytime.
 * Slot ids (GK, LB, CB1, …) stay fixed so saved squads keep working.
 */

function L(id, label, x, y) {
  return { id, label, x, y };
}

/** @type {Record<string, { id: string, name: string, slots: Array<{ id: string, label: string, x: number, y: number }> }>} */
export const MATCHDAY_FORMATIONS = {
  "gpsl-flex": {
    id: "gpsl-flex",
    name: "GPSL Flex",
    slots: [
      L("GK", "GK", 50, 90),
      L("LB", "LB", 8, 72),
      L("CB1", "CB", 28, 74),
      L("CB2", "CB", 50, 76),
      L("RB", "CB", 72, 74),
      L("RMF", "RB", 92, 70),
      L("LMF", "DMF/CMF", 22, 56),
      L("CMF", "DMF/CMF", 50, 56),
      L("RWF", "DMF/CMF", 78, 56),
      L("LWF", "CF/SS", 32, 11),
      L("CF", "SS", 50, 24),
    ],
  },
  "4-3-3": {
    id: "4-3-3",
    name: "4-3-3",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "LM", 16, 48),
      L("CMF", "CM", 50, 52),
      L("RMF", "RM", 84, 48),
      L("LWF", "LW", 22, 22),
      L("CF", "CF", 50, 12),
      L("RWF", "RW", 78, 22),
    ],
  },
  "4-4-2": {
    id: "4-4-2",
    name: "4-4-2",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "LM", 14, 46),
      L("CMF", "CM", 38, 50),
      L("RMF", "RM", 62, 50),
      L("RWF", "RM", 86, 46),
      L("LWF", "ST", 38, 18),
      L("CF", "ST", 62, 18),
    ],
  },
  "4-2-3-1": {
    id: "4-2-3-1",
    name: "4-2-3-1",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "CDM", 38, 54),
      L("RMF", "CDM", 62, 54),
      L("LWF", "LW", 18, 32),
      L("CMF", "CAM", 50, 36),
      L("RWF", "RW", 82, 32),
      L("CF", "ST", 50, 12),
    ],
  },
  "3-5-2": {
    id: "3-5-2",
    name: "3-5-2",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("LB", "LWB", 10, 52),
      L("LMF", "LM", 30, 48),
      L("CMF", "CM", 50, 50),
      L("RMF", "RM", 70, 48),
      L("RWF", "RWB", 90, 52),
      L("LWF", "ST", 38, 16),
      L("CF", "ST", 62, 16),
    ],
  },
  "3-4-3": {
    id: "3-4-3",
    name: "3-4-3",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("LB", "LM", 14, 48),
      L("LMF", "CM", 38, 50),
      L("RMF", "CM", 62, 50),
      L("RWF", "RM", 86, 48),
      L("LWF", "LW", 22, 20),
      L("CF", "ST", 50, 12),
      L("CMF", "RW", 78, 20),
    ],
  },
  "5-3-2": {
    id: "5-3-2",
    name: "5-3-2",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LWB", 8, 58),
      L("CB1", "CB", 30, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 70, 72),
      L("RWF", "RWB", 92, 58),
      L("LMF", "CM", 30, 46),
      L("CMF", "CM", 50, 48),
      L("RMF", "CM", 70, 46),
      L("LWF", "ST", 38, 16),
      L("CF", "ST", 62, 16),
    ],
  },
  "4-5-1": {
    id: "4-5-1",
    name: "4-5-1",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "LM", 12, 44),
      L("CMF", "CM", 32, 48),
      L("RMF", "CM", 50, 50),
      L("LWF", "CM", 68, 48),
      L("RWF", "RM", 88, 44),
      L("CF", "ST", 50, 14),
    ],
  },
  "4-1-4-1": {
    id: "4-1-4-1",
    name: "4-1-4-1",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("CMF", "CDM", 50, 56),
      L("LMF", "LM", 14, 42),
      L("LWF", "CM", 38, 44),
      L("RMF", "CM", 62, 44),
      L("RWF", "RM", 86, 42),
      L("CF", "ST", 50, 14),
    ],
  },
};

export const DEFAULT_FORMATION_ID = "gpsl-flex";

export const FORMATION_LIST = Object.values(MATCHDAY_FORMATIONS).map((f) => ({
  id: f.id,
  name: f.name,
}));

export function getFormation(id) {
  return MATCHDAY_FORMATIONS[id] || MATCHDAY_FORMATIONS[DEFAULT_FORMATION_ID];
}

export function formationLayout(formationId) {
  const f = getFormation(formationId);
  const out = {};
  const labels = {};
  for (const slot of f.slots) {
    out[slot.id] = { x: slot.x, y: slot.y };
    labels[slot.id] = slot.label;
  }
  return { positions: out, labels, formationId: f.id };
}

/** Merge saved custom positions over a formation default. */
export function resolvePitchLayout(saved, fallbackFormationId = DEFAULT_FORMATION_ID) {
  const formationId = saved?.formation_id || fallbackFormationId;
  const base = formationLayout(formationId);
  const positions = { ...base.positions };
  const labels = { ...base.labels };

  if (saved && typeof saved === "object") {
    for (const slot of Object.keys(base.positions)) {
      const s = saved[slot];
      if (s && typeof s === "object" && s.x != null && s.y != null) {
        positions[slot] = {
          x: Math.min(96, Math.max(4, Number(s.x))),
          y: Math.min(96, Math.max(4, Number(s.y))),
        };
      }
      if (s?.label) labels[slot] = s.label;
    }
  }

  return { formationId, positions, labels };
}

export function buildPitchLayoutPayload(slotPositions, labels, formationId) {
  const out = { formation_id: formationId };
  for (const [id, pos] of Object.entries(slotPositions)) {
    out[id] = {
      x: Math.round(pos.x * 10) / 10,
      y: Math.round(pos.y * 10) / 10,
      label: labels[id] || id,
    };
  }
  return out;
}
