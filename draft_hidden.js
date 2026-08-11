/**
 * Per-club draft auction hide list (view only — does not affect bids).
 * Stored in localStorage so owners can declutter threads they have bid on.
 */

function storageKey(clubShortName) {
  const club = String(clubShortName || "")
    .trim()
    .toUpperCase();
  return club ? `gpsl_draft_hidden_${club}` : "gpsl_draft_hidden_anon";
}

export function loadDraftHiddenIds(clubShortName) {
  try {
    const raw = localStorage.getItem(storageKey(clubShortName));
    if (!raw) return new Set();
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return new Set();
    return new Set(arr.map((id) => String(id)));
  } catch {
    return new Set();
  }
}

export function saveDraftHiddenIds(clubShortName, ids) {
  try {
    localStorage.setItem(
      storageKey(clubShortName),
      JSON.stringify([...ids].map((id) => String(id)))
    );
  } catch {
    /* private mode / quota */
  }
}

export function isDraftPlayerHidden(hiddenIds, playerId) {
  return hiddenIds.has(String(playerId));
}

/** @returns {boolean} true if now hidden */
export function toggleDraftPlayerHidden(clubShortName, hiddenIds, playerId) {
  const key = String(playerId);
  if (hiddenIds.has(key)) {
    hiddenIds.delete(key);
    saveDraftHiddenIds(clubShortName, hiddenIds);
    return false;
  }
  hiddenIds.add(key);
  saveDraftHiddenIds(clubShortName, hiddenIds);
  return true;
}

export function draftHideButtonLabel(isHidden) {
  return isHidden ? "Unhide" : "Hide";
}
