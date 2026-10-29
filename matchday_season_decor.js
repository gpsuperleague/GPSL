/**
 * Classy seasonal watermark for Fixtures matchday / Club Fixtures month headers.
 * One large, low-opacity banner per GPSL month — subtle, not busy.
 */

const SEASON_BANNER = {
  june: "images/matchday_seasons/june.jpg",
  july: "images/matchday_seasons/july.jpg",
  august: "images/matchday_seasons/august.jpg",
  september: "images/matchday_seasons/september.jpg",
  october: "images/matchday_seasons/october.jpg",
  november: "images/matchday_seasons/november.jpg",
  december: "images/matchday_seasons/december.jpg",
  january: "images/matchday_seasons/january.jpg",
  february: "images/matchday_seasons/february.jpg",
  march: "images/matchday_seasons/march.jpg",
  april: "images/matchday_seasons/april.jpg",
  may: "images/matchday_seasons/may.jpg",
};

/**
 * @param {string|null|undefined} gpslMonth
 * @returns {string} HTML decoration layer (or "")
 */
export function matchdaySeasonDecorHtml(gpslMonth) {
  const key = String(gpslMonth || "")
    .trim()
    .toLowerCase();
  const src = SEASON_BANNER[key];
  if (!src) return "";

  return (
    `<div class="matchday-season-decor" data-season="${key}" aria-hidden="true">` +
    `<img class="matchday-season-banner" src="${src}" alt="" loading="lazy" decoding="async">` +
    `</div>`
  );
}
