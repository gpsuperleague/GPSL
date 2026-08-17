import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260817-ballon";

primeAdminPageChrome();

const FIELDS = [
  "min_appearances",
  "champ_min_appearances",
  "weight_rating",
  "weight_goals_att_am",
  "weight_goals_other",
  "weight_assists_mid_att_fb",
  "weight_assists_other",
  "weight_cs_gk_def_dmf",
  "weight_cs_other",
  "weight_potm",
  "weight_apps",
  "trophy_superleague",
  "trophy_super8",
  "trophy_plate",
  "trophy_shield",
  "trophy_world_cup",
];

function renderRules() {
  renderRulesPanel(
    document.getElementById("ballonRules"),
    {
      title: "Ballon d'Or",
      lead: `Super League only. Championship clubs have <b>Championship Player of the Season</b> instead.
        Live top-20 race is on <a href="league_stats.html">League Stats</a>. Winner settles at season archive.`,
      cards: [
        {
          heading: "Scoring",
          items: [
            "Rating average × weight.",
            "Goals weighted higher for CF / SS / AMF / WG.",
            "Assists weighted for mids, attackers, and full-backs.",
            "Clean sheets for GK / CB / FB / DMF.",
            "Optional POTM + appearance factors.",
          ],
        },
        {
          heading: "Trophies",
          items: [
            "Bonuses for Super League, Super 8, Plate, Shield (player must have contributed apps).",
            "World Cup bonus if the player’s nation is recorded as champion.",
            "Mid-season race shows trophies only once they are decided.",
          ],
        },
        {
          heading: "Eligibility",
          items: [
            "Default minimum <b>20 appearances</b> (configurable).",
            "Championship players are never eligible for the Ballon.",
          ],
        },
      ],
    },
    { rootClass: "info-box info-box--wide ballon-rules" }
  );
}

function fillForm(settings) {
  for (const key of FIELDS) {
    const el = document.getElementById(key);
    if (!el || settings?.[key] == null) continue;
    el.value = settings[key];
  }
}

function readForm() {
  const out = {};
  for (const key of FIELDS) {
    const el = document.getElementById(key);
    if (!el) continue;
    out[key] = Number(el.value);
  }
  return out;
}

async function loadSettings() {
  setStatus("statusLine", "Loading…", true);
  const { data, error } = await supabase.rpc("admin_ballon_settings_get");
  if (error) {
    setStatus(
      "statusLine",
      error.message.includes("admin_ballon_settings_get")
        ? "Run supabase/sql/patches/ballon_dor_settings_race_20260817.sql first."
        : error.message,
      false
    );
    return;
  }
  fillForm(data);
  setStatus("statusLine", "Settings loaded.", true);
}

async function saveSettings(event) {
  event?.preventDefault?.();
  setStatus("statusLine", "Saving…", true);
  const { data, error } = await supabase.rpc("admin_ballon_settings_set", {
    p_settings: readForm(),
  });
  if (error) {
    setStatus("statusLine", error.message, false);
    return;
  }
  fillForm(data);
  setStatus("statusLine", "Saved. Live race and archive settle use these weights.", true);
}

document.addEventListener("DOMContentLoaded", async () => {
  renderRules();
  document.getElementById("ballonForm")?.addEventListener("submit", saveSettings);
  document.getElementById("reloadBtn")?.addEventListener("click", loadSettings);
  if (!(await initAdminPage())) return;
  await loadSettings();
});
