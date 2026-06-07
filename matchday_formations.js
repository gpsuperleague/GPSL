/**
 * Default pitch formations — add more here anytime.
 * Slot ids (GK, LB, CB1, …) stay fixed so saved squads keep working.
 */

function L(id, label, x, y) {
  return { id, label, x, y };
}

export const FORMATION_GROUP_ORDER = ["Back-4", "Back-3", "Back-5"];

/** @type {Record<string, { id: string, group: string, name: string, description: string, slots: Array<{ id: string, label: string, x: number, y: number }> }>} */
export const MATCHDAY_FORMATIONS = {
  "4-4-2": {
    id: "4-4-2",
    group: "Back-4",
    name: "4-4-2",
    description: "Balanced, classic shape",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "LMF", 14, 46),
      L("CMF", "CMF", 38, 50),
      L("RMF", "RMF", 62, 50),
      L("RWF", "RMF", 86, 46),
      L("LWF", "CF", 38, 18),
      L("CF", "CF", 62, 18),
    ],
  },
  "4-3-3": {
    id: "4-3-3",
    group: "Back-4",
    name: "4-3-3",
    description: "High pressing, possession, wide play",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "CMF", 16, 48),
      L("CMF", "CMF", 50, 52),
      L("RMF", "CMF", 84, 48),
      L("LWF", "LWF", 22, 22),
      L("CF", "CF", 50, 12),
      L("RWF", "RWF", 78, 22),
    ],
  },
  "4-3-2-1": {
    id: "4-3-2-1",
    group: "Back-4",
    name: "4-3-2-1",
    description: 'Narrow "Christmas Tree", strong central buildup',
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "CMF", 22, 52),
      L("CMF", "CMF", 50, 54),
      L("RMF", "CMF", 78, 52),
      L("LWF", "AMF", 38, 32),
      L("RWF", "AMF", 62, 32),
      L("CF", "CF", 50, 12),
    ],
  },
  "4-3-1-2": {
    id: "4-3-1-2",
    group: "Back-4",
    name: "4-3-1-2",
    description: "Central overload with AMF link play",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "CMF", 22, 52),
      L("CMF", "CMF", 50, 54),
      L("RMF", "CMF", 78, 52),
      L("LWF", "AMF", 50, 34),
      L("RWF", "SS", 38, 18),
      L("CF", "CF", 62, 18),
    ],
  },
  "4-2-3-1": {
    id: "4-2-3-1",
    group: "Back-4",
    name: "4-2-3-1",
    description: "Flexible, wide or central transitions",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "DMF", 38, 54),
      L("RMF", "DMF", 62, 54),
      L("LWF", "LWF", 18, 32),
      L("CMF", "AMF", 50, 36),
      L("RWF", "RWF", 82, 32),
      L("CF", "CF", 50, 12),
    ],
  },
  "4-2-1-3": {
    id: "4-2-1-3",
    group: "Back-4",
    name: "4-2-1-3",
    description: "Defensive midfield cover + structured buildup",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("LMF", "DMF", 38, 56),
      L("RMF", "DMF", 62, 56),
      L("CMF", "AMF", 50, 40),
      L("LWF", "LWF", 22, 20),
      L("CF", "CF", 50, 12),
      L("RWF", "RWF", 78, 20),
    ],
  },
  "4-1-4-1": {
    id: "4-1-4-1",
    group: "Back-4",
    name: "4-1-4-1",
    description: "Strong defensive block with a single pivot",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("CMF", "DMF", 50, 56),
      L("LMF", "LMF", 14, 42),
      L("LWF", "CMF", 38, 44),
      L("RMF", "CMF", 62, 44),
      L("RWF", "RMF", 86, 42),
      L("CF", "CF", 50, 14),
    ],
  },
  "4-1-2-3": {
    id: "4-1-2-3",
    group: "Back-4",
    name: "4-1-2-3",
    description: "Aggressive, high-pressing, forward-loaded variant",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LB", 12, 68),
      L("CB1", "CB", 36, 72),
      L("CB2", "CB", 64, 72),
      L("RB", "RB", 88, 68),
      L("CMF", "DMF", 50, 56),
      L("LMF", "CMF", 36, 44),
      L("RMF", "CMF", 64, 44),
      L("LWF", "LWF", 22, 20),
      L("CF", "CF", 50, 12),
      L("RWF", "RWF", 78, 20),
    ],
  },
  "3-4-3": {
    id: "3-4-3",
    group: "Back-3",
    name: "3-4-3",
    description: "Wide, attacking, wing-driven",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("LB", "LMF", 14, 48),
      L("LMF", "CMF", 38, 50),
      L("RMF", "CMF", 62, 50),
      L("RWF", "RMF", 86, 48),
      L("LWF", "LWF", 22, 20),
      L("CF", "CF", 50, 12),
      L("CMF", "RWF", 78, 20),
    ],
  },
  "3-2-4-1": {
    id: "3-2-4-1",
    group: "Back-3",
    name: "3-2-4-1",
    description: "Midfield dominance, possession-heavy",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("LMF", "DMF", 38, 54),
      L("RMF", "DMF", 62, 54),
      L("LB", "LMF", 14, 42),
      L("LWF", "CMF", 36, 42),
      L("CMF", "CMF", 50, 44),
      L("RWF", "RMF", 86, 42),
      L("CF", "CF", 50, 14),
    ],
  },
  "3-2-3-2": {
    id: "3-2-3-2",
    group: "Back-3",
    name: "3-2-3-2",
    description: "Balanced, with wide attacking options",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("LMF", "CMF", 38, 50),
      L("RMF", "CMF", 62, 50),
      L("LB", "LWF", 18, 30),
      L("CMF", "AMF", 50, 34),
      L("RWF", "RWF", 82, 30),
      L("LWF", "CF", 38, 16),
      L("CF", "CF", 62, 16),
    ],
  },
  "3-1-4-2": {
    id: "3-1-4-2",
    group: "Back-3",
    name: "3-1-4-2",
    description: "Central play, requires high-stamina wide mids",
    slots: [
      L("GK", "GK", 50, 86),
      L("CB1", "CB", 28, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 72, 72),
      L("CMF", "DMF", 50, 54),
      L("LB", "LMF", 12, 42),
      L("LMF", "CMF", 36, 44),
      L("RMF", "CMF", 64, 44),
      L("RWF", "RMF", 88, 42),
      L("LWF", "CF", 38, 16),
      L("CF", "CF", 62, 16),
    ],
  },
  "5-3-2": {
    id: "5-3-2",
    group: "Back-5",
    name: "5-3-2",
    description: "Very solid defensively, counter-attack friendly",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LWB", 8, 58),
      L("CB1", "CB", 30, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 70, 72),
      L("RWF", "RWB", 92, 58),
      L("LMF", "CMF", 30, 46),
      L("CMF", "CMF", 50, 48),
      L("RMF", "CMF", 70, 46),
      L("LWF", "CF", 38, 16),
      L("CF", "CF", 62, 16),
    ],
  },
  "5-2-2-1": {
    id: "5-2-2-1",
    group: "Back-5",
    name: "5-2-2-1",
    description: "Defensive with wide counter-attacking threat",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LWB", 8, 58),
      L("CB1", "CB", 30, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 70, 72),
      L("RWF", "RWB", 92, 58),
      L("LMF", "CMF", 38, 48),
      L("RMF", "CMF", 62, 48),
      L("LWF", "AMF", 32, 30),
      L("CMF", "AMF", 68, 30),
      L("CF", "CF", 50, 12),
    ],
  },
  "5-2-1-2": {
    id: "5-2-1-2",
    group: "Back-5",
    name: "5-2-1-2",
    description: "Compact, central counter-attacking shape",
    slots: [
      L("GK", "GK", 50, 86),
      L("LB", "LWB", 8, 58),
      L("CB1", "CB", 30, 72),
      L("CB2", "CB", 50, 74),
      L("RB", "CB", 70, 72),
      L("RWF", "RWB", 92, 58),
      L("LMF", "CMF", 38, 48),
      L("RMF", "CMF", 62, 48),
      L("CMF", "AMF", 50, 34),
      L("LWF", "CF", 38, 16),
      L("CF", "CF", 62, 16),
    ],
  },
};

