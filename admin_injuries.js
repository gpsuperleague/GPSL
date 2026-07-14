import { initAdminPage, primeAdminPageChrome, supabase } from "./admin_common.js";
import { fullClubName, loadClubsMap } from "./clubs_lookup.js";

primeAdminPageChrome();

let settings = null;
let currentSeasonId = null;

function setStatus(id, msg, isError = false) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = isError ? "#f88" : "#8c8";
}

async function loadCurrentSeasonId() {
  const { data } = await supabase
    .from("competition_seasons")
    .select("id")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();
  currentSeasonId = data?.id ?? null;
}

function renderSettings() {
  const s = settings || {};
  const months = Array.isArray(s.preseason_months)
    ? s.preseason_months.join(",")
    : "may,june,july";
  document.getElementById("settingsGrid").innerHTML = `
    <div><label>Max major / season</label><input id="max_major" type="number" min="0" value="${s.max_major ?? 1}"></div>
    <div><label>Max moderate / season</label><input id="max_moderate" type="number" min="0" value="${s.max_moderate ?? 2}"></div>
    <div><label>Max minor / season</label><input id="max_minor" type="number" min="0" value="${s.max_minor ?? 4}"></div>
    <div><label>Max total / season</label><input id="max_total" type="number" min="0" value="${s.max_total ?? 4}"></div>
    <div><label>Base chance / club match</label><input id="base_match_chance" type="number" step="0.01" min="0" max="1" value="${s.base_match_chance ?? 0.15}"></div>
    <div><label>Weight Minor</label><input id="weight_minor" type="number" step="0.1" value="${s.weight_minor ?? 70}"></div>
    <div><label>Weight Moderate</label><input id="weight_moderate" type="number" step="0.1" value="${s.weight_moderate ?? 25}"></div>
    <div><label>Weight Major</label><input id="weight_major" type="number" step="0.1" value="${s.weight_major ?? 5}"></div>
    <div><label>Pre-season months (csv)</label><input id="preseason_months" type="text" value="${months}"></div>
    <div><label>Virtual matches / pre-season month</label><input id="preseason_matches_per_month" type="number" min="0" value="${s.preseason_matches_per_month ?? 4}"></div>
    <div><label>Risk min</label><input id="risk_min" type="number" step="0.01" value="${s.risk_min ?? 0.7}"></div>
    <div><label>Risk max</label><input id="risk_max" type="number" step="0.01" value="${s.risk_max ?? 1.3}"></div>
  `;
}

function readSettingsFromForm() {
  const monthsRaw = document.getElementById("preseason_months")?.value || "";
  const months = monthsRaw
    .split(",")
    .map((m) => m.trim().toLowerCase())
    .filter(Boolean);
  return {
    max_major: Number(document.getElementById("max_major").value),
    max_moderate: Number(document.getElementById("max_moderate").value),
    max_minor: Number(document.getElementById("max_minor").value),
    max_total: Number(document.getElementById("max_total").value),
    base_match_chance: Number(document.getElementById("base_match_chance").value),
    weight_minor: Number(document.getElementById("weight_minor").value),
    weight_moderate: Number(document.getElementById("weight_moderate").value),
    weight_major: Number(document.getElementById("weight_major").value),
    preseason_months: months,
    preseason_matches_per_month: Number(
      document.getElementById("preseason_matches_per_month").value
    ),
    risk_min: Number(document.getElementById("risk_min").value),
    risk_max: Number(document.getElementById("risk_max").value),
  };
}

async function loadSettings() {
  const { data, error } = await supabase.rpc("admin_injury_settings_get");
  if (error) {
    setStatus(
      "settingsStatus",
      error.message.includes("admin_injury_settings")
        ? "Run competition_injuries_engine.sql in Supabase first."
        : error.message,
      true
    );
    return;
  }
  settings = data;
  renderSettings();
}

async function saveSettings() {
  const payload = readSettingsFromForm();
  setStatus("settingsStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_injury_settings_save", {
    p_settings: payload,
  });
  if (error) {
    setStatus("settingsStatus", error.message, true);
    return;
  }
  settings = data;
  renderSettings();
  setStatus("settingsStatus", "Settings saved.");
}

async function initRisks() {
  if (!currentSeasonId) {
    setStatus("settingsStatus", "No current season.", true);
    return;
  }
  setStatus("settingsStatus", "Rolling club risk factors…");
  const { data, error } = await supabase.rpc("competition_injury_init_season_risks", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("settingsStatus", error.message, true);
    return;
  }
  setStatus("settingsStatus", `Risk factors ready for ${data?.clubs ?? 0} clubs.`);
  await loadRisks();
}

