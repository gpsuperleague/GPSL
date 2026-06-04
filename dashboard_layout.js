import {
  DEFAULT_DASHBOARD_PANEL_IDS,
  getDashboardPanel,
} from "./dashboard_registry.js";

const TABLE = "owner_dashboard_layout";

export async function loadOwnerDashboardLayout(supabase, ownerId) {
  const { data, error } = await supabase
    .from(TABLE)
    .select("panel_ids")
    .eq("owner_id", ownerId)
    .maybeSingle();

  if (error) throw error;

  const raw = normalizePanelIdsFromDb(data?.panel_ids);
  if (!raw.length) {
    return [...DEFAULT_DASHBOARD_PANEL_IDS];
  }

  const ids = sanitizePanelIds(raw);
  return ids.length ? ids : [...DEFAULT_DASHBOARD_PANEL_IDS];
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

export async function saveOwnerDashboardLayout(supabase, ownerId, panelIds) {
  const ids = sanitizePanelIds(panelIds);
  const { error } = await supabase.from(TABLE).upsert(
    {
      owner_id: ownerId,
      panel_ids: ids,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "owner_id" }
  );

  if (error) throw error;
  return ids;
}

export async function isPanelOnDashboard(supabase, ownerId, panelId) {
  const ids = await loadOwnerDashboardLayout(supabase, ownerId);
  return ids.includes(panelId);
}

export async function setPanelOnDashboard(supabase, ownerId, panelId, onDashboard) {
  let ids = await loadOwnerDashboardLayout(supabase, ownerId);
  const has = ids.includes(panelId);

  if (onDashboard && !has) {
    ids = [...ids, panelId];
  } else if (!onDashboard && has) {
    ids = ids.filter((id) => id !== panelId);
  }

  return saveOwnerDashboardLayout(supabase, ownerId, ids);
}

export async function togglePanelOnDashboard(supabase, ownerId, panelId) {
  const ids = await loadOwnerDashboardLayout(supabase, ownerId);
  const on = ids.includes(panelId);
  if (on) {
    return saveOwnerDashboardLayout(
      supabase,
      ownerId,
      ids.filter((id) => id !== panelId)
    );
  }
  return saveOwnerDashboardLayout(supabase, ownerId, [...ids, panelId]);
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
