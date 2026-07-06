import {
  DEFAULT_DASHBOARD_PANEL_IDS,
  getDashboardPanel,
} from "./dashboard_registry.js";

const TABLE = "owner_dashboard_layout";

export const DEFAULT_SECTION_TITLE = "Shortcuts";

/** Sensible default groups for owners who have not customised yet. */
export const DEFAULT_DASHBOARD_SECTIONS = [
  {
    id: "def_club",
    title: "My club",
    panelIds: ["club_details", "stadium", "history"],
  },
  {
    id: "def_squad",
    title: "Squad & transfers",
    panelIds: ["squad", "transfer_center"],
  },
  {
    id: "def_match",
    title: "Match day",
    panelIds: ["matchday", "club_fixtures", "fixtures"],
  },
  {
    id: "def_comp",
    title: "Competition",
    panelIds: ["progress", "league_stats", "cups", "world_cup"],
  },
  {
    id: "def_fin",
    title: "Finances",
    panelIds: ["finances", "central_bank"],
  },
];

export function createDashboardSectionId() {
  return `sec_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`;
}

export function createDashboardSection(title = DEFAULT_SECTION_TITLE, panelIds = []) {
  return {
    id: createDashboardSectionId(),
    title: title || DEFAULT_SECTION_TITLE,
    panelIds: sanitizePanelIds(panelIds),
  };
}

export function flattenPanelIds(sections) {
  const seen = new Set();
  const out = [];
  for (const sec of sections || []) {
    for (const id of sec.panelIds || []) {
      if (typeof id !== "string" || seen.has(id) || !getDashboardPanel(id)) continue;
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

export function sanitizeSections(sections) {
  const seen = new Set();
  const out = [];

  for (const raw of sections || []) {
    if (!raw || typeof raw !== "object") continue;
    const id =
      typeof raw.id === "string" && raw.id.trim()
        ? raw.id.trim()
        : createDashboardSectionId();
    const title =
      typeof raw.title === "string" && raw.title.trim()
        ? raw.title.trim().slice(0, 48)
        : DEFAULT_SECTION_TITLE;
    const panelIds = [];
    for (const panelId of raw.panelIds || []) {
      if (typeof panelId !== "string" || seen.has(panelId) || !getDashboardPanel(panelId)) {
        continue;
      }
      seen.add(panelId);
      panelIds.push(panelId);
    }
    out.push({ id, title, panelIds });
  }

  return out;
}

export function sectionsFromPanelIds(panelIds) {
  const ids = sanitizePanelIds(panelIds);
  if (!ids.length) return cloneDefaultSections();
  return [createDashboardSection(DEFAULT_SECTION_TITLE, ids)];
}

export function cloneDefaultSections() {
  return DEFAULT_DASHBOARD_SECTIONS.map((sec) => ({
    id: sec.id,
    title: sec.title,
    panelIds: [...sec.panelIds],
  }));
}

export async function loadOwnerDashboardLayout(supabase, ownerId) {
  const { data, error } = await supabase
    .from(TABLE)
    .select("panel_ids, sections")
    .eq("owner_id", ownerId)
    .maybeSingle();

  if (error) throw error;

  const rawSections = normalizeSectionsFromDb(data?.sections);
  if (rawSections.length) {
    const sections = sanitizeSections(rawSections);
    if (sections.length) return sections;
  }

  const rawPanelIds = normalizePanelIdsFromDb(data?.panel_ids);
  if (rawPanelIds.length) {
    return sectionsFromPanelIds(rawPanelIds);
  }

  return cloneDefaultSections();
}

export async function saveOwnerDashboardLayout(supabase, ownerId, sections) {
  const cleaned = sanitizeSections(sections);
  const panelIds = flattenPanelIds(cleaned);
  const { error } = await supabase.from(TABLE).upsert(
    {
      owner_id: ownerId,
      panel_ids: panelIds,
      sections: cleaned,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "owner_id" }
  );

  if (error) throw error;
  return cleaned;
}

export async function isPanelOnDashboard(supabase, ownerId, panelId) {
  const sections = await loadOwnerDashboardLayout(supabase, ownerId);
  return flattenPanelIds(sections).includes(panelId);
}

export async function setPanelOnDashboard(supabase, ownerId, panelId, onDashboard) {
  let sections = await loadOwnerDashboardLayout(supabase, ownerId);
  const flat = flattenPanelIds(sections);
  const has = flat.includes(panelId);

  if (onDashboard && !has) {
    if (!sections.length) sections = [createDashboardSection()];
    const last = sections[sections.length - 1];
    last.panelIds = [...last.panelIds, panelId];
  } else if (!onDashboard && has) {
    sections = sections.map((sec) => ({
      ...sec,
      panelIds: sec.panelIds.filter((id) => id !== panelId),
    }));
  }

  return saveOwnerDashboardLayout(supabase, ownerId, sections);
}

export async function togglePanelOnDashboard(supabase, ownerId, panelId) {
  const sections = await loadOwnerDashboardLayout(supabase, ownerId);
  const on = flattenPanelIds(sections).includes(panelId);
  return setPanelOnDashboard(supabase, ownerId, panelId, !on);
}

function normalizeSectionsFromDb(raw) {
  if (raw == null) return [];
  if (Array.isArray(raw)) return raw;
  if (typeof raw === "string") {
    const s = raw.trim();
    if (s.startsWith("[") && s.endsWith("]")) {
      try {
        const parsed = JSON.parse(s);
        if (Array.isArray(parsed)) return parsed;
      } catch (_) {
        /* fall through */
      }
    }
  }
  return [];
}

/** Postgres text[] sometimes arrives as a string — normalize for JS. */
function normalizePanelIdsFromDb(raw) {
  if (raw == null) return [];
  if (Array.isArray(raw)) return raw;

  if (typeof raw === "string") {
    const s = raw.trim();
    if (s.startsWith("[") && s.endsWith("]")) {
      try {
        const parsed = JSON.parse(s);
        if (Array.isArray(parsed)) return parsed;
      } catch (_) {
        /* fall through */
      }
    }
    if (s.startsWith("{") && s.endsWith("}")) {
      const inner = s.slice(1, -1).trim();
      if (!inner) return [];
      return inner.split(",").map((id) => id.trim().replace(/^"|"$/g, ""));
    }
  }

  return [];
}

function sanitizePanelIds(ids) {
  const seen = new Set();
  const out = [];
  for (const id of ids) {
    if (typeof id !== "string" || seen.has(id) || !getDashboardPanel(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}
