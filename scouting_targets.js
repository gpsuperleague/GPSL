// Owner scouting shortlist — tiered targets + tactic board (follows the owner)

const SQL_SETUP_HINT =
  "Run supabase/sql/patches/owner_scouting_persist.sql in the Supabase SQL Editor (after club_scouting_targets.sql), then reload.";

const ACTIVE_TARGET_SQL_HINT =
  "Run supabase/sql/patches/owner_scouting_active_targets.sql in the Supabase SQL Editor, then reload.";

const MULTI_BOARD_SQL_HINT =
  "Run supabase/sql/patches/owner_scouting_multi_boards_20260813.sql in the Supabase SQL Editor, then reload.";

export const SCOUTING_BOARD_COUNT = 4;
const BOARD_STORAGE_KEY = "gpsl_scouting_board_no";

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
    msg.includes("owner_scouting_targets") ||
    msg.includes("club_scouting_targets") ||
    msg.includes("scouting_toggle_target") ||
    msg.includes("owner_scouting_planner")
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

async function currentOwnerId(supabase) {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  return data?.user?.id || null;
}

/**
 * Load the signed-in owner's scouting shortlist.
 * @param {*} supabase
 * @param {string} [_clubShortName] ignored — kept for call-site compatibility
 */
export async function loadScoutingTargets(supabase, _clubShortName) {
  const ownerId = await currentOwnerId(supabase);
  if (!ownerId) return [];

  let { data, error } = await supabase
    .from("owner_scouting_targets")
    .select("player_id, tier, sort_order, created_at, is_active_target")
    .eq("owner_id", ownerId)
    .order("tier")
    .order("sort_order")
    .order("created_at");

  // Column may be missing until owner_scouting_active_targets.sql is deployed
  if (
    error &&
    (String(error.message || "").includes("is_active_target") ||
      error.code === "42703")
  ) {
    ({ data, error } = await supabase
      .from("owner_scouting_targets")
      .select("player_id, tier, sort_order, created_at")
      .eq("owner_id", ownerId)
      .order("tier")
      .order("sort_order")
      .order("created_at"));
    if (!error && data) {
      data = data.map((r) => ({ ...r, is_active_target: false }));
    }
  }

  if (error) {
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      return [];
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return (data || []).map((r) => ({
    ...r,
    is_active_target: r.is_active_target === true,
  }));
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

export async function setScoutingActiveTarget(supabase, playerId, active) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("scouting_set_active_target", {
    p_player_id: String(playerId),
    p_active: Boolean(active),
  });

  if (error) {
    if (
      String(error.message || "").includes("scouting_set_active_target") ||
      error.code === "PGRST202"
    ) {
      throw new Error(ACTIVE_TARGET_SQL_HINT);
    }
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  return data;
}

function clampBoardNo(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v < 1 || v > SCOUTING_BOARD_COUNT) return 1;
  return Math.trunc(v);
}

export function getStoredScoutingBoardNo() {
  try {
    return clampBoardNo(localStorage.getItem(BOARD_STORAGE_KEY));
  } catch {
    return 1;
  }
}

export function setStoredScoutingBoardNo(boardNo) {
  const n = clampBoardNo(boardNo);
  try {
    localStorage.setItem(BOARD_STORAGE_KEY, String(n));
  } catch {
    /* ignore */
  }
  return n;
}

function defaultBoardList() {
  return Array.from({ length: SCOUTING_BOARD_COUNT }, (_, i) => ({
    board_no: i + 1,
    name: `Board ${i + 1}`,
    updated_at: null,
  }));
}

/** Ensure Boards 1–4 exist; returns [{ board_no, name, updated_at }, …]. */
export async function ensureScoutingBoards(supabase) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("scouting_ensure_boards");

  if (error) {
    if (
      String(error.message || "").includes("scouting_ensure_boards") ||
      error.code === "PGRST202" ||
      error.code === "42883"
    ) {
      throw new Error(MULTI_BOARD_SQL_HINT);
    }
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  const list = Array.isArray(data) ? data : [];
  if (!list.length) return defaultBoardList();
  return list
    .map((r) => ({
      board_no: clampBoardNo(r.board_no),
      name: String(r.name || `Board ${clampBoardNo(r.board_no)}`).trim() ||
        `Board ${clampBoardNo(r.board_no)}`,
      updated_at: r.updated_at || null,
    }))
    .sort((a, b) => a.board_no - b.board_no);
}

export async function renameScoutingBoard(supabase, boardNo, name) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("scouting_rename_board", {
    p_board_no: clampBoardNo(boardNo),
    p_name: String(name || "").trim(),
  });

  if (error) {
    if (
      String(error.message || "").includes("scouting_rename_board") ||
      error.code === "PGRST202" ||
      error.code === "42883"
    ) {
      throw new Error(MULTI_BOARD_SQL_HINT);
    }
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  return data;
}

/**
 * @param {*} supabase
 * @param {string} [_clubShortName] ignored — kept for call-site compatibility
 * @param {number} [boardNo]
 */
export async function loadScoutingPlannerState(
  supabase,
  _clubShortName,
  boardNo = getStoredScoutingBoardNo()
) {
  const ownerId = await currentOwnerId(supabase);
  if (!ownerId) {
    return { pitchLayout: null, rows: [], boardNo: 1, name: "Board 1" };
  }

  const n = clampBoardNo(boardNo);

  const [layoutRes, rowsRes] = await Promise.all([
    supabase
      .from("owner_scouting_planner")
      .select("pitch_layout, name, board_no")
      .eq("owner_id", ownerId)
      .eq("board_no", n)
      .maybeSingle(),
    supabase
      .from("owner_scouting_planner_player")
      .select("player_id, slot_kind, pitch_slot, sort_order")
      .eq("owner_id", ownerId)
      .eq("board_no", n)
      .order("slot_kind")
      .order("sort_order"),
  ]);

  // Pre-multi-board schema: no board_no column — fall back to single planner
  if (
    layoutRes.error &&
    (String(layoutRes.error.message || "").includes("board_no") ||
      layoutRes.error.code === "42703")
  ) {
    const [legacyLayout, legacyRows] = await Promise.all([
      supabase
        .from("owner_scouting_planner")
        .select("pitch_layout")
        .eq("owner_id", ownerId)
        .maybeSingle(),
      supabase
        .from("owner_scouting_planner_player")
        .select("player_id, slot_kind, pitch_slot, sort_order")
        .eq("owner_id", ownerId)
        .order("slot_kind")
        .order("sort_order"),
    ]);
    if (legacyLayout.error && isScoutingSchemaMissingError(legacyLayout.error)) {
      scoutingSchemaMissing = true;
      return { pitchLayout: null, rows: [], boardNo: 1, name: "Board 1" };
    }
    if (legacyLayout.error) throw legacyLayout.error;
    if (legacyRows.error) throw legacyRows.error;
    return {
      pitchLayout: legacyLayout.data?.pitch_layout ?? null,
      rows: legacyRows.data || [],
      boardNo: 1,
      name: "Board 1",
      multiBoard: false,
    };
  }

  if (layoutRes.error && isScoutingSchemaMissingError(layoutRes.error)) {
    scoutingSchemaMissing = true;
    return { pitchLayout: null, rows: [], boardNo: n, name: `Board ${n}` };
  }
  if (rowsRes.error && isScoutingSchemaMissingError(rowsRes.error)) {
    scoutingSchemaMissing = true;
    return { pitchLayout: null, rows: [], boardNo: n, name: `Board ${n}` };
  }

  if (layoutRes.error) throw layoutRes.error;
  if (rowsRes.error) throw rowsRes.error;

  scoutingSchemaMissing = false;
  return {
    pitchLayout: layoutRes.data?.pitch_layout ?? null,
    rows: rowsRes.data || [],
    boardNo: n,
    name: layoutRes.data?.name || `Board ${n}`,
    multiBoard: true,
  };
}

export async function saveScoutingPlanner(
  supabase,
  slots,
  pitchLayout,
  boardNo = getStoredScoutingBoardNo()
) {
  if (scoutingSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const n = clampBoardNo(boardNo);
  const { data, error } = await supabase.rpc("club_save_scouting_planner", {
    p_slots: slots,
    p_pitch_layout: pitchLayout,
    p_board_no: n,
  });

  if (error) {
    // Older RPC without p_board_no — save to the single planner
    if (
      error.code === "PGRST202" ||
      String(error.message || "").includes("p_board_no") ||
      String(error.message || "").includes("club_save_scouting_planner")
    ) {
      const legacy = await supabase.rpc("club_save_scouting_planner", {
        p_slots: slots,
        p_pitch_layout: pitchLayout,
      });
      if (legacy.error) {
        if (
          String(legacy.error.message || "").includes("board_no") ||
          String(legacy.error.message || "").includes("Board must be")
        ) {
          throw new Error(MULTI_BOARD_SQL_HINT);
        }
        if (isScoutingSchemaMissingError(legacy.error)) {
          scoutingSchemaMissing = true;
          throw new Error(SQL_SETUP_HINT);
        }
        throw legacy.error;
      }
      return legacy.data;
    }
    if (isScoutingSchemaMissingError(error)) {
      scoutingSchemaMissing = true;
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  scoutingSchemaMissing = false;
  return data;
}
