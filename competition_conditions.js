// Continental weather, pitch, and kit season labels (eFootball match settings)

export const CONTINENTS = [
  { id: "south_america", label: "South America" },
  { id: "north_america", label: "North America" },
  { id: "northern_europe", label: "Northern Europe" },
  { id: "western_europe", label: "Western Europe" },
  { id: "southern_europe", label: "Southern Europe" },
  { id: "eastern_europe", label: "Eastern Europe" },
  { id: "asia", label: "Asia" },
  { id: "africa", label: "Africa" },
];

export const CONTINENT_LABELS = Object.fromEntries(
  CONTINENTS.map((c) => [c.id, c.label])
);

export const METEO_SEASONS = [
  { id: "spring", label: "Spring" },
  { id: "summer", label: "Summer" },
  { id: "autumn", label: "Autumn" },
  { id: "winter", label: "Winter" },
];

/** GPSL months (Aug–May) mapped to meteorological season per continent. */
export const GPSL_MONTH_SEASON_BY_CONTINENT = {
  south_america: {
    august: "winter",
    september: "spring",
    october: "spring",
    november: "spring",
    december: "summer",
    january: "summer",
    february: "summer",
    march: "autumn",
    april: "autumn",
    may: "autumn",
  },
  asia: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "autumn",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  north_america: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "autumn",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  northern_europe: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "winter",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  southern_europe: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "winter",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  western_europe: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "winter",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  eastern_europe: {
    march: "spring",
    april: "spring",
    may: "spring",
    august: "summer",
    september: "autumn",
    october: "autumn",
    november: "winter",
    december: "winter",
    january: "winter",
    february: "winter",
  },
  africa: {
    august: "summer",
    september: "summer",
    october: "autumn",
    november: "autumn",
    december: "winter",
    january: "winter",
    february: "winter",
    march: "spring",
    april: "spring",
    may: "spring",
  },
};

export const GPSL_MONTH_LABELS = {
  august: "August",
  september: "September",
  october: "October",
  november: "November",
  december: "December",
  january: "January",
  february: "February",
  march: "March",
  april: "April",
  may: "May",
};

export function gpslMonthsForContinentSeason(continentId, seasonId) {
  const map = GPSL_MONTH_SEASON_BY_CONTINENT[continentId] || {};
  return Object.entries(map)
    .filter(([, season]) => season === seasonId)
    .map(([month]) => GPSL_MONTH_LABELS[month] || month)
    .join(", ");
}

export function formatWeatherLabel(value) {
  const v = String(value || "").toLowerCase();
  if (v === "fine") return "Fine";
  if (v === "rain") return "Rain";
  if (v === "snow") return "Snow";
  return value || "—";
}

export function formatPitchLabel(value) {
  const v = String(value || "").toLowerCase();
  if (v === "normal") return "Normal";
  if (v === "dry") return "Dry";
  if (v === "wet") return "Wet";
  return value || "—";
}

export function formatKitSeasonLabel(value) {
  const v = String(value || "").toLowerCase();
  if (v === "summer") return "Summer kit (short sleeves)";
  if (v === "winter") return "Winter kit (long sleeves)";
  return value || "—";
}

const WEATHER_ICON = {
  fine: "images/conditions/weather-fine.svg",
  rain: "images/conditions/weather-rain.svg",
  snow: "images/conditions/weather-snow.svg",
};

const PITCH_ICON = {
  normal: "images/conditions/pitch-normal.svg",
  dry: "images/conditions/pitch-dry.svg",
  wet: "images/conditions/pitch-wet.svg",
};

function conditionIconHtml(src, label) {
  if (!src) return escapeHtmlText(label);
  return (
    `<span class="cond-chip" title="${escapeHtmlText(label)}">` +
    `<img class="cond-icon" src="${src}" alt="" width="16" height="16" loading="lazy">` +
    `<span class="cond-label">${escapeHtmlText(label)}</span>` +
    `</span>`
  );
}

export function formatWeatherChipHtml(value) {
  const key = String(value || "").toLowerCase();
  const label = formatWeatherLabel(value);
  if (!label || label === "—") return "—";
  return conditionIconHtml(WEATHER_ICON[key], label);
}

export function formatPitchChipHtml(value) {
  const key = String(value || "").toLowerCase();
  const label = formatPitchLabel(value);
  if (!label || label === "—") return "—";
  return conditionIconHtml(PITCH_ICON[key], label);
}

/** One-line summary for fixtures / matchday. */
export function formatMatchConditions(fixture) {
  if (!fixture) return "—";
  const parts = [];
  if (fixture.kit_season) parts.push(formatKitSeasonLabel(fixture.kit_season));
  if (fixture.weather) parts.push(formatWeatherLabel(fixture.weather));
  if (fixture.pitch_condition) parts.push(formatPitchLabel(fixture.pitch_condition));
  return parts.length ? parts.join(" · ") : fixture.weather || "—";
}

