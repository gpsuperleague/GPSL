import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

/** Keep in sync with match_sim_default_outcome_bands() in SQL. */
const DEFAULT_BANDS = [
  {
    id: "even",
    title: "Even contest",
    blurb: "XI strengths are almost identical. Small home lean; draws common.",
    min_diff: 0,
    mode: "sides",
    home_pct: 40,
    draw_pct: 50,
    away_pct: 10,
  },
  {
    id: "slight",
    title: "Slight edge",
    blurb: "One XI is a bit stronger. Favourite usually wins; upsets still happen.",
    min_diff: 15,
    mode: "fav",
    fav_pct: 55,
    draw_pct: 25,
    upset_pct: 20,
  },
  {
    id: "clear",
    title: "Clear favourite",
    blurb: "A clear gap on paper. Favourite wins most of the time.",
    min_diff: 30,
    mode: "fav",
    fav_pct: 65,
    draw_pct: 20,
    upset_pct: 15,
  },
  {
    id: "strong",
    title: "Strong favourite",
    blurb: "Big XI gap. Upsets are uncommon.",
    min_diff: 50,
    mode: "fav",
    fav_pct: 75,
    draw_pct: 15,
    upset_pct: 10,
  },
  {
    id: "mismatch",
    title: "Mismatch",
    blurb: "Huge gap — favourite almost always wins.",
    min_diff: 80,
    mode: "fav",
    fav_pct: 100,
    draw_pct: 0,
    upset_pct: 0,
  },
];

const DEFAULTS = {
  yellow_per_match: 3,
  red_chance_pct: 5,
  cards_enabled: true,
  injuries_enabled: true,
  max_subs_on: 5,
  outcome_bands: DEFAULT_BANDS,
};

/** @type {Array<object>} */
let bandsState = structuredClone(DEFAULT_BANDS);

function updateBadge(enabled) {
  const badge = document.getElementById("armBadge");
  if (!badge) return;
  badge.textContent = enabled ? "ON" : "OFF";
  badge.className = enabled ? "arm-badge arm-on" : "arm-badge arm-off";
}

function num(id, fallback) {
  const raw = Number(document.getElementById(id)?.value);
  return Number.isFinite(raw) ? raw : fallback;
}

function clampPct(n) {
  const v = Math.trunc(Number(n));
  if (!Number.isFinite(v)) return 0;
  return Math.max(0, Math.min(100, v));
}

function normalizeBand(raw) {
  const mode = String(raw?.mode || "fav").toLowerCase() === "sides" ? "sides" : "fav";
  const minDiff = Math.max(0, Math.min(500, Math.trunc(Number(raw?.min_diff) || 0)));
  const base = {
    id: String(raw?.id || `band_${minDiff}`),
    title: String(raw?.title || `Band from ${minDiff}`),
    blurb: String(raw?.blurb || ""),
    min_diff: minDiff,
    mode,
  };
  if (mode === "sides") {
    const home = clampPct(raw?.home_pct ?? 40);
    const draw = clampPct(Math.min(100 - home, raw?.draw_pct ?? 50));
    return { ...base, home_pct: home, draw_pct: draw, away_pct: Math.max(0, 100 - home - draw) };
  }
  const fav = clampPct(raw?.fav_pct ?? 60);
  const draw = clampPct(Math.min(100 - fav, raw?.draw_pct ?? 20));
  return { ...base, fav_pct: fav, draw_pct: draw, upset_pct: Math.max(0, 100 - fav - draw) };
}

function normalizeBands(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_BANDS;
  const sorted = src
    .map((b) => normalizeBand(b))
    .sort((a, b) => a.min_diff - b.min_diff || String(a.id).localeCompare(String(b.id)));
  let prev = -1;
  return sorted.map((b) => {
    let min = b.min_diff;
    if (min < prev) min = prev;
    prev = min;
    return { ...b, min_diff: min };
  });
}

function bandRangeLabel(band, nextMin) {
  if (nextMin == null) return `${band.min_diff}+ rating points`;
  return `${band.min_diff}–${nextMin - 1} rating points`;
}

function bandSum(band) {
  if (band.mode === "sides") {
    return (band.home_pct ?? 0) + (band.draw_pct ?? 0) + (band.away_pct ?? 0);
  }
  return (band.fav_pct ?? 0) + (band.draw_pct ?? 0) + (band.upset_pct ?? 0);
}

function pickBandFromForm(absDiff) {
  const bands = normalizeBands(bandsState);
  let best = bands[0];
  for (const b of bands) {
    if (absDiff >= b.min_diff) best = b;
  }
  return { band: best, bands };
}

