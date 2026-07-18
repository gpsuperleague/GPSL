import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { CUP_LABELS, formatMoney } from "./competition.js";

primeAdminPageChrome();

const CUP_PRIZE_STAGE_LABELS = {
  appearance: "Appearance",
  r1: "Round 1",
  r2: "Round 2",
  qf: "Quarter-final",
  sf: "Semi-final",
  final: "Final",
};

/** @type {{ id: number, label?: string, status?: string, is_current?: boolean }[]} */
let seasons = [];
let selectedSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("compCupSelect").onchange = loadCupPrizeConfig;
  document.getElementById("compSavePrizeBtn").onclick = saveCompetitionCupPrize;
  document.getElementById("compAwardCupPrizeBtn").onclick = awardCupRoundPrize;
  document.getElementById("cupPrizeSeasonSelect")?.addEventListener("change", () => {
    syncCopyFromSelect();
    loadCupPrizeConfig();
  });
  document.getElementById("copyCupPrizesBtn")?.addEventListener("click", copyCupPrizesFromSeason);

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

  const order = ["appearance", "r1", "r2", "qf", "sf", "final"];
  const sorted = [...data].sort(
    (a, b) => order.indexOf(a.stage) - order.indexOf(b.stage)
  );

  listEl.innerHTML = sorted
    .map(
      (row) =>
        `<div><b>${CUP_PRIZE_STAGE_LABELS[row.stage] || row.stage}</b>: ${formatMoney(row.amount)}</div>`
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
    `✅ ${CUP_PRIZE_STAGE_LABELS[stage] || stage} prize saved for ${cup}.`,
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
