/**
 * GPSL formations catalogue (eFootball-style).
 * Prefers admin-owned formations from Supabase whenever enabled rows exist;
 * otherwise falls back to hardcoded Match Day presets.
 *
 * Global rules (hard-coded):
 *   · CF + SS combined ≤ 2 (no CF/CF/SS)
 *   · DMF ≤ 2
 *   · AMF ≤ 2
 * Owner pitch layouts always enforce GPSL mirroring.
 */

import { supabase } from "./global.js";
import {
  MATCHDAY_FORMATIONS,
  DEFAULT_FORMATION_ID,
  FORMATION_GROUP_ORDER,
  PITCH_SLOT_IDS,
  getFormation as getHardcodedFormation,
  formationDisplayName as hardcodedDisplayName,
  formationLayout,
  normalizePitchLayout,
  spaceGkFromDefenders,
  validateFormationMirroring,
} from "./matchday_formations.js";

export const GPSL_POSITIONS = [
  "GK",
  "CB",
  "LB",
  "RB",
  "LWB",
  "RWB",
  "DMF",
  "CMF",
  "AMF",
  "LMF",
  "RMF",
  "LWF",
  "RWF",
  "SS",
  "CF",
];

/** Hard league caps for pitch role labels (not configurable). */
export const MAX_DMF_ON_PITCH = 2;
export const MAX_AMF_ON_PITCH = 2;

/** @type {{ settings: object, formations: object[], positions: string[], loaded: boolean, error: string|null }} */
let cache = {
  settings: {
    catalogue_live: false,
    enforce_mirroring: true,
    max_cf_ss: 2,
  },
  formations: [],
  positions: GPSL_POSITIONS,
  loaded: false,
  error: null,
};

export function getFormationsCache() {
  return cache;
}

export async function loadGpslFormations({ force = false } = {}) {
  // Retry when a prior attempt failed or returned no rows (e.g. called before auth).
  if (cache.loaded && !force && !cache.error && cache.formations.length) {
    return cache;
  }
  try {
    const { data, error } = await supabase.rpc("gpsl_formations_list", {
      p_enabled_only: false,
    });
    if (error) throw error;
    const formations = Array.isArray(data?.formations) ? data.formations : [];
    cache = {
      settings: data?.settings || cache.settings,
      formations,
      positions: Array.isArray(data?.positions) ? data.positions : GPSL_POSITIONS,
      loaded: true,
      error: null,
    };
  } catch (err) {
    console.warn("gpsl_formations_list unavailable — using hardcoded presets", err);
    cache = {
      ...cache,
      loaded: true,
      error: err?.message || String(err),
      // Keep any previously successful rows; only clear on hard empty miss
      formations: cache.formations?.length ? cache.formations : [],
    };
  }
  return cache;
}

/** True when Match Day is using admin catalogue rows (not hardcoded presets). */
export function isUsingCatalogueFormations() {
  return (cache.formations || []).some((f) => f.is_enabled);
}

export function isCatalogueLive() {
  return !!cache.settings?.catalogue_live;
}

export function enforceMirroring() {
  // Match Day always mirrors; setting kept for admin UI / future toggles
  return cache.settings?.enforce_mirroring !== false;
}

export function maxCfSs() {
  const n = Number(cache.settings?.max_cf_ss);
  return Number.isFinite(n) ? n : 2;
}

function mapCatalogueFormation(f) {
  return {
    id: f.code,
    code: f.code,
    name: f.name,
    description: f.description || "",
    group: f.group_label || "General",
    formationId: f.id,
    slots: (f.slots || []).map((s) => ({
      id: s.slot_key,
      label: s.default_position,
      x: Number(s.x),
      y: Number(s.y),
      allowRelabel: !!s.allow_relabel,
      allowedPositions: Array.isArray(s.allowed_positions)
        ? s.allowed_positions
        : [s.default_position],
    })),
  };
}

function mapHardcodedFormation(f) {
  // Without catalogue rows, lock each slot to its default label.
  // Free "any role" picking is admin-catalogue only.
  return {
    id: f.id,
    code: f.id,
    name: f.name,
    description: f.description || "",
    group: f.group,
    formationId: null,
    slots: f.slots.map((s) => ({
      id: s.id,
      label: s.label,
      x: s.x,
      y: s.y,
      allowRelabel: false,
      allowedPositions: [s.label],
    })),
  };
}

/**
 * Prefer admin catalogue whenever any enabled formation exists
 * (so role locks / allowed positions apply on Match Day without a separate "live" flip).
 */
export function listSelectableFormations() {
  const enabled = (cache.formations || []).filter((f) => f.is_enabled);
  if (enabled.length) return enabled.map(mapCatalogueFormation);
  return Object.values(MATCHDAY_FORMATIONS).map(mapHardcodedFormation);
}