function oddsFromBand(band, homeStr, awayStr) {
  const diff = homeStr - awayStr;
  const abs = Math.abs(diff);
  const homeFav = diff >= 0;
  let homePct;
  let drawPct;
  let awayPct;
  if (band.mode === "sides") {
    homePct = band.home_pct;
    drawPct = band.draw_pct;
    awayPct = band.away_pct;
  } else if (homeFav) {
    homePct = band.fav_pct;
    drawPct = band.draw_pct;
    awayPct = band.upset_pct;
  } else {
    homePct = band.upset_pct;
    drawPct = band.draw_pct;
    awayPct = band.fav_pct;
  }
  return { diff, abs, homeFav, homePct, drawPct, awayPct };
}

function renderBands() {
  const host = document.getElementById("bandsHost");
  if (!host) return;
  bandsState = normalizeBands(bandsState);

  host.innerHTML = bandsState
    .map((band, i) => {
      const next = bandsState[i + 1];
      const range = bandRangeLabel(band, next?.min_diff);
      const sum = bandSum(band);
      const sumOk = sum === 100;
      const modeLabel =
        band.mode === "sides"
          ? "Home / Draw / Away (no favourite)"
          : "Favourite / Draw / Upset";

      const fields =
        band.mode === "sides"
          ? `
          <label>From gap ≥
            <input type="number" data-band="${i}" data-key="min_diff" min="0" max="500" value="${band.min_diff}">
          </label>
          <label>Home %
            <input type="number" data-band="${i}" data-key="home_pct" min="0" max="100" value="${band.home_pct}">
          </label>
          <label>Draw %
            <input type="number" data-band="${i}" data-key="draw_pct" min="0" max="100" value="${band.draw_pct}">
          </label>
          <label>Away % <span style="color:#666;font-weight:400">(auto)</span>
            <input type="number" value="${band.away_pct}" disabled title="Fills the remainder to 100%">
          </label>`
          : `
          <label>From gap ≥
            <input type="number" data-band="${i}" data-key="min_diff" min="0" max="500" value="${band.min_diff}">
          </label>
          <label>Favourite win %
            <input type="number" data-band="${i}" data-key="fav_pct" min="0" max="100" value="${band.fav_pct}">
          </label>
          <label>Draw %
            <input type="number" data-band="${i}" data-key="draw_pct" min="0" max="100" value="${band.draw_pct}">
          </label>
          <label>Upset % <span style="color:#666;font-weight:400">(auto)</span>
            <input type="number" value="${band.upset_pct}" disabled title="Fills the remainder to 100%">
          </label>`;

      return `
        <div class="band-card" data-band-card="${i}">
          <div class="band-head">
            <h3 class="band-title">${escapeHtml(band.title)}</h3>
            <span class="band-range">${escapeHtml(range)}</span>
          </div>
          <p class="band-blurb">${escapeHtml(band.blurb)}</p>
          <span class="band-mode">${escapeHtml(modeLabel)}</span>
          <div class="band-fields">${fields}</div>
          <div class="band-sum ${sumOk ? "ok" : "bad"}" data-sum="${i}">
            ${sumOk ? `Totals ${sum}% ✓` : `Totals ${sum}% — must be 100`}
          </div>
        </div>`;
    })
    .join("");

  host.querySelectorAll("input[data-band]").forEach((el) => {
    el.addEventListener("change", onBandInput);
  });
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function onBandInput(ev) {
  const el = ev.target;
  const i = Number(el.dataset.band);
  const key = el.dataset.key;
  if (!Number.isFinite(i) || !bandsState[i] || !key) return;

  const raw = Number(el.value);
  if (!Number.isFinite(raw)) return;

  if (key === "min_diff") {
    bandsState[i].min_diff = Math.max(0, Math.min(500, Math.trunc(raw)));
  } else {
    bandsState[i][key] = clampPct(raw);
  }

  bandsState = normalizeBands(bandsState);
  renderBands();
}

function applySettingsToForm(settings) {
  const s = { ...DEFAULTS, ...(settings || {}) };
  const map = {
    yellowPerMatch: s.yellow_per_match,
    redChancePct: s.red_chance_pct,
    maxSubsOn: s.max_subs_on,
  };
  for (const [id, val] of Object.entries(map)) {
    const el = document.getElementById(id);
    if (el && val != null) el.value = String(val);
  }
  const cards = document.getElementById("cardsEnabled");
  const injuries = document.getElementById("injuriesEnabled");
  if (cards) cards.checked = s.cards_enabled !== false;
  if (injuries) injuries.checked = s.injuries_enabled !== false;

  bandsState = normalizeBands(s.outcome_bands);
  renderBands();
}

function readSettingsFromForm() {
  bandsState = normalizeBands(bandsState);
  return {
    yellow_per_match: Math.max(0, Math.min(22, Math.trunc(num("yellowPerMatch", 3)))),
    red_chance_pct: (() => {
      const raw = Number(document.getElementById("redChancePct")?.value);
      const v = Number.isFinite(raw) ? raw : 5;
      return Math.max(0, Math.min(100, v));
    })(),
    cards_enabled: !!document.getElementById("cardsEnabled")?.checked,
    injuries_enabled: !!document.getElementById("injuriesEnabled")?.checked,
    max_subs_on: Math.max(0, Math.min(5, Math.trunc(num("maxSubsOn", 5)))),
    outcome_bands: bandsState,
  };
}

async function loadStatus() {
  const { data, error } = await supabase.rpc("match_result_simulation_status");
  if (error) {
    setStatus("status", "Run match_result_simulation_settings.sql — " + error.message, false);
    return;
  }
  updateBadge(!!data?.enabled);
  applySettingsToForm(data?.settings);
  setStatus(
    "status",
    data?.enabled
      ? "Simulation enabled — owners can Simulate from My Club Fixtures."
      : "Simulation disabled.",
    true
  );
}

async function setEnabled(enabled) {
  const msg = enabled
    ? "Enable match simulation for owners? Use for full test seasons only."
    : "Disable match simulation? Simulate buttons will hide.";
  if (!confirm(msg)) return;

  setStatus("status", "Updating…");
  const { data, error } = await supabase.rpc("admin_set_match_result_simulation_enabled", {
    p_enabled: enabled,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  updateBadge(!!data?.match_result_simulation_enabled);
  setStatus(
    "status",
    data?.match_result_simulation_enabled ? "Simulation ON." : "Simulation OFF.",
    true
  );
}

async function saveSettings() {
  const settings = readSettingsFromForm();
  const bad = settings.outcome_bands.find((b) => bandSum(b) !== 100);
  if (bad) {
    setStatus("settingsStatus", `"${bad.title}" percentages must total 100.`, false);
    return;
  }
  setStatus("settingsStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_set_match_sim_settings", {
    p_settings: settings,
  });
  if (error) {
    setStatus(
      "settingsStatus",
      `Failed: ${error.message}. Run match_result_simulation_outcome_bands.sql.`,
      false
    );
    return;
  }
  applySettingsToForm(data?.settings);
  const s = data?.settings || settings;
  const n = Array.isArray(s.outcome_bands) ? s.outcome_bands.length : 0;
  setStatus(
    "settingsStatus",
    `Saved ${n} win bands · ${s.yellow_per_match}Y/match · ${s.red_chance_pct}% red` +
      `${s.cards_enabled ? "" : " · cards off"}` +
      `${s.injuries_enabled ? "" : " · injuries off"}.`,
    true
  );
}

function calculateOdds() {
  const home = num("calcHomeStr", 850);
  const away = num("calcAwayStr", 785);
  const box = document.getElementById("oddsResult");
  if (!box) return;

  const { band, bands } = pickBandFromForm(Math.abs(home - away));
  const odds = oddsFromBand(band, home, away);
  const idx = bands.findIndex((b) => b.id === band.id && b.min_diff === band.min_diff);
  const next = bands[idx + 1];
  const range = bandRangeLabel(band, next?.min_diff);
  const favLabel =
    band.mode === "sides"
      ? "no favourite (home lean)"
      : odds.homeFav
        ? "Home favourite"
        : "Away favourite";

  box.hidden = false;
  box.innerHTML = `
    <div>
      Gap <strong>${odds.abs.toFixed(0)}</strong>
      (home ${home.toFixed(0)} − away ${away.toFixed(0)} = ${odds.diff >= 0 ? "+" : ""}${odds.diff.toFixed(0)})
    </div>
    <div style="margin-top:6px;">
      Band <strong>${escapeHtml(band.title)}</strong> · ${escapeHtml(range)}
    </div>
    <div style="margin-top:6px;color:#aaa;font-size:13px;">${escapeHtml(favLabel)}</div>
    <div style="margin-top:10px;">
      Home <strong>${odds.homePct}%</strong>
      · Draw <strong>${odds.drawPct}%</strong>
      · Away <strong>${odds.awayPct}%</strong>
    </div>
    <div class="hint" style="margin-top:8px;">
      Preview from the form above — Save to apply to Simulate.
    </div>
  `;
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  await loadStatus();
  document.getElementById("enableBtn")?.addEventListener("click", () => setEnabled(true));
  document.getElementById("disableBtn")?.addEventListener("click", () => setEnabled(false));
  document.getElementById("saveSettingsBtn")?.addEventListener("click", () => saveSettings());
  document.getElementById("resetDefaultsBtn")?.addEventListener("click", () => {
    applySettingsToForm(DEFAULTS);
    setStatus("settingsStatus", "Defaults loaded in form — click Save settings to apply.", true);
  });
  document.getElementById("calcOddsBtn")?.addEventListener("click", () => calculateOdds());
});
