/**
 * Keep GK fully on the green. Cap depth so centred cards don't spill off the bottom.
 */
export function spaceGkFromDefenders(positions, minGap = 14) {
  if (!positions || typeof positions !== "object") return positions;
  const gk = positions.GK;
  if (!gk || gk.y == null) return positions;

  const out = { ...positions };
  // 80% leaves room below the card centre for ~half a compact card
  let gkY = Math.min(Number(gk.y), 80);
  out.GK = { ...gk, y: clampPct(gkY) };

  const gkX = Number(gk.x) || 50;
  for (const [id, p] of Object.entries(out)) {
    if (id === "GK" || !p || p.y == null) continue;
    const y = Number(p.y);
    const x = Number(p.x) || 50;
    if (y < 52) continue;
    const central = Math.abs(x - gkX) <= 22;
    const needed = central ? minGap : Math.max(10, minGap - 3);
    const gap = gkY - y;
    if (gap >= needed) continue;
    out[id] = { ...p, y: clampPct(y - (needed - gap)) };
  }
  return out;
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

  return {
    formationId,
    positions: spaceGkFromDefenders(positions),
    labels,
  };
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
