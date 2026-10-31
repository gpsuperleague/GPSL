/**
 * Mid-season handpick wishlist tags (GPDB soft hold).
 * Does not set Contracted_Team — only club_handpick_basket.
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
  return {
    ok: !!data?.ok,
    club: data?.club ? String(data.club).toUpperCase() : null,
    handpickIntake: !!data?.handpick_intake,
    playerIds: new Set(ids.filter(Boolean)),
    players,
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

export function handpickTagChar(on) {
  return on ? "☑" : "☐";
}
