/**
 * Mid-season handpick wishlist tags (GPDB / MGDB soft hold).
 * Does not set Contracted_Team / contracted_club — basket + one manager tag only.
 */

export async function loadHandpickBasketState(supabase, clubShortName = null) {
  const { data, error } = await supabase.rpc("handpick_basket_list", {
    p_club_short_name: clubShortName || null,
  });
  if (error) throw error;
  const ids = Array.isArray(data?.player_ids)
    ? data.player_ids.map(String)
    : [];
  const players = Array.isArray(data?.players) ? data.players : [];
  const manager =
    data?.manager && typeof data.manager === "object" ? data.manager : null;
  return {
    ok: !!data?.ok,
    club: data?.club ? String(data.club).toUpperCase() : null,
    handpickIntake: !!data?.handpick_intake,
    playerIds: new Set(ids.filter(Boolean)),
    players,
    manager,
    managerId: manager?.manager_id != null ? Number(manager.manager_id) : null,
    raw: data,
  };
}

/**
 * @returns {Promise<{ ok: boolean, tagged?: boolean, reason?: string, detail?: string }>}
 */
export async function toggleHandpickBasketPlayer(
  supabase,
  playerId,
  clubShortName = null
) {
  const { data, error } = await supabase.rpc("handpick_basket_toggle", {
    p_player_id: String(playerId || "").trim(),
    p_club_short_name: clubShortName || null,
  });
  if (error) {
    return { ok: false, reason: error.message };
  }
  return data && typeof data === "object" ? data : { ok: false, reason: "bad_response" };
}

/**
 * Explicit add/remove (preferred for wishlist UI).
 * @returns {Promise<{ ok: boolean, tagged?: boolean, reason?: string, detail?: string }>}
 */
export async function setHandpickBasketPlayer(
  supabase,
  playerId,
  tagged,
  clubShortName = null
) {
  const { data, error } = await supabase.rpc("handpick_basket_set", {
    p_player_id: String(playerId || "").trim(),
    p_tagged: !!tagged,
    p_club_short_name: clubShortName || null,
  });
  if (error) {
    return { ok: false, reason: error.message };
  }
  return data && typeof data === "object" ? data : { ok: false, reason: "bad_response" };
}

export async function clearHandpickBasket(supabase, clubShortName = null) {
  const { data, error } = await supabase.rpc("handpick_basket_clear", {
    p_club_short_name: clubShortName || null,
  });
  if (error) throw error;
  return data;
}

/**
 * Tag / untag the club's handpick manager (one at a time; tagging replaces).
 * @returns {Promise<{ ok: boolean, tagged?: boolean, manager?: object, reason?: string, detail?: string }>}
 */
export async function setHandpickManager(
  supabase,
  managerId,
  tagged,
  clubShortName = null
) {
  const { data, error } = await supabase.rpc("handpick_manager_set", {
    p_manager_id: Number(managerId),
    p_tagged: !!tagged,
    p_club_short_name: clubShortName || null,
  });
  if (error) {
    return { ok: false, reason: error.message };
  }
  return data && typeof data === "object" ? data : { ok: false, reason: "bad_response" };
}

export async function toggleHandpickManager(
  supabase,
  managerId,
  currentlyTagged,
  clubShortName = null
) {
  return setHandpickManager(
    supabase,
    managerId,
    !currentlyTagged,
    clubShortName
  );
}

export function handpickTagChar(on) {
  return on ? "☑" : "☐";
}
