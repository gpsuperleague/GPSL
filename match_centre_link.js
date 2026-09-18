/**
 * Match Centre shortcut — small Natter-style button on fixture rows.
 * Opens match_report.html (full box score when played; CTAs when not).
 */

export function matchCentreHref(fixture) {
  const id = fixture?.id ?? fixture?.fixture_id;
  if (id == null) return null;
  return `match_report.html?fixture=${encodeURIComponent(String(id))}`;
}

export function matchCentreTitle(fixture) {
  const status = String(fixture?.status || "").toLowerCase();
  if (status === "played") return "Match Centre — line-ups & stats";
  return "Match Centre — open match";
}

/** Compact nav-style control next to team names. */
export function matchCentreButtonHtml(fixture) {
  const href = matchCentreHref(fixture);
  if (!href) return "";
  const title = matchCentreTitle(fixture);
  const played = String(fixture?.status || "").toLowerCase() === "played";
  const mark = played ? "◉" : "▷";
  return (
    `<a href="${href}" class="match-centre-btn${played ? " is-played" : ""}" ` +
    `title="${title}" aria-label="${title}">` +
    `<span class="match-centre-mark" aria-hidden="true">${mark}</span>` +
    `</a>`
  );
}
