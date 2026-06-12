import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  CONTINENTS,
  METEO_SEASONS,
  WEATHER_KEYS,
  PITCH_KEYS,
  WEATHER_LABELS,
  PITCH_LABELS,
  gpslMonthsForContinentSeason,
} from "./competition_conditions.js";

primeAdminPageChrome();

/** @type {Map<string, Record<string, unknown>>} */
const configMap = new Map();

function configKey(continent, season) {
  return `${continent}|${season}`;
}

function pctSum(inputs) {
  return inputs.reduce((n, el) => n + (Number(el.value) || 0), 0);
}

function updateSumDisplay(wrap, sum, target = 100) {
  const el = wrap.querySelector(".wx-sum");
  if (!el) return;
  const ok = Math.round(sum * 100) / 100 === target;
  el.textContent = `Sum: ${sum.toFixed(0)}%`;
  el.className = `wx-sum ${ok ? "ok" : "bad"}`;
}

function wireSumListeners(card) {
  const weatherInputs = [...card.querySelectorAll("input[data-kind='weather']")];
  const pitchInputs = [...card.querySelectorAll("input[data-kind='pitch']")];

  const refresh = () => {
    updateSumDisplay(card.querySelector(".wx-weather-sum-wrap"), pctSum(weatherInputs));
    updateSumDisplay(card.querySelector(".wx-pitch-sum-wrap"), pctSum(pitchInputs));
  };

  [...weatherInputs, ...pitchInputs].forEach((inp) => {
    inp.addEventListener("input", refresh);
  });
  refresh();
}

function renderConfig() {
  const root = document.getElementById("configRoot");
  if (!root) return;

  root.innerHTML = CONTINENTS.map((cont) => {
    const seasonCards = METEO_SEASONS.map((season) => {
      const row = configMap.get(configKey(cont.id, season.id)) || {};
      const months = gpslMonthsForContinentSeason(cont.id, season.id) || "—";

      const weatherInputs = WEATHER_KEYS.map((k) => {
        const field = `weather_${k}_pct`;
        return `<label>${WEATHER_LABELS[k]}
          <input type="number" min="0" max="100" step="1" data-kind="weather" data-field="${field}"
            value="${row[field] ?? ""}">%</label>`;
      }).join("");

      const pitchInputs = PITCH_KEYS.map((k) => {
        const field = `pitch_${k}_pct`;
        return `<label>${PITCH_LABELS[k]}
          <input type="number" min="0" max="100" step="1" data-kind="pitch" data-field="${field}"
            value="${row[field] ?? ""}">%</label>`;
      }).join("");

      return `
        <div class="wx-season-card" data-continent="${cont.id}" data-season="${season.id}">
          <div class="wx-season-title">${season.label}</div>
          <div class="wx-months">GPSL months: ${months || "—"}</div>
          <div class="wx-pct-group">
            <div class="wx-pct-label">Weather %</div>
            <div class="wx-pct-row">${weatherInputs}</div>
            <div class="wx-weather-sum-wrap"><span class="wx-sum">Sum: —</span></div>
          </div>
          <div class="wx-pct-group">
            <div class="wx-pct-label">Pitch %</div>
            <div class="wx-pct-row">${pitchInputs}</div>
            <div class="wx-pitch-sum-wrap"><span class="wx-sum">Sum: —</span></div>
          </div>
        </div>`;
    }).join("");

    return `
      <section class="wx-continent">
        <div class="wx-continent-head">${cont.label}</div>
        <div class="wx-season-grid">${seasonCards}</div>
      </section>`;
  }).join("");

  root.querySelectorAll(".wx-season-card").forEach((card) => wireSumListeners(card));
}

function collectRows() {
  const rows = [];

  for (const card of document.querySelectorAll(".wx-season-card")) {
    const continent = card.dataset.continent;
    const season = card.dataset.season;
    const row = { continent, meteorological_season: season };

    for (const inp of card.querySelectorAll("input[data-field]")) {
      row[inp.dataset.field] = Number(inp.value);
    }

    const wSum =
      (row.weather_fine_pct || 0) + (row.weather_rain_pct || 0) + (row.weather_snow_pct || 0);
    const pSum =
      (row.pitch_normal_pct || 0) + (row.pitch_dry_pct || 0) + (row.pitch_wet_pct || 0);

    if (Math.round(wSum) !== 100 || Math.round(pSum) !== 100) {
      throw new Error(
        `${continent} ${season}: weather and pitch percentages must each sum to 100`
      );
    }

    rows.push(row);
  }

  return rows;
}

async function loadConfig() {
  setStatus("pageStatus", "Loading…");
  const { data, error } = await supabase.rpc("competition_admin_continental_conditions_list");

  if (error) {
    setStatus(
      "pageStatus",
      "❌ " + error.message + " — run competition_continental_conditions.sql in Supabase.",
      false
    );
    return;
  }

  configMap.clear();
  for (const row of data || []) {
    configMap.set(
      configKey(row.continent, row.meteorological_season),
      row
    );
  }

  renderConfig();
  setStatus("pageStatus", `✅ Loaded ${(data || []).length} continent-season profiles.`, true);
}

async function saveConfig() {
  let rows;
  try {
    rows = collectRows();
  } catch (err) {
    setStatus("pageStatus", "❌ " + err.message, false);
    return;
  }

  setStatus("pageStatus", "Saving…");
  const { error } = await supabase.rpc("competition_admin_save_continental_conditions", {
    p_rows: rows,
  });

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("pageStatus", "✅ Saved all continent weather & pitch settings.", true);
  await loadConfig();
}

async function reapplyFixtures() {
  if (
    !confirm(
      "Re-roll weather, pitch, and kit for all scheduled fixtures in the active season?\n\nPlayed fixtures are not changed."
    )
  ) {
    return;
  }

  setStatus("pageStatus", "Re-rolling scheduled fixtures…");
  const { data, error } = await supabase.rpc("competition_admin_reapply_fixture_conditions", {
    p_season_id: null,
  });

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "pageStatus",
    `✅ Updated ${data?.fixtures_updated ?? 0} scheduled fixture(s).`,
    true
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("saveBtn").onclick = saveConfig;
  document.getElementById("reapplyBtn").onclick = reapplyFixtures;
  document.getElementById("reloadBtn").onclick = loadConfig;

  await loadConfig();
});
