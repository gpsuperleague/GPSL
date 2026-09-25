import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { CUP_LABELS, formatMoney } from "./competition.js";

primeAdminPageChrome();

const STAGE_ORDER = [
  "appearance",
  "r1",
  "r32",
  "r2",
  "r16",
  "qf",
  "sf",
  "winner",
  "runner_up",
  "final",
];

/**
 * Stage options per cup. League Cup has separate Last 64 / 32 / 16.
 * @param {string} cup
 * @returns {{ value: string, label: string }[]}
 */
function stagesForCup(cup) {
  const appearance = { value: "appearance", label: "Appearance (optional extra)" };
  const finals = [
    { value: "winner", label: "Winner" },
    { value: "runner_up", label: "Runner-up" },
    { value: "sf", label: "Semi-final" },
    { value: "qf", label: "Quarter-final" },
  ];

  if (cup === "league_cup") {
    return [
      ...finals,
      { value: "r16", label: "Last 16" },
      { value: "r32", label: "Last 32" },
      { value: "r1", label: "Last 64" },
      appearance,
    ];
  }
  if (cup === "shield") {
    return [
      ...finals,
      { value: "r2", label: "Last 16" },
      { value: "r1", label: "Last 32" },
      appearance,
    ];
  }
  if (cup === "plate") {
    return [...finals, { value: "r2", label: "Last 16" }, appearance];
  }
  if (cup === "super8" || cup === "bowl") {
    return [...finals, appearance];
  }
  return [
    ...finals,
    { value: "r2", label: "Round 2" },
    { value: "r1", label: "Round 1" },
    appearance,
  ];
}

function stageLabel(cup, stage) {
  return stagesForCup(cup).find((s) => s.value === stage)?.label || stage;
}

function fillStageSelects(cup) {
  const stages = stagesForCup(cup);
  const saveSel = document.getElementById("compPrizeStage");
  const overrideSel = document.getElementById("compOverrideStage");

  if (saveSel) {
    const prev = saveSel.value;
    saveSel.innerHTML = stages
      .map((s) => `<option value="${s.value}">${escapeHtml(s.label)}</option>`)
      .join("");
    if (stages.some((s) => s.value === prev)) saveSel.value = prev;
  }

  if (overrideSel) {
    const prev = overrideSel.value;
    overrideSel.innerHTML =
      `<option value="">Auto (from fixture round)</option>` +
      stages.map((s) => `<option value="${s.value}">${escapeHtml(s.label)}</option>`).join("");
    if (prev === "" || stages.some((s) => s.value === prev)) overrideSel.value = prev;
  }
}

/** @type {{ id: number, label?: string, status?: string, is_current?: boolean }[]} */
let seasons = [];
let selectedSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("compCupSelect").onchange = () => {
    fillStageSelects(document.getElementById("compCupSelect").value);
    loadCupPrizeConfig();
  };
  document.getElementById("compSavePrizeBtn").onclick = saveCompetitionCupPrize;
  document.getElementById("compAwardCupPrizeBtn").onclick = awardCupRoundPrize;
  document.getElementById("cupPrizeSeasonSelect")?.addEventListener("change", () => {
    syncCopyFromSelect();
    loadCupPrizeConfig();
  });
  document.getElementById("copyCupPrizesBtn")?.addEventListener("click", copyCupPrizesFromSeason);
  document.getElementById("saveCupPrizeTemplateBtn")?.addEventListener("click", saveCupPrizeTemplate);
  document.getElementById("applyCupPrizeTemplateBtn")?.addEventListener("click", applyCupPrizeTemplate);

  fillStageSelects(document.getElementById("compCupSelect")?.value || "super8");
  await loadSeasons();
  await loadCupPrizeConfig();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function seasonOptionHtml(s) {
  const tag = s.is_current ? " (current)" : ` (${s.status || ""})`;
  return `<option value="${s.id}">${escapeHtml(s.label || `Season ${s.id}`)}${tag}</option>`;
}

