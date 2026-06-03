// Saved transfer market listings (per club) — localStorage, no SQL required

const STORAGE_PREFIX = "gpsl_listing_favourites_";

export function favouriteStarChar(isFavourite) {
  return isFavourite ? "★" : "☆";
}

export function favouriteButtonLabel(isFavourite) {
  return isFavourite ? "Remove from favourites" : "Favourite listing";
}

export function loadListingFavouriteIds(clubShortName) {
  if (!clubShortName) return new Set();
  try {
    const raw = localStorage.getItem(STORAGE_PREFIX + clubShortName);
    if (!raw) return new Set();
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return new Set();
    return new Set(arr.map((id) => String(id)));
  } catch {
    return new Set();
  }
}

function saveListingFavouriteIds(clubShortName, ids) {
  if (!clubShortName) return;
  localStorage.setItem(
    STORAGE_PREFIX + clubShortName,
    JSON.stringify([...ids])
  );
}

/** Toggle favourite; returns true if now favourited. */
export function toggleListingFavourite(clubShortName, listingId) {
  const key = String(listingId);
  const ids = loadListingFavouriteIds(clubShortName);
  if (ids.has(key)) ids.delete(key);
  else ids.add(key);
  saveListingFavouriteIds(clubShortName, ids);
  return ids.has(key);
}

/** Favourites first; preserve relative order within each group. */
export function sortListingsFavouritesFirst(listings, favouriteIds) {
  if (!favouriteIds?.size) return listings;
  return listings
    .map((listing, index) => ({ listing, index }))
    .sort((a, b) => {
      const aFav = favouriteIds.has(String(a.listing.id));
      const bFav = favouriteIds.has(String(b.listing.id));
      if (aFav !== bFav) return aFav ? -1 : 1;
      return a.index - b.index;
    })
    .map((x) => x.listing);
}
