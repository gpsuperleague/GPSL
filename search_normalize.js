/** Accent/punctuation-insensitive text search (matches GPDB name filter). */

export function normalizeSearchText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function textMatchesSearch(displayText, rawQuery) {
  const query = normalizeSearchText(rawQuery);
  if (!query) return true;
  const haystack = normalizeSearchText(displayText);
  return haystack.includes(query);
}
