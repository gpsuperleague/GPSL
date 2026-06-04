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

  const raw = data?.panel_ids;
  if (!Array.isArray(raw) || raw.length === 0) {
    return [...DEFAULT_DASHBOARD_PANEL_IDS];
  }

  return sanitizePanelIds(raw);
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
