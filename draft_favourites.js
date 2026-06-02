// Per-club saved draft auction threads (player Konami_ID)

export function favouriteStarChar(isFavourite) {
  return isFavourite ? "★" : "☆";
}

export function favouriteButtonLabel(isFavourite) {
  return isFavourite ? "Remove from saved" : "Save draft auction";
}

export async function loadDraftFavouriteIds(supabase, clubShortName) {
  if (!clubShortName) return new Set();

  const { data, error } = await supabase
    .from("draft_auction_favourites")
    .select("player_id")
    .eq("club_id", clubShortName);

  if (error) {
    console.error("loadDraftFavouriteIds:", error);
    return new Set();
  }

  return new Set((data || []).map((r) => String(r.player_id)));
}

export async function toggleDraftFavourite(supabase, clubShortName, playerId) {
  if (!clubShortName) {
    throw new Error("No club linked to your account");
  }

  const { data, error } = await supabase.rpc("draft_auction_toggle_favourite", {
    p_player_id: String(playerId),
  });

  if (error) throw error;
  return data?.favourited === true;
}

export function sortDraftListingsByFavourite(listings, favouriteIds) {
  return [...listings].sort((a, b) => {
    const aFav = favouriteIds.has(String(a.player_id)) ? 0 : 1;
    const bFav = favouriteIds.has(String(b.player_id)) ? 0 : 1;
    return aFav - bFav;
  });
}
