import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { stadiumImageUrl } from "./stadium_images.js";
import {
  formatMoney,
  loadLeagueFixtures,
  estimateGateForClub,
  loadClubSeasonArchive,
  loadStandings,
  DIVISION_LABELS,
} from "./competition.js";

function renderStadiumPhoto(shortName, stadiumName) {
  const slot = document.getElementById("stadiumPhotoSlot");
  if (!slot) return;

  const src = stadiumImageUrl(shortName);
  const img = new Image();
  img.onload = () => {
    slot.innerHTML = `
      <div class="stadium-photo-wrap">
        <img class="stadium-photo" src="${src}" alt="${stadiumName || "Stadium"}">
        <span class="stadium-photo-credit">StadiumDB</span>
      </div>
    `;
  };
  img.onerror = () => {
    slot.innerHTML = `
      <p class="stadium-photo-missing">
        No stadium photo yet. Run <code>node scripts/fetch_stadium_images.mjs</code> locally.
      </p>
    `;
  };
  img.src = src;
}

function renderGateBreakdown(data) {
  const el = document.getElementById("gateBreakdown");
  if (!el) return;

  if (!data) {
    el.innerHTML = '<p class="empty">Could not estimate gate — check active season and SQL phase 5.</p>';
    return;
  }

  const fillPct = ((Number(data.attendance_rate) || 0) * 100).toFixed(1);
  el.innerHTML = `
    <dl class="breakdown">
      <dt>Stadium capacity</dt><dd>${Number(data.capacity || 0).toLocaleString("en-GB")}</dd>
      <dt>League position</dt><dd>${data.table_position ?? "—"}</dd>
      <dt>5-season avg finish</dt><dd>${data.history_avg_position ?? "10 (neutral)"}</dd>
      <dt>Fill rate</dt><dd>${fillPct}%</dd>
      <dt>Est. gate per home match</dt><dd class="highlight">${formatMoney(data.total_gate)}</dd>
    </dl>
    <p class="note">League home games: <b>100%</b> to home club. Cup games: <b>50% / 50%</b> (when cups are added).</p>
  `;
}

function renderHomeFixtures(fixtures, clubShort) {
  const el = document.getElementById("homeFixturesList");
  if (!el) return;

  const home = fixtures
    .filter(
      (f) =>
        f.status === "scheduled" &&
        (f.home_club_short_name || "").toUpperCase() === clubShort.toUpperCase()
    )
    .slice(0, 8);

  if (!home.length) {
    el.innerHTML = '<p class="empty">No upcoming home league fixtures.</p>';
    return;
  }

  el.innerHTML = `
    <ul class="fixture-ul">
      ${home
        .map(
          (f) =>
            `<li>MD${f.matchday}: vs ${f.away_club_name || f.away_club_short_name}</li>`
        )
        .join("")}
    </ul>
  `;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Stadium, Capacity")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent = "No club linked to this account.";
    return;
  }

  await loadClubsMap();
  const shortName = club.ShortName;

  document.getElementById("pageTitle").textContent =
    `${fullClubName(shortName) || club.Club} — Stadium`;
  document.getElementById("stadiumName").textContent = club.Stadium || "—";
  document.getElementById("stadiumCapacity").textContent = Number(
    club.Capacity || 0
  ).toLocaleString("en-GB");

  renderStadiumPhoto(shortName, club.Stadium);

  const estimate = await estimateGateForClub(supabase, shortName);
  renderGateBreakdown(estimate);

  const archive = await loadClubSeasonArchive(supabase, shortName);
  const archEl = document.getElementById("historyNote");
  if (archEl) {
    archEl.textContent = archive.length
      ? `Using ${archive.length} archived season(s) for gate boost.`
      : "No archive rows — using neutral history until seasons are archived.";
  }

  const standings = await loadStandings(supabase);
  const row = standings.find((s) => s.club_short_name === shortName);
  if (row && document.getElementById("leaguePos")) {
    document.getElementById("leaguePos").textContent =
      `${DIVISION_LABELS[row.division] || row.division} — ${row.table_position}${ordinal(row.table_position)}`;
  }

  const { data: reg } = await supabase
    .from("competition_club_season_public")
    .select("division")
    .eq("club_short_name", shortName)
    .maybeSingle();

  const division = reg?.division || row?.division;
  if (division) {
    const fixtures = await loadLeagueFixtures(supabase, division);
    renderHomeFixtures(fixtures, shortName);
  }
});

function ordinal(n) {
  const s = ["th", "st", "nd", "rd"];
  const v = n % 100;
  return s[(v - 20) % 10] || s[v] || s[0];
}