function seasonId() {
  const sel = document.getElementById("cupPrizeSeasonSelect");
  const v = sel?.value ? Number(sel.value) : null;
  return Number.isFinite(v) ? v : selectedSeasonId;
}

function syncCopyFromSelect() {
  const copySel = document.getElementById("cupPrizeCopyFrom");
  const target = seasonId();
  if (!copySel) return;
  const others = seasons.filter((s) => Number(s.id) !== Number(target));
  copySel.innerHTML =
    `<option value="">Select season…</option>` + others.map(seasonOptionHtml).join("");
  const prior = others.find((s) => Number(s.id) < Number(target)) || others[0];
  if (prior) copySel.value = String(prior.id);
}

async function loadSeasons() {
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });
  if (error) throw error;
  seasons = data || [];
  const sel = document.getElementById("cupPrizeSeasonSelect");
  if (!sel) return;
  sel.innerHTML = seasons.map(seasonOptionHtml).join("");
  const current = seasons.find((s) => s.is_current) || seasons[0];
  if (current) {
    sel.value = String(current.id);
    selectedSeasonId = current.id;
  }
  syncCopyFromSelect();
}

async function loadCupPrizeConfig() {
  const listEl = document.getElementById("compCupPrizeList");
  const sid = seasonId();
  const cup = document.getElementById("compCupSelect").value;

  if (!listEl) return;
  fillStageSelects(cup);

  if (!sid) {
    listEl.textContent = "No competition season found.";
    return;
  }

  selectedSeasonId = sid;

  const { data, error } = await supabase
    .from("competition_cup_prize_config_public")
    .select("stage, amount")
    .eq("season_id", sid)
    .eq("cup_code", cup)
    .order("stage");

  if (error) {
    listEl.textContent = `Could not load prizes — run competition_cup_prizes_fix.sql (${error.message})`;
    return;
  }

  if (!data?.length) {
    listEl.textContent = `No prizes saved for ${CUP_LABELS[cup] || cup} on this season yet. Copy from a previous season or save amounts below.`;
    return;
  }

  const sorted = [...data].sort(
    (a, b) => STAGE_ORDER.indexOf(a.stage) - STAGE_ORDER.indexOf(b.stage)
  );

  listEl.innerHTML = sorted
    .map(
      (row) =>
        `<div><b>${escapeHtml(stageLabel(cup, row.stage))}</b>: ${formatMoney(row.amount)}</div>`
    )
    .join("");
}