async function tickPreseason() {
  if (!currentSeasonId) {
    setStatus("preseasonStatus", "No current season.", true);
    return;
  }
  const month = document.getElementById("preseasonMonth")?.value;
  if (!confirm(`Apply pre-season recovery tick for ${month}?`)) return;
  setStatus("preseasonStatus", "Applying…");
  const { data, error } = await supabase.rpc("competition_injury_tick_preseason_month", {
    p_season_id: currentSeasonId,
    p_gpsl_month: month,
  });
  if (error) {
    setStatus("preseasonStatus", error.message, true);
    return;
  }
  if (data?.already_applied) {
    setStatus("preseasonStatus", `${month} already applied this season.`, true);
    return;
  }
  setStatus(
    "preseasonStatus",
    `Applied ${data?.ticks ?? 0} virtual matches to ${data?.injuries_updated ?? 0} injuries.`
  );
  await loadActive();
}

async function loadRisks() {
  const el = document.getElementById("risksPanel");
  const { data, error } = await supabase.rpc("admin_injury_club_risks", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    el.innerHTML = `<p class="note" style="color:#f88;">${error.message}</p>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    el.innerHTML =
      '<p class="note">No club risks yet — click “Roll club risk factors”.</p>';
    return;
  }
  el.innerHTML = `
    <table class="risk-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Risk</th>
          <th>Maj</th>
          <th>Mod</th>
          <th>Min</th>
          <th>Total</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${r.club_name || fullClubName(r.club_short_name) || r.club_short_name}</td>
            <td>${Number(r.injury_risk).toFixed(3)}</td>
            <td>${r.count_major}</td>
            <td>${r.count_moderate}</td>
            <td>${r.count_minor}</td>
            <td>${r.count_total}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function loadActive() {
  const el = document.getElementById("activePanel");
  const { data, error } = await supabase.rpc("admin_injury_active_list", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    el.innerHTML = `<p class="note" style="color:#f88;">${error.message}</p>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    el.innerHTML = '<p class="note">No active injuries.</p>';
    return;
  }
  el.innerHTML = `
    <table class="risk-table">
      <thead>
        <tr>
          <th>Player</th>
          <th>Club</th>
          <th>Injury</th>
          <th>Sev</th>
          <th>Out left</th>
          <th>Fitness left</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (r) => `
          <tr>
            <td>${r.player_name || r.player_id}</td>
            <td>${fullClubName(r.club_short_name) || r.club_short_name}</td>
            <td>${r.label || "—"}</td>
            <td>${r.severity || "—"}</td>
            <td>${r.matches_out_remaining ?? 0}</td>
            <td>${r.recovery_remaining ?? 0}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

async function seedDiscipline(force = false) {
  const msg = force
    ? "Force re-seed every club (cancel prior test injuries, add new suspension + injury)?"
    : "Seed 1 suspended + 1 injured player for every club?";
  if (!confirm(msg)) return;
  setStatus("seedStatus", "Seeding…");
  const { data, error } = await supabase.rpc("admin_test_seed_squad_discipline", {
    p_force: force,
  });
  if (error) {
    setStatus(
      "seedStatus",
      error.message.includes("admin_test_seed_squad_discipline")
        ? "Run admin_test_seed_squad_discipline.sql in Supabase first."
        : error.message,
      true
    );
    return;
  }
  setStatus(
    "seedStatus",
    `Seeded ${data?.clubs_seeded ?? 0} clubs (${data?.suspensions ?? 0} suspensions, ${data?.injuries ?? 0} injuries, ${data?.skipped ?? 0} skipped).`
  );
  await loadRisks();
  await loadActive();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  await loadClubsMap();
  await loadCurrentSeasonId();
  await loadSettings();
  await loadRisks();
  await loadActive();

  document.getElementById("saveSettingsBtn")?.addEventListener("click", () => {
    void saveSettings();
  });
  document.getElementById("initRisksBtn")?.addEventListener("click", () => {
    void initRisks();
  });
  document.getElementById("tickPreseasonBtn")?.addEventListener("click", () => {
    void tickPreseason();
  });
  document.getElementById("seedDisciplineBtn")?.addEventListener("click", () => {
    void seedDiscipline(false);
  });
  document.getElementById("seedDisciplineForceBtn")?.addEventListener("click", () => {
    void seedDiscipline(true);
  });
});