export function getSelectableFormation(codeOrId) {
  const list = listSelectableFormations();
  return (
    list.find((f) => f.id === codeOrId || f.code === codeOrId) ||
    list.find((f) => f.id === DEFAULT_FORMATION_ID) ||
    list[0] ||
    null
  );
}

export function formationPickerGroups() {
  const list = listSelectableFormations();
  const groups = [];
  const seen = new Set();
  const fromCatalogue = (cache.formations || []).some((f) => f.is_enabled);
  const prefer = fromCatalogue
    ? [...new Set(list.map((f) => f.group))]
    : FORMATION_GROUP_ORDER;
  for (const g of prefer) {
    const items = list.filter((f) => f.group === g);
    if (items.length) {
      groups.push({ group: g, formations: items });
      seen.add(g);
    }
  }
  for (const f of list) {
    if (seen.has(f.group)) continue;
    const items = list.filter((x) => x.group === f.group);
    groups.push({ group: f.group, formations: items });
    seen.add(f.group);
  }
  return groups;
}

export function formationLabel(f) {
  if (!f) return "";
  return f.description ? `${f.name} — ${f.description}` : f.name;
}

export function countCfSs(slotLabels) {
  let n = 0;
  for (const v of Object.values(slotLabels || {})) {
    const p = String(v || "")
      .trim()
      .toUpperCase();
    if (p === "CF" || p === "SS") n += 1;
  }
  return n;
}

export function countPitchRole(slotLabels, role) {
  const want = String(role || "")
    .trim()
    .toUpperCase();
  if (!want) return 0;
  let n = 0;
  for (const v of Object.values(slotLabels || {})) {
    if (
      String(v || "")
        .trim()
        .toUpperCase() === want
    ) {
      n += 1;
    }
  }
  return n;
}

/**
 * If applying `newLabel` on `slotId` would breach DMF/AMF (or CF+SS) caps, return an error message.
 * Otherwise return null.
 */
export function pitchRoleChangeBlockedReason(slotLabels, slotId, newLabel) {
  const next = { ...(slotLabels || {}) };
  const key = String(slotId || "").trim();
  if (!key) return "Invalid pitch slot.";
  next[key] = String(newLabel || "")
    .trim()
    .toUpperCase();

  const maxCf = maxCfSs();
  const cfSs = countCfSs(next);
  if (cfSs > maxCf) {
    return `Cannot set ${next[key]} — CF + SS combined must be ≤ ${maxCf} (would be ${cfSs}).`;
  }

  const dmf = countPitchRole(next, "DMF");
  if (dmf > MAX_DMF_ON_PITCH) {
    return `Cannot set DMF — no more than ${MAX_DMF_ON_PITCH} DMFs on the pitch (you would have ${dmf}). This breaches Match Day rules.`;
  }

  const amf = countPitchRole(next, "AMF");
  if (amf > MAX_AMF_ON_PITCH) {
    return `Cannot set AMF — no more than ${MAX_AMF_ON_PITCH} AMFs on the pitch (you would have ${amf}). This breaches Match Day rules.`;
  }

  return null;
}

/**
 * Validate owner pitch labels against formation slot rules + CF/SS + DMF/AMF caps.
 * Always applies GPSL mirroring (LB↔RB, LMF↔RMF, LWF↔RWF).
 */
export function validateOwnerPitchLabels(formation, slotLabels) {
  const errors = [];
  const labels = slotLabels || {};
  const max = maxCfSs();
  const cfSs = countCfSs(labels);
  if (cfSs > max) {
    errors.push(
      `CF + SS combined must be ≤ ${max} (you have ${cfSs}). CF/CF/SS is not allowed.`
    );
  }

  const dmf = countPitchRole(labels, "DMF");
  if (dmf > MAX_DMF_ON_PITCH) {
    errors.push(
      `No more than ${MAX_DMF_ON_PITCH} DMFs on the pitch (you have ${dmf}).`
    );
  }
  const amf = countPitchRole(labels, "AMF");
  if (amf > MAX_AMF_ON_PITCH) {
    errors.push(
      `No more than ${MAX_AMF_ON_PITCH} AMFs on the pitch (you have ${amf}).`
    );
  }

  if (formation?.slots?.length) {
    for (const slot of formation.slots) {
      const current = String(labels[slot.id] || "")
        .trim()
        .toUpperCase();
      if (!current) continue;
      if (!slot.allowRelabel) {
        if (current !== String(slot.label).toUpperCase()) {
          errors.push(
            `${slot.id}: role is locked to ${slot.label} for this formation.`
          );
        }
        continue;
      }
      const allowed = (slot.allowedPositions || []).map((p) =>
        String(p).toUpperCase()
      );
      if (allowed.length && !allowed.includes(current)) {
        errors.push(
          `${slot.id}: ${current} is not allowed (permitted: ${allowed.join(", ")}).`
        );
      }
    }
  }

  const mirror = validateFormationMirroring(labels);
  if (!mirror.ok) errors.push(...(mirror.errors || [mirror.message]));

  return {
    ok: errors.length === 0,
    errors,
    message: errors.join(" "),
  };
}