async function copyCupPrizesFromSeason() {
  const toId = seasonId();
  const fromRaw = document.getElementById("cupPrizeCopyFrom")?.value;
  const fromId = fromRaw ? Number(fromRaw) : null;
  if (!toId || !fromId) {
    setStatus("compPrizeStatus", "Choose source and target seasons.", false);
    return;
  }
  if (fromId === toId) {
    setStatus("compPrizeStatus", "Source and target are the same.", false);
    return;
  }
  if (
    !confirm(
      `Copy all cup prize amounts from season ${fromId} into season ${toId}?\n\nExisting stages on the target are overwritten.`
    )
  ) {
    return;
  }

  setStatus("compPrizeStatus", "Copying…");
  const { data, error } = await supabase.rpc("competition_admin_copy_cup_prizes", {
    p_from_season_id: fromId,
    p_to_season_id: toId,
  });
  if (error) {
    setStatus(
      "compPrizeStatus",
      error.message.includes("competition_admin_copy_cup_prizes")
        ? "Run patches/prize_config_persist_across_seasons.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  await loadCupPrizeConfig();
  setStatus(
    "compPrizeStatus",
    `✅ Copied ${data?.rows_copied ?? 0} cup prize row(s) from season ${fromId} → ${toId}.`,
    true
  );
}

async function saveCompetitionCupPrize() {
  const sid = seasonId();
  const cup = document.getElementById("compCupSelect").value;
  const stage = document.getElementById("compPrizeStage").value;
  const amount = Number(document.getElementById("compPrizeAmount").value) || 0;

  if (!sid) {
    setStatus("compPrizeStatus", "No season selected.", false);
    return;
  }

  const { error } = await supabase.rpc("competition_admin_set_cup_prize", {
    p_season_id: sid,
    p_cup_code: cup,
    p_stage: stage,
    p_amount: amount,
  });

  if (error) {
    setStatus("compPrizeStatus", "❌ " + error.message, false);
    return;
  }

  await loadCupPrizeConfig();
  setStatus(
    "compPrizeStatus",
    `✅ ${stageLabel(cup, stage)} prize saved for ${CUP_LABELS[cup] || cup}.`,
    true
  );
}

async function awardCupRoundPrize() {
  const fixtureId = Number(document.getElementById("compOverrideFixtureId").value);
  const club = document.getElementById("compOverrideClub").value.trim();
  const stage = document.getElementById("compOverrideStage").value.trim();
  const note = document.getElementById("compOverrideNote").value.trim();

  if (!Number.isFinite(fixtureId) || fixtureId <= 0) {
    setStatus("compOverrideStatus", "Enter a valid fixture ID.", false);
    return;
  }
  if (!club) {
    setStatus("compOverrideStatus", "Enter club ShortName.", false);
    return;
  }

  if (!confirm(`Award cup round prize to ${club} for fixture ${fixtureId}?`)) return;

  setStatus("compOverrideStatus", "Awarding…");
  const { data, error } = await supabase.rpc("competition_admin_award_cup_round_prize", {
    p_fixture_id: fixtureId,
    p_club_short_name: club,
    p_stage: stage || null,
    p_note: note || null,
  });

  if (error) {
    setStatus("compOverrideStatus", "❌ " + error.message, false);
    return;
  }

  setStatus(
    "compOverrideStatus",
    `✅ Awarded ${formatMoney(data?.amount ?? 0)} to ${club}${data?.stage ? ` (${data.stage})` : ""}.`,
    true
  );
}

async function saveCupPrizeTemplate() {
  const sid = seasonId();
  if (!sid) {
    setStatus("compPrizeStatus", "No season selected.", false);
    return;
  }
  if (
    !confirm(
      "Save this season’s cup prize table as the reset template?\n\nIt will survive a full league reset and be restored when you create the next season."
    )
  ) {
    return;
  }
  setStatus("compPrizeStatus", "Saving reset template…");
  const { data, error } = await supabase.rpc("competition_admin_save_cup_prize_template", {
    p_season_id: sid,
  });
  if (error) {
    setStatus(
      "compPrizeStatus",
      error.message.includes("competition_admin_save_cup_prize_template")
        ? "Run patches/prize_templates_survive_reset_20260925.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  setStatus(
    "compPrizeStatus",
    `✅ Reset template saved (${data?.rows_saved ?? 0} row(s) from season ${sid}).`,
    true
  );
}

async function applyCupPrizeTemplate() {
  const sid = seasonId();
  if (!sid) {
    setStatus("compPrizeStatus", "No season selected.", false);
    return;
  }
  if (
    !confirm(
      `Apply the cup prize reset template into season ${sid}?\n\nExisting cup prize amounts on this season will be overwritten.`
    )
  ) {
    return;
  }
  setStatus("compPrizeStatus", "Applying reset template…");
  const { data, error } = await supabase.rpc("competition_admin_apply_cup_prize_template", {
    p_season_id: sid,
  });
  if (error) {
    setStatus(
      "compPrizeStatus",
      error.message.includes("competition_admin_apply_cup_prize_template")
        ? "Run patches/prize_templates_survive_reset_20260925.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  if (data?.ok === false && data?.reason === "no_template") {
    setStatus("compPrizeStatus", "No cup prize reset template saved yet.", false);
    return;
  }
  await loadCupPrizeConfig();
  setStatus(
    "compPrizeStatus",
    `✅ Applied reset template (${data?.rows_applied ?? 0} row(s)) to season ${sid}.`,
    true
  );
}
