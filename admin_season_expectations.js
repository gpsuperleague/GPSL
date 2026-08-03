import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
let seasonLabel = "";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("refreshBtn").onclick = () => loadBoard();
  for (const id of ["filterDivision", "filterTier", "filterBand", "filterMgr"]) {
    document.getElementById(id)?.addEventListener("change", renderTable);
  }

  await loadBoard();
});

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function divLabel(d) {
  return (
    {
      superleague: "SuperLeague",
      championship_a: "Champ A",
      championship_b: "Champ B",
    }[d] || d || "—"
  );
}

function formatPts(n) {
  if (n == null || n === "") return "—";
  const x = Number(n);
  if (!Number.isFinite(x)) return "—";
  return x.toFixed(1);
}

function bandPill(band) {
  if (!band) return '<span class="met-pend">—</span>';
  const label = String(band).replace(/_/g, " ");
  return `<span class="band-pill band-${escapeHtml(band)}">${escapeHtml(label)}</span>`;
}

function metCell(met) {
  if (met === true) return '<span class="met-yes">HIT</span>';
  if (met === false) return '<span class="met-no">MISS</span>';
  return '<span class="met-pend">—</span>';
}

function conseqClass(text) {
  const t = String(text || "").toLowerCase();
  if (t.includes("released") || t.includes("forced") || t.includes("0 hits")) return "bad";
  if (t.includes("miss") || t.includes("renewal") || t.includes("mid-deal")) return "warn";
  if (t.includes("on target") || t.includes("bonus")) return "ok";
  return "";
}

function filteredRows() {
  const div = document.getElementById("filterDivision")?.value || "";
  const tier = document.getElementById("filterTier")?.value || "";
  const band = document.getElementById("filterBand")?.value || "";
  const mgr = document.getElementById("filterMgr")?.value || "";

  return allRows.filter((row) => {
    if (div && row.division !== div) return false;
    if (tier && row.tier !== tier) return false;
    if (band && row.club_performance_band !== band) return false;
    if (mgr === "vacant" && row.manager_id) return false;
    if (mgr === "hit" && row.manager_target_met !== true) return false;
    if (mgr === "miss" && row.manager_target_met !== false) return false;
    if (mgr === "risk") {
      if (!row.manager_id) return false;
      const hits =
        Number(row.manager_deal_hits || 0) +
        (row.manager_target_met === true ? 1 : 0);
      const endDeal =
        row.manager_pending_renewal ||
        Number(row.manager_seasons_remaining ?? 99) <= 1;
      if (!endDeal || hits > 0) return false;
    }
    return true;
  });
}

function renderSummary() {
  const el = document.getElementById("summaryStrip");
  if (!el) return;

  let missClub = 0;
  let mgrHit = 0;
  let mgrMiss = 0;
  let mgrRisk = 0;
  let vacant = 0;

  for (const row of allRows) {
    if (row.club_missed_expectation) missClub += 1;
    if (!row.manager_id) vacant += 1;
    else if (row.manager_target_met === true) mgrHit += 1;
    else if (row.manager_target_met === false) mgrMiss += 1;

    if (row.manager_id) {
      const hits =
        Number(row.manager_deal_hits || 0) +
        (row.manager_target_met === true ? 1 : 0);
      const endDeal =
        row.manager_pending_renewal ||
        Number(row.manager_seasons_remaining ?? 99) <= 1;
      if (endDeal && hits <= 0) mgrRisk += 1;
    }
  }

  el.innerHTML = `
    <span><b>${escapeHtml(seasonLabel || "Current season")}</b></span>
    <span><b>${allRows.length}</b> clubs</span>
    <span>Club misses: <b>${missClub}</b></span>
    <span>Mgr HIT ${mgrHit} · MISS ${mgrMiss} · vacant ${vacant}</span>
    <span>Mgr EOS release risk: <b>${mgrRisk}</b></span>
  `;
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  const countEl = document.getElementById("rowCount");
  if (!wrap) return;

  const rows = filteredRows();
  renderSummary();

  if (countEl) {
    countEl.textContent =
      rows.length === allRows.length
        ? `Showing all ${rows.length}`
        : `Showing ${rows.length} of ${allRows.length}`;
  }

  if (!rows.length) {
    wrap.innerHTML = '<p style="padding:16px;color:#888;">No rows match filters.</p>';
    return;
  }

  wrap.innerHTML = `
    <table class="exp-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Owner</th>
          <th>Manager</th>
          <th>Club expect</th>
          <th>Club actual</th>
          <th>Band</th>
          <th>Club EOS</th>
          <th>Mgr target</th>
          <th>Mgr actual</th>
          <th>Deal</th>
          <th>Manager EOS</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const tier = row.tier || "low";
            const clubExp =
              row.club_expected_position != null
                ? `P${row.club_expected_position} · ${formatPts(row.club_expected_points)} pts`
                : "—";
            const clubAct =
              row.club_actual_position != null
                ? `P${row.club_actual_position} · ${formatPts(row.club_actual_points)} pts`
                : "—";
            const mgrTarget = row.manager_target_label
              ? escapeHtml(row.manager_target_label)
              : "—";
            const mgrAct =
              row.manager_season_position != null
                ? `P${row.manager_season_position}`
                : "—";
            const deal =
              row.manager_id == null
                ? "—"
                : `${row.manager_seasons_remaining ?? "?"} left · ${row.manager_deal_hits ?? 0}H/${row.manager_deal_misses ?? 0}M`;
            const clubC = escapeHtml(row.club_eos_consequence || "—");
            const mgrC = escapeHtml(row.manager_eos_consequence || "—");

            return `<tr>
              <td>
                <div class="club-name">${escapeHtml(row.club_name)}</div>
                <div class="club-short">${escapeHtml(divLabel(row.division))} ·
                  <span class="tier-${escapeHtml(tier)}">${escapeHtml(tier)}</span> ·
                  ${escapeHtml(row.club_short_name)}</div>
              </td>
              <td>${escapeHtml(row.owner_name || "—")}</td>
              <td>${
                row.manager_name
                  ? `${escapeHtml(row.manager_name)} <span class="club-short">(${escapeHtml(row.manager_rating)})</span>`
                  : "—"
              }</td>
              <td>${escapeHtml(clubExp)}</td>
              <td>${escapeHtml(clubAct)}</td>
              <td>${bandPill(row.club_performance_band)}</td>
              <td class="conseq ${conseqClass(row.club_eos_consequence)}">${clubC}</td>
              <td>${mgrTarget}<div>${metCell(row.manager_target_met)}</div></td>
              <td>${escapeHtml(mgrAct)}</td>
              <td>${escapeHtml(deal)}</td>
              <td class="conseq ${conseqClass(row.manager_eos_consequence)}">${mgrC}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;
}

async function loadBoard() {
  setStatus("statusLine", "Loading expectations board…");
  const { data, error } = await supabase.rpc("admin_season_expectations_board", {
    p_season_id: null,
  });

  if (error) {
    setStatus(
      "statusLine",
      error.message.includes("admin_season_expectations_board")
        ? "❌ Run supabase/sql/patches/admin_season_expectations_board.sql in Supabase first."
        : "❌ " + error.message,
      false
    );
    return;
  }

  if (!data?.ok) {
    setStatus("statusLine", data?.reason || "Board failed.", false);
    allRows = [];
    renderTable();
    return;
  }

  seasonLabel = data.season_label || "";
  allRows = Array.isArray(data.rows) ? data.rows : [];
  setStatus(
    "statusLine",
    `Loaded ${allRows.length} club(s) for ${seasonLabel || "current season"}.`,
    true
  );
  renderTable();
}
