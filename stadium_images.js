/** Stadium photo paths (from scripts/fetch_stadium_images.mjs). */
export function stadiumImageUrl(shortName) {
  const key = String(shortName || "").trim();
  if (!key) return null;
  return `images/stadiums/${key}.jpg`;
}