export const DEFAULT_FORMATION_ID = "4-3-3";

export const PITCH_SLOT_IDS = [
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

/** Singular positions only — tap a marker to pick from these. */
/** GPSL mirroring — paired roles must appear together on the pitch. */
export const MIRROR_LABEL_PAIRS = [
  ["LB", "RB"],
  ["LMF", "RMF"],
  ["LWF", "RWF"],
];

export const PITCH_LABEL_PRESETS = [
  "GK",
  "LB",
  "CB",
  "RB",
  "LWB",
  "RWB",
  "DMF",
  "CMF",
  "AMF",
  "LMF",
  "RMF",
  "LW",
  "RW",
  "LWF",
  "RWF",
  "SS",
  "CF",
];

export const FORMATION_LIST = FORMATION_GROUP_ORDER.flatMap((group) =>
  Object.values(MATCHDAY_FORMATIONS)
    .filter((f) => f.group === group)
    .map((f) => ({
      id: f.id,
      name: f.description ? `${f.name} — ${f.description}` : f.name,
      group,
    }))
);

export function formationDisplayName(formation) {
  return formation.description
    ? `${formation.name} — ${formation.description}`
    : formation.name;
}

export function countPitchLabels(slotLabels) {
  const counts = {};
  for (const slotId of PITCH_SLOT_IDS) {
    const label = String(slotLabels[slotId] || "").trim().toUpperCase();
    if (!label) continue;
    counts[label] = (counts[label] || 0) + 1;
  }
  return counts;
}

/** Validate GPSL mirroring rules for a custom pitch layout. */
export function validateFormationMirroring(slotLabels) {
  const counts = countPitchLabels(slotLabels);
  const has = (label) => (counts[label] || 0) > 0;
  const errors = [];

  for (const [left, right] of MIRROR_LABEL_PAIRS) {
    if (has(left) && !has(right)) {
      errors.push(`Mirroring: ${left} requires ${right}.`);
    }
    if (has(right) && !has(left)) {
      errors.push(`Mirroring: ${right} requires ${left}.`);
    }
  }

  const cfSsCount = (counts.CF || 0) + (counts.SS || 0);
  if (cfSsCount > 2) {
    errors.push(
      `Mirroring: only 2 CF/SS roles allowed combined (you have ${cfSsCount}).`
    );
  }

  return {
    ok: errors.length === 0,
    errors,
    message: errors.join(" "),
  };
}

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

function clampPct(n) {
  return Math.min(96, Math.max(4, Number(n) || 0));
}

/** Parse pitch_layout from DB (jsonb object or JSON string). */
export function normalizePitchLayout(raw) {
  if (raw == null) return null;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (typeof raw !== "object" || Array.isArray(raw)) return null;
  return raw;
}

export function pitchLayoutHasSlots(raw) {
  const saved = normalizePitchLayout(raw);
  if (!saved) return false;
  return PITCH_SLOT_IDS.some((id) => saved[id] != null);
}

/** Merge saved layout over template defaults (saved wins for each slot). */
export function resolvePitchLayout(saved, fallbackFormationId = DEFAULT_FORMATION_ID) {
  const layout = normalizePitchLayout(saved);
  const hasSaved = layout && PITCH_SLOT_IDS.some((id) => layout[id] != null);

  const formationId =
    layout?.formation_id ||
    (hasSaved ? "custom" : fallbackFormationId);

  const base = formationLayout(
    formationId === "custom" ? fallbackFormationId : formationId
  );
  const positions = { ...base.positions };
  const labels = { ...base.labels };

  if (hasSaved) {
    for (const slotId of PITCH_SLOT_IDS) {
      const s = layout[slotId];
      if (!s || typeof s !== "object") continue;
      if (s.x != null && s.y != null) {
        positions[slotId] = {
          x: clampPct(s.x),
          y: clampPct(s.y),
        };
      }
      if (s.label) labels[slotId] = String(s.label);
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