/** Plain weather · pitch for wire / checklist meta (no icons). */
export function formatWeatherPitchPlain(fixture) {
  if (!fixture) return "";
  const parts = [];
  if (fixture.weather) parts.push(formatWeatherLabel(fixture.weather));
  if (fixture.pitch_condition) parts.push(formatPitchLabel(fixture.pitch_condition));
  return parts.join(" · ");
}

/**
 * Batch-load home/away + weather/pitch for checklist & Club Wire.
 * @param {import("@supabase/supabase-js").SupabaseClient} client
 * @param {Array<number|string>} fixtureIds
 * @returns {Promise<Map<number, object>>}
 */
export async function fetchFixturesHomeWeatherMeta(client, fixtureIds) {
  const ids = [
    ...new Set(
      (fixtureIds || [])
        .map((id) => Number(id))
        .filter((id) => Number.isFinite(id) && id > 0)
    ),
  ];
  const out = new Map();
  if (!client || !ids.length) return out;

  const { data, error } = await client
    .from("competition_fixtures_public")
    .select(
      "id, home_club_short_name, away_club_short_name, home_club_name, away_club_name, weather, pitch_condition, kit_season"
    )
    .in("id", ids);

  if (error) {
    console.warn("fetchFixturesHomeWeatherMeta:", error.message);
    return out;
  }

  for (const row of data || []) {
    out.set(Number(row.id), row);
  }
  return out;
}

/** Fixtures table: kit text + weather/pitch icons. */
export function formatMatchConditionsHtml(fixture) {
  if (!fixture) return "—";
  const parts = [];
  if (fixture.kit_season) {
    parts.push(
      `<span class="cond-kit">${escapeHtmlText(formatKitSeasonLabel(fixture.kit_season))}</span>`
    );
  }
  if (fixture.weather) parts.push(formatWeatherChipHtml(fixture.weather));
  if (fixture.pitch_condition) parts.push(formatPitchChipHtml(fixture.pitch_condition));
  if (!parts.length) {
    return fixture.weather ? formatWeatherChipHtml(fixture.weather) : "—";
  }
  return parts.join(`<span class="cond-sep">·</span>`);
}

export function formatFixtureContinent(fixture) {
  if (!fixture) return "—";
  return CONTINENT_LABELS[fixture.home_continent] || fixture.home_continent || "—";
}

/** Two-word continents as stacked lines (saves fixtures column width). */
export function formatFixtureContinentStackedHtml(fixture) {
  const label = formatFixtureContinent(fixture);
  if (!label || label === "—") return "—";
  const parts = String(label).trim().split(/\s+/).filter(Boolean);
  if (parts.length < 2) return escapeHtmlText(parts[0] || label);
  return parts
    .map((p) => `<span class="continent-line">${escapeHtmlText(p)}</span>`)
    .join("");
}

function escapeHtmlText(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Stadium label for fixtures table (home venue, or neutral e.g. Wembley). */
export function fixtureStadiumLabel(fixture, myClubShort, homeStadiumName) {
  if (!fixture) return "—";
  const neutral = String(fixture.venue_name || "").trim();
  const name =
    neutral ||
    homeStadiumName ||
    fixture.home_club_name ||
    fixture.home_club_short_name ||
    "—";
  if (neutral) return name;
  const home = (fixture.home_club_short_name || "").trim().toUpperCase();
  const mine = (myClubShort || "").trim().toUpperCase();
  if (mine && home === mine) return name;
  if (mine && home !== mine) return `At ${name}`;
  return name;
}

/**
 * Balance a long stadium name across two lines near the midpoint.
 * Short names stay on one line.
 */
export function formatStadiumLabelStackedHtml(label, { minChars = 16 } = {}) {
  const text = String(label || "").trim();
  if (!text || text === "—") return "—";
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length < 2 || text.length < minChars) {
    return `<span class="stadium-line">${escapeHtmlText(text)}</span>`;
  }
  let best = 1;
  let bestDiff = Infinity;
  for (let i = 1; i < words.length; i++) {
    const a = words.slice(0, i).join(" ");
    const b = words.slice(i).join(" ");
    const diff = Math.abs(a.length - b.length);
    if (diff < bestDiff) {
      bestDiff = diff;
      best = i;
    }
  }
  const top = words.slice(0, best).join(" ");
  const bottom = words.slice(best).join(" ");
  return (
    `<span class="stadium-line">${escapeHtmlText(top)}</span>` +
    `<span class="stadium-line">${escapeHtmlText(bottom)}</span>`
  );
}

export function fixtureStadiumLabelStackedHtml(
  fixture,
  myClubShort,
  homeStadiumName
) {
  return formatStadiumLabelStackedHtml(
    fixtureStadiumLabel(fixture, myClubShort, homeStadiumName)
  );
}

export const WEATHER_KEYS = ["fine", "rain", "snow"];
export const PITCH_KEYS = ["normal", "dry", "wet"];

export const WEATHER_LABELS = { fine: "Fine", rain: "Rain", snow: "Snow" };
export const PITCH_LABELS = { normal: "Normal", dry: "Dry", wet: "Wet" };
