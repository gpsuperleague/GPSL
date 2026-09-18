/**
 * GPSL formations catalogue (eFootball-style).
 * Prefers admin-owned formations from Supabase whenever enabled rows exist;
 * otherwise falls back to hardcoded Match Day presets.
 *
 * Global rule: CF + SS combined ≤ 2 (no CF/CF/SS).
 * Owner pitch layouts always enforce GPSL mirroring.
 */

import { supabase } from "./global.js";
import {
  MATCHDAY_FORMATIONS,
  DEFAULT_FORMATION_ID,
  FORMATION_GROUP_ORDER,
  getFormation as getHardcodedFormation,
  formationDisplayName as hardcodedDisplayName,
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
  if (cache.loaded && !force) return cache;
  try {
    const { data, error } = await supabase.rpc("gpsl_formations_list", {
      p_enabled_only: false,
    });
    if (error) throw error;
    cache = {
      settings: data?.settings || cache.settings,
      formations: Array.isArray(data?.formations) ? data.formations : [],
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
      formations: [],
    };
  }
  return cache;
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
      allowRelabel: true,
      allowedPositions: GPSL_POSITIONS.filter(
        (p) => p !== "GK" || s.label === "GK"
      ),
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

/**
 * Validate owner pitch labels against formation slot rules + CF/SS cap.
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

/** Allowed role options for a slot (for click-to-change UI). */
export function slotRoleOptions(formation, slotId) {
  const slot = formation?.slots?.find((s) => s.id === slotId);
  if (!slot) return GPSL_POSITIONS.filter((p) => p !== "GK");
  if (slot.label === "GK") return ["GK"];
  if (!slot.allowRelabel) return [slot.label];
  const allowed = (slot.allowedPositions || []).filter(Boolean);
  if (!allowed.length) return [slot.label];
  return allowed;
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
