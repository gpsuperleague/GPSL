import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { LEAGUE_DIVISIONS } from "./competition.js";

primeAdminPageChrome();

const LEAGUE_PRIZE_POSITIONS = 20;

let currentSeasonId = null;
/** @type {{ id: number, label?: string, status?: string, is_current?: boolean }[]} */
let seasons = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  await loadSeasons();
  buildLeaguePrizeGrid();
  await loadLeaguePrizeSettings();

  document.getElementById("saveLeaguePrizesBtn").onclick = saveLeaguePrizes;
  document.getElementById("seedLeaguePrizesBtn").onclick = seedLeaguePrizes;
  document.getElementById("payLeaguePrizesBtn").onclick = payLeaguePrizes;
  document.getElementById("copyLeaguePrizesBtn").onclick = () => copyLeaguePrizes(false);
  document.getElementById("copySaveLeaguePrizesBtn").onclick = () => copyLeaguePrizes(true);
  document.getElementById("copyLeaguePrizesSeasonBtn").onclick = copyLeaguePrizesFromSeason;
  document.getElementById("leaguePrizeSeasonSelect")?.addEventListener("change", () => {
    const v = Number(document.getElementById("leaguePrizeSeasonSelect")?.value);
    currentSeasonId = Number.isFinite(v) ? v : null;
    syncCopySeasonOptions();
    loadLeaguePrizeSettings();
  });
  document.getElementById("leaguePrizeDivision").onchange = () => {
    syncCopyFromOptions();
    loadLeaguePrizeSettings();
  };
  syncCopyFromOptions();
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

function syncCopySeasonOptions() {
  const copySel = document.getElementById("leaguePrizeCopySeasonFrom");
  if (!copySel) return;
  const others = seasons.filter((s) => Number(s.id) !== Number(currentSeasonId));
  copySel.innerHTML =
    `<option value="">Select season…</option>` + others.map(seasonOptionHtml).join("");
  const prior = others.find((s) => Number(s.id) < Number(currentSeasonId)) || others[0];
  if (prior) copySel.value = String(prior.id);
}

async function loadSeasons() {
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });
  if (error) throw error;
  seasons = data || [];
  const sel = document.getElementById("leaguePrizeSeasonSelect");
  if (sel) {
    sel.innerHTML = seasons.map(seasonOptionHtml).join("");
    const current = seasons.find((s) => s.is_current) || seasons[0];
    if (current) {
      sel.value = String(current.id);
      currentSeasonId = current.id;
    }
  } else {
    await loadCurrentSeasonId();
  }
  syncCopySeasonOptions();
}

async function copyLeaguePrizesFromSeason() {
  const toId = currentSeasonId;
  const fromRaw = document.getElementById("leaguePrizeCopySeasonFrom")?.value;
  const fromId = fromRaw ? Number(fromRaw) : null;
  if (!toId || !fromId) {
    setStatus("leaguePrizeStatus", "Choose source and target seasons.", false);
    return;
  }
  if (fromId === toId) {
    setStatus("leaguePrizeStatus", "Source and target are the same.", false);
    return;
  }
  if (
    !confirm(
      `Copy all league prize amounts from season ${fromId} into season ${toId}?\n\nAll divisions on the target are overwritten.`
    )
  ) {
    return;
  }

  setStatus("leaguePrizeStatus", "Copying…");
  const { data, error } = await supabase.rpc("competition_admin_copy_league_prizes", {
    p_from_season_id: fromId,
    p_to_season_id: toId,
  });
  if (error) {
    setStatus(
      "leaguePrizeStatus",
      error.message.includes("competition_admin_copy_league_prizes")
        ? "Run patches/prize_config_persist_across_seasons.sql first."
        : "❌ " + error.message,
      false
    );
    return;
  }
  await loadLeaguePrizeSettings();
  setStatus(
    "leaguePrizeStatus",
    `✅ Copied ${data?.rows_copied ?? 0} league prize row(s) from season ${fromId} → ${toId}.`,
    true
  );
}

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

  setStatus(
    "leaguePrizeStatus",
    `Loaded ${DIVISION_LABELS[division] || division} prizes.`,
    true
  );
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

  setStatus(
    "leaguePrizeStatus",
    `✅ Saved ${data ?? 0} position(s) for ${DIVISION_LABELS[division] || division}.`,
    true
  );
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