/**
 * Allowed role options for a slot (click-to-change UI).
 * Never expands to the full position list — unknown slots stay locked.
 */
export function slotRoleOptions(formation, slotId, currentLabel = null) {
  const slot = formation?.slots?.find(
    (s) => String(s.id).toUpperCase() === String(slotId || "").toUpperCase()
  );
  const fallback = String(currentLabel || slotId || "")
    .trim()
    .toUpperCase();
  if (!slot) return fallback ? [fallback] : [];
  if (String(slot.label).toUpperCase() === "GK") return ["GK"];
  if (!slot.allowRelabel) return [slot.label];
  const allowed = (slot.allowedPositions || [])
    .map((p) => String(p || "").trim())
    .filter(Boolean);
  // Default role is always permitted when relabel is on
  const def = String(slot.label || "").trim();
  if (def && !allowed.some((p) => p.toUpperCase() === def.toUpperCase())) {
    allowed.unshift(def);
  }
  if (!allowed.length) return def ? [def] : fallback ? [fallback] : [];
  return [...new Set(allowed)];
}

/**
 * Template marker positions + default labels for a formation code.
 * Prefers admin catalogue when enabled rows exist.
 */
export function getFormationTemplateLayout(formationId) {
  const sel = getSelectableFormation(formationId);
  if (!sel?.slots?.length) return null;
  const positions = {};
  const labels = {};
  for (const s of sel.slots) {
    const id = String(s.id || "").trim();
    if (!id) continue;
    positions[id] = {
      x: Number(s.x),
      y: Number(s.y),
    };
    labels[id] = s.label || id;
  }
  return {
    formationId: sel.id,
    positions,
    labels,
    fromCatalogue: isUsingCatalogueFormations(),
  };
}

/**
 * Clamp marker % coords. When catalogue is active, do NOT run spaceGkFromDefenders —
 * admin spacing is the source of truth.
 */
export function finalizeTemplatePositions(positions) {
  if (!positions || typeof positions !== "object") return positions;
  const out = {};
  for (const [id, p] of Object.entries(positions)) {
    if (!p || typeof p !== "object") continue;
    out[id] = {
      x: Math.min(96, Math.max(4, Number(p.x) || 0)),
      y: Math.min(96, Math.max(4, Number(p.y) || 0)),
    };
  }
  if (isUsingCatalogueFormations()) return out;
  return spaceGkFromDefenders(out);
}

/**
 * Resolve saved pitch for Match Day:
 * · Roles (labels) keep owner overrides from saved layout
 * · Marker x/y always refresh from the current formation template
 *   (owners cannot free-drag; Admin Formations catalogue owns spacing)
 */
export function resolveMatchdayPitchLayout(
  saved,
  fallbackFormationId = DEFAULT_FORMATION_ID
) {
  const layout = normalizePitchLayout(saved);
  const hasSaved = layout && PITCH_SLOT_IDS.some((id) => layout[id] != null);

  let formationId =
    layout?.formation_id ||
    (hasSaved ? "custom" : fallbackFormationId);

  if (formationId === "custom" || !formationId) {
    formationId = fallbackFormationId;
  }

  const template = getFormationTemplateLayout(formationId);
  const hardcoded = formationLayout(formationId);

  const positions = {
    ...(template?.positions || hardcoded.positions),
  };
  const labels = {
    ...(template?.labels || hardcoded.labels),
  };

  // Owner role overrides from last save (not coordinates)
  if (hasSaved) {
    for (const slotId of PITCH_SLOT_IDS) {
      const s = layout[slotId];
      if (!s || typeof s !== "object") continue;
      if (s.label) labels[slotId] = String(s.label);
    }
  }

  return {
    formationId: template?.formationId || hardcoded.formationId || formationId,
    positions: finalizeTemplatePositions(positions),
    labels,
  };
}

export function buildLayoutFromFormation(formation) {
  if (!formation) {
    const f = getHardcodedFormation(DEFAULT_FORMATION_ID);
    return buildLayoutFromFormation({
      id: f.id,
      slots: f.slots.map((s) => ({
        id: s.id,
        label: s.label,
        x: s.x,
        y: s.y,
      })),
    });
  }
  const out = { formation_id: formation.id || formation.code };
  for (const s of formation.slots || []) {
    out[s.id] = {
      x: Math.round(Number(s.x) * 10) / 10,
      y: Math.round(Number(s.y) * 10) / 10,
      label: s.label,
    };
  }
  return out;
}

export { hardcodedDisplayName, getHardcodedFormation, DEFAULT_FORMATION_ID };
