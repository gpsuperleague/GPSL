/**
 * GPSL player link standard (use everywhere a player is shown in lists/tables):
 *   • Card/thumbnail → pesdb.net (efootball card page)
 *   • Player name    → player_career.html (GPSL player file)
 */

export const PESDB_FALLBACK_CARD_IMG = "https://i.imgur.com/3s8XQ7Y.png";

export function pesdbPlayerUrl(konamiId) {
  const id = String(konamiId ?? "").trim();
  if (!id) return "#";
  return `https://pesdb.net/efootball/?id=${encodeURIComponent(id)}`;
}

export function pesdbPlayerCardUrl(konamiId) {
  const id = String(konamiId ?? "").trim();
  if (!id) return PESDB_FALLBACK_CARD_IMG;
  return `https://pesdb.net/assets/img/card/b${encodeURIComponent(id)}.png`;
}

export function gpslPlayerCareerUrl(konamiId) {
  const id = String(konamiId ?? "").trim();
  if (!id) return "#";
  return `player_career.html?id=${encodeURIComponent(id)}`;
}

export function escapePlayerHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

/**
 * Linked PESDB card image.
 */
export function playerThumbLinkHtml(konamiId, options = {}) {
  const id = String(konamiId ?? "").trim();
  if (!id) return "";

  const {
    className = "player-thumb",
    alt = "",
    linkClass = "",
    fallback = PESDB_FALLBACK_CARD_IMG,
    wrapLink = true,
  } = options;

  const img = `<img src="${pesdbPlayerCardUrl(id)}" class="${className}" alt="${escapePlayerHtml(alt)}" onerror="this.src='${fallback}'">`;

  if (!wrapLink) return img;

  const linkCls = linkClass ? ` class="${linkClass}"` : "";
  return `<a href="${pesdbPlayerUrl(id)}" target="_blank" rel="noopener"${linkCls}>${img}</a>`;
}

/**
 * Linked GPSL player career page.
 */
export function playerNameLinkHtml(konamiId, name, options = {}) {
  const id = String(konamiId ?? "").trim();
  const {
    className = "gpsl-player-link",
    fallbackId = true,
    raw = false,
  } = options;
  const label = name || (fallbackId && id ? id : "—");

  if (!id) {
    return raw ? escapePlayerHtml(label) : escapePlayerHtml(label);
  }

  return `<a href="${gpslPlayerCareerUrl(id)}" class="${className}">${escapePlayerHtml(label)}</a>`;
}

/** Standard table cells: thumb (PESDB) + name (GPSL). */
export function playerTableCellsHtml(konamiId, name, options = {}) {
  return `<td>${playerThumbLinkHtml(konamiId, options)}</td><td>${playerNameLinkHtml(konamiId, name, options)}</td>`;
}
