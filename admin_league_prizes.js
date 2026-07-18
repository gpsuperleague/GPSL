import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { LEAGUE_DIVISIONS } from "./competition.js";

primeAdminPageChrome();

const LEAGUE_PRIZE_POSITIONS = 20;

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadCurrentSeasonId();
  buildLeaguePrizeGrid();
  await loadLeaguePrizeSettings();

  document.getElementById("saveLeaguePrizesBtn").onclick = saveLeaguePrizes;
  document.getElementById("seedLeaguePrizesBtn").onclick = seedLeaguePrizes;
  document.getElementById("payLeaguePrizesBtn").onclick = payLeaguePrizes;
  document.getElementById("copyLeaguePrizesBtn").onclick = () => copyLeaguePrizes(false);
  document.getElementById("copySaveLeaguePrizesBtn").onclick = () => copyLeaguePrizes(true);
  document.getElementById("leaguePrizeDivision").onchange = () => {
    syncCopyFromOptions();
    loadLeaguePrizeSettings();
  };
  syncCopyFromOptions();
});

const DIVISION_LABELS = {
  superleague: "SuperLeague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};

function syncCopyFromOptions() {
  const target = document.getElementById("leaguePrizeDivision")?.value;
  const copySel = document.getElementById("leaguePrizeCopyFrom");
  if (!copySel) return;
  const prev = copySel.value;
  copySel.innerHTML =
    `<option value="">Select division…</option>` +
    LEAGUE_DIVISIONS.filter((d) => d !== target)
      .map(
        (d) =>
          `<option value="${d}">${DIVISION_LABELS[d] || d}</option>`
      )
      .join("");
  if (prev && prev !== target && LEAGUE_DIVISIONS.includes(prev)) {
    copySel.value = prev;
  }
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

function buildLeaguePrizeGrid() {
  const grid = document.getElementById("leaguePrizeGrid");
  if (!grid) return;
  const rows = [];
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    rows.push(`
      <label class="league-prize-cell">
        <span>#${pos}</span>
        <input type="number" id="leaguePrizePos${pos}" min="0" step="100000" value="0" style="width:120px;">
      </label>
    `);
  }
  grid.innerHTML = rows.join("");
}

async function loadLeaguePrizeSettings() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current competition season.", false);
    return;
  }

  const division = document.getElementById("leaguePrizeDivision").value;
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    const el = document.getElementById(`leaguePrizePos${pos}`);
    if (el) el.value = "0";
  }

  const { data, error } = await supabase
    .from("competition_league_prize_config_public")
    .select("position, amount")
    .eq("season_id", currentSeasonId)
    .eq("division", division);

  if (error) {
    setStatus(
      "leaguePrizeStatus",
      "❌ " + error.message + " — run competition_league_prizes.sql",
      false
    );
    return;
  }

  for (const row of data || []) {
    const el = document.getElementById(`leaguePrizePos${row.position}`);
    if (el) el.value = String(row.amount ?? 0);
  }

  setStatus("leaguePrizeStatus", `Loaded ${division} prizes for season ${currentSeasonId}.`, true);
}

function leaguePrizeAmountsPayload() {
  /** @type {Record<string, number>} */
  const amounts = {};
  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    const el = document.getElementById(`leaguePrizePos${pos}`);
    amounts[String(pos)] = Number(el?.value) || 0;
  }
  return amounts;
}

async function saveLeaguePrizes() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current season.", false);
    return;
  }

  const division = document.getElementById("leaguePrizeDivision").value;
  if (!LEAGUE_DIVISIONS.includes(division)) {
    setStatus("leaguePrizeStatus", "Invalid division.", false);
    return;
  }

  setStatus("leaguePrizeStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_save_league_prizes", {
    p_season_id: currentSeasonId,
    p_division: division,
    p_amounts: leaguePrizeAmountsPayload(),
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("leaguePrizeStatus", `✅ Saved ${data ?? 0} position(s) for ${division}.`, true);
}

async function seedLeaguePrizes() {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current season.", false);
    return;
  }

  setStatus("leaguePrizeStatus", "Loading defaults…");
  const { data, error } = await supabase.rpc("competition_admin_seed_league_prize_defaults", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  await loadLeaguePrizeSettings();
  setStatus(
    "leaguePrizeStatus",
    `✅ Default prize table applied (${data ?? 0} new rows). Edit and Save per division if needed.`,
    true
  );
}

async function payLeaguePrizes() {
  setStatus("leaguePrizeStatus", "Paying…");
  const { data, error } = await supabase.rpc("competition_admin_pay_league_prizes", {
    p_season_id: currentSeasonId,
  });

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  const paid = data?.clubs_paid ?? 0;
  const byDiv = data?.by_division ?? {};
  setStatus(
    "leaguePrizeStatus",
    `✅ Paid ${paid} club(s). SL: ${byDiv.superleague ?? 0}, CH A: ${byDiv.championship_a ?? 0}, CH B: ${byDiv.championship_b ?? 0}. (Only divisions with 38/38 played.)`,
    true
  );
}

async function copyLeaguePrizes(alsoSave) {
  if (!currentSeasonId) {
    setStatus("leaguePrizeStatus", "No current season.", false);
    return;
  }

  const target = document.getElementById("leaguePrizeDivision")?.value;
  const source = document.getElementById("leaguePrizeCopyFrom")?.value;

  if (!source || !LEAGUE_DIVISIONS.includes(source)) {
    setStatus("leaguePrizeStatus", "Choose a division to copy from.", false);
    return;
  }
  if (source === target) {
    setStatus("leaguePrizeStatus", "Source and editing division are the same.", false);
    return;
  }

  setStatus(
    "leaguePrizeStatus",
    `Copying from ${DIVISION_LABELS[source] || source}…`
  );

  const { data, error } = await supabase
    .from("competition_league_prize_config_public")
    .select("position, amount")
    .eq("season_id", currentSeasonId)
    .eq("division", source);

  if (error) {
    setStatus("leaguePrizeStatus", "❌ " + error.message, false);
    return;
  }

  if (!data?.length) {
    setStatus(
      "leaguePrizeStatus",
      `⚠ ${DIVISION_LABELS[source] || source} has no saved prizes to copy.`,
      false
    );
    return;
  }

  for (let pos = 1; pos <= LEAGUE_PRIZE_POSITIONS; pos++) {
    const el = document.getElementById(`leaguePrizePos${pos}`);
    if (el) el.value = "0";
  }
  for (const row of data) {
    const el = document.getElementById(`leaguePrizePos${row.position}`);
    if (el) el.value = String(row.amount ?? 0);
  }

  const srcLabel = DIVISION_LABELS[source] || source;
  const tgtLabel = DIVISION_LABELS[target] || target;

  if (!alsoSave) {
    setStatus(
      "leaguePrizeStatus",
      `Copied ${data.length} position(s) from ${srcLabel} into the form for ${tgtLabel}. Click Save prizes to keep.`,
      true
    );
    return;
  }

  setStatus("leaguePrizeStatus", "Saving copied prizes…");
  const { data: saved, error: saveErr } = await supabase.rpc(
    "competition_admin_save_league_prizes",
    {
      p_season_id: currentSeasonId,
      p_division: target,
      p_amounts: leaguePrizeAmountsPayload(),
    }
  );

  if (saveErr) {
    setStatus("leaguePrizeStatus", "❌ " + saveErr.message, false);
    return;
  }

  setStatus(
    "leaguePrizeStatus",
    `✅ Copied & saved ${saved ?? data.length} position(s) from ${srcLabel} → ${tgtLabel}.`,
    true
  );
}
