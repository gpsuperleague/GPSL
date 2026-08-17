import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const NUM = [
  "budget",
  "squad_size",
  "starters",
  "max_per_club",
  "slot_gk",
  "slot_def",
  "slot_mid",
  "slot_fwd",
  "price_round_to",
  "price_floor",
  "free_transfers_per_month",
  "pts_appear",
  "pts_goal_gk",
  "pts_goal_def",
  "pts_goal_mid",
  "pts_goal_fwd",
  "pts_assist",
  "pts_cs_gk",
  "pts_cs_def",
  "pts_cs_mid",
  "pts_cs_fwd",
  "pts_yellow",
  "pts_red",
  "pts_potm",
  "captain_multiplier",
];

const BOOL = ["enabled", "opt_in_only", "require_stats_to_score"];

function fillForm(s) {
  for (const key of BOOL) {
    const el = document.getElementById(key);
    if (el) el.checked = Boolean(s?.[key]);
  }
  for (const key of NUM) {
    const el = document.getElementById(key);
    if (el && s?.[key] != null) el.value = s[key];
  }
  const div = document.getElementById("divisions");
  if (div) div.value = Array.isArray(s?.divisions) ? s.divisions.join(", ") : "";
  const ct = document.getElementById("competition_types");
  if (ct) ct.value = Array.isArray(s?.competition_types) ? s.competition_types.join(", ") : "";
}

function readForm() {
  const out = {};
  for (const key of BOOL) {
    out[key] = Boolean(document.getElementById(key)?.checked);
  }
  for (const key of NUM) {
    const el = document.getElementById(key);
    if (!el) continue;
    out[key] = Number(el.value);
  }
  out.divisions = String(document.getElementById("divisions")?.value || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
  out.competition_types = String(document.getElementById("competition_types")?.value || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
  return out;
}

async function load() {
  setStatus("status", "Loading…", true);
  const { data, error } = await supabase.rpc("admin_gpfl_settings_get");
  if (error) {
    setStatus(
      "status",
      error.message.includes("admin_gpfl_settings_get")
        ? "Run supabase/sql/patches/gpfl_fantasy_league_20260817.sql first."
        : error.message,
      false
    );
    return;
  }
  fillForm(data);
  setStatus("status", "Settings loaded.", true);
}

async function save() {
  const payload = readForm();
  setStatus("status", "Saving…", true);
  const { data, error } = await supabase.rpc("admin_gpfl_settings_set", {
    p_settings: payload,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  fillForm(data);
  setStatus(
    "status",
    "Saved. Open/refresh GPFL season on fantasy.html if the pool needs rebuilding.",
    true
  );
}

document.getElementById("saveBtn")?.addEventListener("click", () => save());

initAdminPage({ title: "GPFL settings" })
  .then(() => load())
  .catch((err) => setStatus("status", err?.message || String(err), false));
