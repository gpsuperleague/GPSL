/**
 * TV fixture selection badge for fixture lists.
 */

/** @type {Set<number>} */
let tvFixtureIds = new Set();

/**
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @param {number|null|undefined} seasonId
 */
export async function loadTvFixtureIds(supabase, seasonId) {
  tvFixtureIds = new Set();
  if (!seasonId) return tvFixtureIds;

  const { data, error } = await supabase
    .from("competition_tv_fixtures_public")
    .select("fixture_id")
    .eq("season_id", seasonId);

  if (error) {
    console.warn("loadTvFixtureIds:", error);
    return tvFixtureIds;
  }

  for (const row of data || []) {
    if (row.fixture_id != null) tvFixtureIds.add(Number(row.fixture_id));
  }
  return tvFixtureIds;
}

/** @param {number|string|null|undefined} fixtureId */
export function isTvFixture(fixtureId) {
  if (fixtureId == null || fixtureId === "") return false;
  return tvFixtureIds.has(Number(fixtureId));
}

/** @param {number|string|null|undefined} fixtureId */
export function tvFixtureBadgeHtml(fixtureId) {
  if (!isTvFixture(fixtureId)) return "";
  return '<span class="tv-fixture-badge" title="Selected for TV">📺</span>';
}
