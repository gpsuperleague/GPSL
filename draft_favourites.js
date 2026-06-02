// Per-club saved draft auction threads (player Konami_ID)

const SQL_SETUP_HINT =
  "Run supabase/sql/draft_auction_favourites.sql in the Supabase SQL Editor, then reload the page.";

let favouritesSchemaMissing = false;
let schemaMissingWarned = false;

function isFavouritesSchemaMissingError(error) {
  if (!error) return false;
  if (error.code === "PGRST205" || error.code === "42P01") return true;
  const msg = String(error.message || "");
  return msg.includes("draft_auction_favourites");
}

function warnSchemaMissingOnce() {
  if (schemaMissingWarned) return;
  schemaMissingWarned = true;
  console.warn(`Saved draft auctions: database table missing. ${SQL_SETUP_HINT}`);
}

export function isDraftFavouritesAvailable() {
  return !favouritesSchemaMissing;
}

export function draftFavouritesSetupHint() {
  return SQL_SETUP_HINT;
}

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
    if (isFavouritesSchemaMissingError(error)) {
      favouritesSchemaMissing = true;
      warnSchemaMissingOnce();
      return new Set();
    }
    console.error("loadDraftFavouriteIds:", error);
    return new Set();
  }

  favouritesSchemaMissing = false;
  return new Set((data || []).map((r) => String(r.player_id)));
}

export async function toggleDraftFavourite(supabase, clubShortName, playerId) {
  if (!clubShortName) {
    throw new Error("No club linked to your account");
  }

  if (favouritesSchemaMissing) {
    throw new Error(SQL_SETUP_HINT);
  }

  const { data, error } = await supabase.rpc("draft_auction_toggle_favourite", {
    p_player_id: String(playerId),
  });

  if (error) {
    if (isFavouritesSchemaMissingError(error)) {
      favouritesSchemaMissing = true;
      warnSchemaMissingOnce();
      throw new Error(SQL_SETUP_HINT);
    }
    throw error;
  }

  favouritesSchemaMissing = false;
  return data?.favourited === true;
}

export function sortDraftListingsByFavourite(listings, favouriteIds) {
  return [...listings].sort((a, b) => {
    const aFav = favouriteIds.has(String(a.player_id)) ? 0 : 1;
    const bFav = favouriteIds.has(String(b.player_id)) ? 0 : 1;
    return aFav - bFav;
  });
}
