import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const DEFAULTS = {
  yellow_per_month: 15,
  red_per_month: 1,
  cards_enabled: true,
  injuries_enabled: true,
  max_subs_on: 5,
  blowout_diff: 100,
  strong_diff: 50,
  strong_fav_pct: 60,
  strong_draw_pct: 20,
  close_home_pct: 20,
  close_away_pct: 20,
  close_draw_pct: 60,
};

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

function applySettingsToForm(settings) {
  const s = { ...DEFAULTS, ...(settings || {}) };
  const map = {
    yellowPerMonth: s.yellow_per_month,
    redPerMonth: s.red_per_month,
    maxSubsOn: s.max_subs_on,
    blowoutDiff: s.blowout_diff,
    strongDiff: s.strong_diff,
    strongFavPct: s.strong_fav_pct,
    strongDrawPct: s.strong_draw_pct,
    closeHomePct: s.close_home_pct,
    closeAwayPct: s.close_away_pct,
  };
  for (const [id, val] of Object.entries(map)) {
    const el = document.getElementById(id);
    if (el && val != null) el.value = String(val);
  }
  const cards = document.getElementById("cardsEnabled");
  const injuries = document.getElementById("injuriesEnabled");
  if (cards) cards.checked = s.cards_enabled !== false;
  if (injuries) injuries.checked = s.injuries_enabled !== false;
  renderBandsTable(s);
  updateBandHint(s);
}

function readSettingsFromForm() {
  const strongFav = Math.max(0, Math.min(100, Math.trunc(num("strongFavPct", 60))));
  const strongDraw = Math.max(0, Math.min(100 - strongFav, Math.trunc(num("strongDrawPct", 20))));
  const closeHome = Math.max(0, Math.min(100, Math.trunc(num("closeHomePct", 20))));
  const closeAway = Math.max(0, Math.min(100 - closeHome, Math.trunc(num("closeAwayPct", 20))));
  const blowout = Math.max(1, Math.min(500, Math.trunc(num("blowoutDiff", 100))));
  const strong = Math.max(0, Math.min(blowout, Math.trunc(num("strongDiff", 50))));

  return {
    yellow_per_month: Math.max(0, Math.min(200, Math.trunc(num("yellowPerMonth", 15)))),
    red_per_month: Math.max(0, Math.min(50, Math.trunc(num("redPerMonth", 1)))),
    cards_enabled: !!document.getElementById("cardsEnabled")?.checked,
    injuries_enabled: !!document.getElementById("injuriesEnabled")?.checked,
    max_subs_on: Math.max(0, Math.min(5, Math.trunc(num("maxSubsOn", 5)))),
    blowout_diff: blowout,
    strong_diff: strong,
    strong_fav_pct: strongFav,
    strong_draw_pct: strongDraw,
    strong_upset_pct: Math.max(0, 100 - strongFav - strongDraw),
    close_home_pct: closeHome,
    close_away_pct: closeAway,
    close_draw_pct: Math.max(0, 100 - closeHome - closeAway),
  };
}

function updateBandHint(s) {
  const el = document.getElementById("bandSumHint");
  if (!el) return;
  const settings = s || readSettingsFromForm();
  const upset = Math.max(0, 100 - (settings.strong_fav_pct ?? 60) - (settings.strong_draw_pct ?? 20));
  const closeDraw = Math.max(0, 100 - (settings.close_home_pct ?? 20) - (settings.close_away_pct ?? 20));
  el.textContent =
    `Strong upset auto = ${upset}% · Close draw auto = ${closeDraw}% (bands must sum to 100).`;
}

