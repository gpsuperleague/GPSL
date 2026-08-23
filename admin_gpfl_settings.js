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
  "price_ceiling",
  "free_transfers_per_month",
  "transfer_hit_points",
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
  "prize_season_1",
  "prize_season_2",
  "prize_season_3",
  "prize_month_1",
  "prize_month_2",
  "prize_month_3",
];

const BOOL = [
  "enabled",
  "opt_in_only",
  "require_stats_to_score",
  "chips_enabled",
  "chip_wildcard_enabled",
  "chip_triple_captain_enabled",
  "chip_bench_boost_enabled",
  "cash_prizes_enabled",
];

function fillForm(s) {
  for (const key of BOOL) {
    const el = document.getElementById(key);
    if (el) el.checked = Boolean(s?.[key]);
  }
  for (const key of NUM) {
    const el = document.getElementById(key);
    if (el && s?.[key] != null) el.value = s[key];
  }
  const mode = document.getElementById("deadline_mode");
  if (mode && s?.deadline_mode) mode.value = s.deadline_mode;
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
  const mode = document.getElementById("deadline_mode")?.value;
  if (mode) out.deadline_mode = mode;
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
        ? "Run gpfl_fantasy_league_20260817.sql (then gpfl_v2 patches) first."
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
    "Saved. Open/refresh GPFL season on fantasy.html to rebuild fantasy prices (not GPSL MV) if the pool needs updating.",
    true
  );
}

document.getElementById("saveBtn")?.addEventListener("click", () => save());

async function paySeason() {
  if (!confirm("Pay GPFL season top-3 cash prizes to owner wallets?")) return;
  setStatus("status", "Paying season prizes…", true);
  const { data, error } = await supabase.rpc("admin_gpfl_pay_season_prizes", {
    p_gpfl_season_id: null,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  setStatus(
    "status",
    data?.skipped && data?.reason === "disabled"
      ? "Cash prizes disabled in settings."
      : `Season prizes: paid ${data?.paid ?? 0}, skipped ${data?.skipped ?? 0}, total ₿${data?.total_amount ?? 0}.`,
    true
  );
}

async function payMonth() {
  const month = document.getElementById("payMonthSelect")?.value;
  if (!month) return;
  if (!confirm(`Pay GPFL ${month} month top-3 cash prizes to owner wallets?`)) return;
  setStatus("status", `Paying ${month} prizes…`, true);
  const { data, error } = await supabase.rpc("admin_gpfl_pay_month_prizes", {
    p_gpsl_month: month,
    p_gpfl_season_id: null,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  setStatus(
    "status",
    data?.skipped && data?.reason === "disabled"
      ? "Cash prizes disabled in settings."
      : `${month}: paid ${data?.paid ?? 0}, skipped ${data?.skipped ?? 0}, total ₿${data?.total_amount ?? 0}.`,
    true
  );
}

document.getElementById("paySeasonBtn")?.addEventListener("click", () => paySeason());
document.getElementById("payMonthBtn")?.addEventListener("click", () => payMonth());

initAdminPage({ title: "GPFL settings" })
  .then(() => load())
  .catch((err) => setStatus("status", err?.message || String(err), false));
