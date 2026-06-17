// Continental weather, pitch, and kit season labels (eFootball match settings)

export const CONTINENTS = [
  { id: "south_america", label: "South America" },
  { id: "north_america", label: "North America" },
  { id: "northern_europe", label: "Northern Europe" },
  { id: "southern_europe", label: "Southern Europe" },
  { id: "western_europe", label: "Western Europe" },
  { id: "asia", label: "Asia" },
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

/** One-line summary for fixtures / matchday. */
export function formatMatchConditions(fixture) {
  if (!fixture) return "—";
  const parts = [];
  if (fixture.kit_season) parts.push(formatKitSeasonLabel(fixture.kit_season));
  if (fixture.weather) parts.push(formatWeatherLabel(fixture.weather));
  if (fixture.pitch_condition) parts.push(formatPitchLabel(fixture.pitch_condition));
  return parts.length ? parts.join(" · ") : fixture.weather || "—";
}

/** Home venue label for the logged-in owner (home = your continent rules; away = opponent's). */
export function fixtureHomeVenueLabel(fixture, myClubShort) {
  if (!fixture) return "—";
  const home = (fixture.home_club_short_name || "").trim().toUpperCase();
  const mine = (myClubShort || "").trim().toUpperCase();
  if (mine && home === mine) return "Your home";
  if (mine) {
    return `At ${fixture.home_club_name || fixture.home_club_short_name || "opponent"}`;
  }
  return fixture.home_club_name || fixture.home_club_short_name || "Home venue";
}

/** Match conditions at the home venue, with continent (used on Fixtures). */
export function formatFixtureConditionsRow(fixture, myClubShort) {
  if (!fixture) return "—";
  const venue = fixtureHomeVenueLabel(fixture, myClubShort);
  const continent =
    CONTINENT_LABELS[fixture.home_continent] || fixture.home_continent || null;
  const cond = formatMatchConditions(fixture);
  return [venue, continent, cond].filter(Boolean).join(" · ");
}

export const WEATHER_KEYS = ["fine", "rain", "snow"];
export const PITCH_KEYS = ["normal", "dry", "wet"];

export const WEATHER_LABELS = { fine: "Fine", rain: "Rain", snow: "Snow" };
export const PITCH_LABELS = { normal: "Normal", dry: "Dry", wet: "Wet" };
