// GPDB scouting shortlist — tiered targets per club

const SQL_SETUP_HINT =
  "Run supabase/sql/patches/club_scouting_targets.sql in the Supabase SQL Editor, then reload.";

export const SCOUTING_TIER_LABELS = {
  1: "Top targets",
  2: "Backup targets",
  3: "Third choice",
  4: "Fourth choice",
};

let scoutingSchemaMissing = false;

function isScoutingSchemaMissingError(error) {
  if (!error) return false;
  if (error.code === "PGRST205" || error.code === "42P01") return true;
  const msg = String(error.message || "");
  return (
    msg.includes("club_scouting_targets") ||
    msg.includes("scouting_toggle_target")
  );
}

export function isScoutingAvailable() {
  return !scoutingSchemaMissing;
}

export function scoutingSetupHint() {
  return SQL_SETUP_HINT;
}

export function scoutingStarChar(isScouted) {
  return isScouted ? "★" : "☆";
}

export async function loadScoutingTargets(supabase, clubShortName) {
  if (!clubShortName) return [];

  const { data, error } = await supabase
    .from("club_scouting_targets")
    .select("player_id, tier, sort_order, created_at")
    .eq("club_id", clubShortName)
    .order("tier")
    .order("sort_order")
    .order("created_at");

  if (error) {
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      return [];
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return data || [];
}

export async function loadScoutingTargetMap(supabase, clubShortName) {
  const rows = await loadScoutingTargets(supabase, clubShortName);
  const map = new Map();
  for (const row of rows) {
    map.set(String(row.player_id), Number(row.tier) || 1);
  }
  return map;
}

export async function toggleScoutingTarget(supabase, playerId, tier = 1) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("scouting_toggle_target", {
    p_player_id: String(playerId),
    p_tier: tier,
  });

  if (error) {
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return data?.scouted === true;
}

export async function setScoutingTargetTier(supabase, playerId, tier) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("scouting_set_target_tier", {
    p_player_id: String(playerId),
    p_tier: tier,
  });

  if (error) {
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return data;
}

export async function loadScoutingPlannerState(supabase, clubShortName) {
  if (!clubShortName) {
    return { pitchLayout: null, rows: [] };
  }

  const [layoutRes, rowsRes] = await Promise.all([
    supabase
      .from("club_scouting_planner")
      .select("pitch_layout")
      .eq("club_short_name", clubShortName)
      .maybeSingle(),
    supabase
      .from("club_scouting_planner_player")
      .select("player_id, slot_kind, pitch_slot, sort_order")
      .eq("club_short_name", clubShortName)
      .order("slot_kind")
      .order("sort_order"),
  ]);

  if (layoutRes.error && isScoutingSchemaMissingError(layoutRes.error)) {
    scoutingSchemaMissing = true;
    return { pitchLayout: null, rows: [] };
  }
  if (rowsRes.error && isScoutingSchemaMissingError(rowsRes.error)) {
    scoutingSchemaMissing = true;
    return { pitchLayout: null, rows: [] };
  }

  if (layoutRes.error) throw layoutRes.error;
  if (rowsRes.error) throw rowsRes.error;

  scoutingSchemaMissing = false;
  return {
    pitchLayout: layoutRes.data?.pitch_layout ?? null,
    rows: rowsRes.data || [],
  };
}

export async function saveScoutingPlanner(supabase, slots, pitchLayout) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("club_save_scouting_planner", {
    p_slots: slots,
    p_pitch_layout: pitchLayout,
  });

  if (error) {
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return data;
}