function renderBandsTable(settings) {
  const body = document.getElementById("oddsBandsBody");
  if (!body) return;
  const s = { ...DEFAULTS, ...(settings || {}) };
  const upset = Math.max(0, 100 - s.strong_fav_pct - s.strong_draw_pct);
  const closeDraw = Math.max(0, 100 - s.close_home_pct - s.close_away_pct);
  body.innerHTML = `
    <tr>
      <td>0 – ${s.strong_diff - 1} (close)</td>
      <td colspan="3">Home ${s.close_home_pct}% · Draw ${closeDraw}% · Away ${s.close_away_pct}% <span style="color:#888">(no favourite)</span></td>
    </tr>
    <tr>
      <td>${s.strong_diff} – ${s.blowout_diff - 1} (strong)</td>
      <td>${s.strong_fav_pct}%</td>
      <td>${s.strong_draw_pct}%</td>
      <td>${upset}%</td>
    </tr>
    <tr>
      <td>${s.blowout_diff}+ (blowout)</td>
      <td>100%</td>
      <td>0%</td>
      <td>0%</td>
    </tr>
  `;
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
  setStatus("settingsStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_set_match_sim_settings", {
    p_settings: settings,
  });
  if (error) {
    setStatus(
      "settingsStatus",
      `Failed: ${error.message}. Run match_result_simulation_outcome_bands.sql if win-band fields fail.`,
      false
    );
    return;
  }
  applySettingsToForm(data?.settings);
  const s = data?.settings || settings;
  setStatus(
    "settingsStatus",
    `Saved bands + ${s.yellow_per_month}Y/${s.red_per_month}R` +
      `${s.cards_enabled ? "" : " · cards off"}` +
      `${s.injuries_enabled ? "" : " · injuries off"}.`,
    true
  );
}

async function calculateOdds() {
  const home = num("calcHomeStr", 800);
  const away = num("calcAwayStr", 780);
  const box = document.getElementById("oddsResult");
  if (!box) return;

  // Prefer live RPC (uses saved DB settings). Fall back to form bands if RPC missing.
  const { data, error } = await supabase.rpc("match_sim_outcome_odds", {
    p_home_str: home,
    p_away_str: away,
  });

  if (!error && data?.ok) {
    box.hidden = false;
    box.innerHTML = `
      <div><strong>Diff</strong> ${Number(data.diff).toFixed(0)} (abs ${Number(data.abs_diff).toFixed(0)}) · band <strong>${data.band}</strong></div>
      <div style="margin-top:8px;">
        Home <strong>${data.home_pct}%</strong>
        · Draw <strong>${data.draw_pct}%</strong>
        · Away <strong>${data.away_pct}%</strong>
      </div>
      <div class="hint" style="margin-top:8px;">${data.note || ""}</div>
    `;
    return;
  }

  // Client-side fallback from form
  const s = readSettingsFromForm();
  const diff = home - away;
  const abs = Math.abs(diff);
  const homeFav = diff >= 0;
  let homePct;
  let drawPct;
  let awayPct;
  let band;
  if (abs >= s.blowout_diff) {
    band = "blowout";
    homePct = homeFav ? 100 : 0;
    drawPct = 0;
    awayPct = homeFav ? 0 : 100;
  } else if (abs >= s.strong_diff) {
    band = "strong";
    const upset = s.strong_upset_pct;
    homePct = homeFav ? s.strong_fav_pct : upset;
    drawPct = s.strong_draw_pct;
    awayPct = homeFav ? upset : s.strong_fav_pct;
  } else {
    band = "close";
    homePct = s.close_home_pct;
    drawPct = s.close_draw_pct;
    awayPct = s.close_away_pct;
  }
  box.hidden = false;
  box.innerHTML = `
    <div><strong>Diff</strong> ${diff.toFixed(0)} · band <strong>${band}</strong>${error ? " (local preview — save/run SQL for live RPC)" : ""}</div>
    <div style="margin-top:8px;">
      Home <strong>${homePct}%</strong>
      · Draw <strong>${drawPct}%</strong>
      · Away <strong>${awayPct}%</strong>
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
  ["strongDiff", "blowoutDiff", "strongFavPct", "strongDrawPct", "closeHomePct", "closeAwayPct"].forEach(
    (id) => {
      document.getElementById(id)?.addEventListener("input", () => {
        const s = readSettingsFromForm();
        renderBandsTable(s);
        updateBandHint(s);
      });
    }
  );
});
