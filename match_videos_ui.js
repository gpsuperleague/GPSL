/**
 * Fixture match video ticks (home / away Discord uploads).
 */

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {Array<number|string>} fixtureIds
 * @returns {Promise<Map<string, { home_url?: string|null, away_url?: string|null }>>}
 */
export async function loadFixtureMatchVideos(supabase, fixtureIds) {
  const map = new Map();
  const ids = [...new Set((fixtureIds || []).map((id) => Number(id)).filter(Boolean))];
  if (!ids.length) return map;

  const { data, error } = await supabase
    .from("fixture_match_videos")
    .select("fixture_id, side, video_url")
    .in("fixture_id", ids);

  if (error) {
    console.warn("loadFixtureMatchVideos:", error.message);
    return map;
  }

  for (const row of data || []) {
    const key = String(row.fixture_id);
    const cur = map.get(key) || { home_url: null, away_url: null };
    if (row.side === "home") cur.home_url = row.video_url;
    if (row.side === "away") cur.away_url = row.video_url;
    map.set(key, cur);
  }
  return map;
}

function tickHtml(sideLabel, url) {
  const has = Boolean(url);
  if (has) {
    return `<a class="mv-tick mv-tick-on" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer" title="${sideLabel} video uploaded — open">${sideLabel}✓</a>`;
  }
  return `<span class="mv-tick mv-tick-off" title="${sideLabel} video not uploaded yet">${sideLabel}○</span>`;
}

function escapeAttr(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

/**
 * Compact home/away ticks for fixtures score cell.
 * @param {{ home_url?: string|null, away_url?: string|null }|null|undefined} videos
 */
export function matchVideoTicksHtml(videos) {
  const v = videos || {};
  return `<span class="mv-ticks">${tickHtml("H", v.home_url)}${tickHtml("A", v.away_url)}</span>`;
}

/** Suggested Discord filename for a fixture (copy hint). */
export function matchVideoFilenameHint(fixture) {
  if (!fixture) return "";
  const home = String(fixture.home_club_short_name || "").toUpperCase();
  const away = String(fixture.away_club_short_name || "").toUpperCase();
  const hg = fixture.home_goals != null ? fixture.home_goals : "0";
  const ag = fixture.away_goals != null ? fixture.away_goals : "0";

  let tag = "SL-MD1";
  if (fixture.competition_type === "cup") {
    const cupMap = {
      super8: "S8",
      plate: "PL",
      shield: "SH",
      bowl: "BO",
      league_cup: "LC",
    };
    const comp = cupMap[fixture.cup_code] || "S8";
    const round = fixture.cup_round != null ? `R${fixture.cup_round}` : "R1";
    tag = `${comp}-${round}`;
  } else if (fixture.division === "superleague") {
    tag = `SL-MD${fixture.matchday || "?"}`;
  } else if (fixture.division === "championship_a") {
    tag = `CA-MD${fixture.matchday || "?"}`;
  } else if (fixture.division === "championship_b") {
    tag = `CB-MD${fixture.matchday || "?"}`;
  } else {
    tag = `CH-MD${fixture.matchday || "?"}`;
  }

  return `${home} ${hg}-${ag} ${away} [${tag}]`;
}

export const MATCH_VIDEO_TICK_CSS = `
.mv-ticks { display:inline-flex; gap:4px; margin-left:6px; vertical-align:middle; font-size:11px; }
.mv-tick { text-decoration:none; padding:1px 4px; border-radius:3px; font-weight:600; letter-spacing:0.02em; }
.mv-tick-on { color:#1a1a1a; background:#8d8; border:1px solid #6a6; }
.mv-tick-on:hover { filter:brightness(1.08); }
.mv-tick-off { color:#777; background:#222; border:1px solid #444; }
`;
