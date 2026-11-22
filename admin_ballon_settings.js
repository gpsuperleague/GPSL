import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { renderRulesPanel } from "./gpsl_rules_cards.js?v=20260817-ballon";

primeAdminPageChrome();

const SIMPLE_FIELDS = [
  "min_appearances",
  "champ_min_appearances",
  "weight_apps",
  "trophy_superleague",
  "trophy_superleague_runner_up",
  "trophy_superleague_third",
  "trophy_world_cup",
  "trophy_world_cup_runner_up",
  "trophy_world_cup_third",
  "trophy_super8",
  "trophy_super8_runner_up",
  "trophy_league_cup",
  "trophy_league_cup_runner_up",
  "trophy_plate",
  "trophy_plate_runner_up",
  "trophy_shield",
  "trophy_shield_runner_up",
  "trophy_bowl",
  "trophy_bowl_runner_up",
  "trophy_premier_challenge",
  "trophy_premier_challenge_runner_up",
];

const PLAYSTYLES = [
  ["goal_poacher", "Goal Poacher"],
  ["fox_in_the_box", "Fox in the Box"],
  ["deep_lying_forward", "Deep-Lying Forward"],
  ["target_man", "Target Man"],
  ["dummy_runner", "Dummy Runner"],
  ["hole_player", "Hole Player"],
  ["creative_playmaker", "Creative Playmaker"],
  ["classic_10", "Classic No. 10"],
  ["prolific_winger", "Prolific Winger"],
  ["roaming_flank", "Roaming Flank"],
  ["cross_specialist", "Cross Specialist"],
  ["box_to_box", "Box-to-Box"],
  ["orchestrator", "Orchestrator"],
  ["anchor_man", "Anchor Man"],
  ["destroyer", "The Destroyer"],
  ["offensive_full_back", "Offensive Full-back"],
  ["full_back_finisher", "Full-back Finisher"],
  ["defensive_full_back", "Defensive Full-back"],
  ["build_up", "Build Up"],
  ["extra_frontman", "Extra Frontman"],
  ["goalkeeper", "Any goalkeeper"],
];

const METRICS = ["rating", "contributions", "clean_sheet", "potm"];

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
            "Average rating, goal contributions, clean sheets, and POTM each use the player’s playstyle.",
            "Goal contributions are goals plus assists in every competition.",
            "No playstyle: forwards count as Goal Poacher, midfielders as Box-to-Box, defenders as Build Up, goalkeepers as any goalkeeper.",
            "Appearances still add their own weight.",
            "The total is multiplied by the club’s Super League points ÷ 100.",
          ],
        },
        {
          heading: "Trophies",
          items: [
            "Winner, runner-up, and third for the Super League and the World Cup.",
            "Winner and runner-up for Super 8, League Cup, Plate, Shield, Bowl, and the Premier Challenge Cup.",
            "League places need 5 league appearances. Cup places need one appearance in that cup.",
            "Premier Challenge Cup points wait until that competition has a recorded winner.",
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

function ensurePlaystyleRows() {
  const body = document.getElementById("playstyleWeights");
  if (!body || body.childElementCount) return;
  body.innerHTML = PLAYSTYLES.map(([key, label]) => {
    const cells = METRICS.map(
      (metric) =>
        `<td><input type="number" step="0.01" id="ps_${key}_${metric}" data-ps="${key}" data-metric="${metric}"></td>`
    ).join("");
    return `<tr><td>${label}</td>${cells}</tr>`;
  }).join("");
}

function fillForm(settings) {
  ensurePlaystyleRows();
  for (const key of SIMPLE_FIELDS) {
    const el = document.getElementById(key);
    if (!el || settings?.[key] == null) continue;
    el.value = settings[key];
  }
  const weights = settings?.playstyle_weights || {};
  for (const [key] of PLAYSTYLES) {
    const row = weights[key] || {};
    for (const metric of METRICS) {
      const el = document.getElementById(`ps_${key}_${metric}`);
      if (!el || row[metric] == null) continue;
      el.value = row[metric];
    }
  }
}

function readForm() {
  const out = {};
  for (const key of SIMPLE_FIELDS) {
    const el = document.getElementById(key);
    if (!el) continue;
    out[key] = Number(el.value);
  }
  const weights = {};
  for (const [key] of PLAYSTYLES) {
    weights[key] = {};
    for (const metric of METRICS) {
      const el = document.getElementById(`ps_${key}_${metric}`);
      weights[key][metric] = Number(el?.value);
    }
  }
  out.playstyle_weights = weights;
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
  ensurePlaystyleRows();
  document.getElementById("ballonForm")?.addEventListener("submit", saveSettings);
  document.getElementById("reloadBtn")?.addEventListener("click", loadSettings);
  if (!(await initAdminPage())) return;
  await loadSettings();
});
