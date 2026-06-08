import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

/** @type {Array<Record<string, unknown>>} */
let allRows = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("refreshTableBtn").onclick = () => loadTable();
  document.getElementById("syncFillBtn").onclick = syncFill;
  document.getElementById("recomputeBtn").onclick = recomputeRankings;
  document.getElementById("saveOverridesBtn").onclick = saveOverrides;
  document.getElementById("filterTier").onchange = renderTable;
  document.getElementById("filterBand").onchange = renderTable;

  await loadTable();
});

function formatLastSeasons(json) {
  if (!json || !Array.isArray(json) || !json.length) return "—";
  return json
    .slice(0, 5)
    .map((s) => {
      const pts = Number(s.season_total || 0).toFixed(1);
      const pos = s.final_position != null ? `P${s.final_position}` : "—";
      return `${s.season_label || "?"}: ${pts} (${pos})`;
    })
    .join("<br>");
}

function bandClass(band) {
  return `band-pill band-${band || "slight"}`;
}

function tierClass(tier) {
  return `tier-${tier || "low"}`;
}

function filteredRows() {
  const tier = document.getElementById("filterTier")?.value || "";
  const band = document.getElementById("filterBand")?.value || "";
  return allRows.filter((row) => {
    if (tier && row.effective_tier !== tier) return false;
    if (band && row.performance_band !== band) return false;
    return true;
  });
}

function renderSummary(rows) {
  const el = document.getElementById("summaryStrip");
  if (!el) return;

  const tiers = { big: 0, medium: 0, low: 0 };
  const bands = { on_target: 0, slight: 0, bad: 0, abysmal: 0 };
  for (const row of rows) {
    const t = row.effective_tier || "low";
    if (tiers[t] != null) tiers[t] += 1;
    const b = row.performance_band || "slight";
    if (bands[b] != null) bands[b] += 1;
  }

  el.innerHTML = `
    <span><b>${rows.length}</b> clubs</span>
    <span>Tiers: ${tiers.big} big · ${tiers.medium} med · ${tiers.low} low</span>
    <span>Status: ${bands.on_target} on target · ${bands.slight} slight · ${bands.bad} bad · ${bands.abysmal} abysmal</span>
  `;
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  const countEl = document.getElementById("rowCount");
  if (!wrap) return;

  const rows = filteredRows();
  renderSummary(allRows);

  if (countEl) {
    countEl.textContent =
      rows.length === allRows.length
        ? `Showing all ${rows.length}`
        : `Showing ${rows.length} of ${allRows.length}`;
  }

  if (!rows.length) {
    wrap.innerHTML = '<p class="note">No clubs match this filter.</p>';
    return;
  }

  wrap.innerHTML = `
    <table class="att-table">
      <thead>
        <tr>
          <th>#</th>
          <th>Club</th>
          <th>Tier</th>
          <th>Override</th>
          <th>Mgr</th>
          <th>Status</th>
          <th>Exp pos</th>
          <th>Act pos</th>
          <th>Exp pts</th>
          <th>Act pts</th>
          <th>Gap</th>
          <th>Start %</th>
          <th>Display %</th>
          <th>Gate %</th>
          <th>Cushion</th>
          <th>Target %</th>
          <th>Base %</th>
          <th>5y pts</th>
          <th>Cap</th>
          <th>5y history</th>
          <th>Projection</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const band = row.performance_band || "—";
            const gap = Number(row.performance_gap || 0);
            const gapStr =
              gap > 0 ? `+${gap.toFixed(2)}` : gap < 0 ? gap.toFixed(2) : "0";
            const cushion = Number(row.cushion_pct || 0);
            return `
          <tr data-club="${row.club_short_name}">
            <td class="rank">${row.prestige_rank}</td>
            <td>
              <div class="club-name">${row.club_name || row.club_short_name}</div>
              <div class="club-short">${row.club_short_name}</div>
            </td>
            <td class="${tierClass(row.effective_tier)}"><b>${row.effective_tier}</b></td>
            <td>
              <select class="club-tier-override" data-club="${row.club_short_name}">
                <option value="auto" ${!row.tier_override ? "selected" : ""}>Auto</option>
                <option value="big" ${row.tier_override === "big" ? "selected" : ""}>Big</option>
                <option value="medium" ${row.tier_override === "medium" ? "selected" : ""}>Medium</option>
                <option value="low" ${row.tier_override === "low" ? "selected" : ""}>Low</option>
              </select>
            </td>
            <td>
              <input type="number" class="club-mgr-rating" data-club="${row.club_short_name}"
                min="1" max="99" step="1" style="width:48px;background:#222;color:#ddd;border:1px solid #444;"
                value="${row.manager_rating ?? ""}" placeholder="—">
            </td>
            <td><span class="${bandClass(band)}">${band}</span></td>
            <td>${row.expected_position ?? "—"}</td>
            <td>${row.actual_position ?? "—"}</td>
            <td>${Number(row.expected_points || 0).toFixed(2)}</td>
            <td>${Number(row.actual_points || 0).toFixed(2)}</td>
            <td>${gapStr}</td>
            <td>${row.stadium_season_start_fill_pct ?? "—"}</td>
            <td>${row.stadium_display_fill_pct ?? "—"}</td>
            <td class="fill-gate">${row.gate_fill_pct ?? "—"}</td>
            <td class="fill-cushion">${cushion > 0 ? "+" + cushion : "—"}</td>
            <td>${row.stadium_fill_target_pct ?? "—"}</td>
            <td>${row.prestige_base_fill_pct != null ? Number(row.prestige_base_fill_pct).toFixed(1) : "—"}</td>
            <td>${Number(row.rolling_points || 0).toFixed(1)} <span class="club-short">(${row.rolling_seasons_count ?? 0}y)</span></td>
            <td>${Number(row.capacity || 0).toLocaleString("en-GB")}</td>
            <td class="hist-cell">${formatLastSeasons(row.last_seasons_json)}</td>
            <td class="proj-cell">${row.projection_note || "—"}</td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

function formatLoadError(error) {
  if (!error) return "Unknown error";
  const parts = [error.message, error.details, error.hint].filter(Boolean);
  return parts.join(" — ");
}

async function fetchOverviewRows() {
  const { data: rpcData, error: rpcError } = await supabase.rpc(
    "competition_club_stadium_overview_list"
  );

  if (!rpcError && Array.isArray(rpcData)) {
    return { data: rpcData, error: null };
  }

  const { data, error } = await supabase
    .from("competition_club_stadium_overview_public")
    .select(
      "prestige_rank,club_short_name,club_name,capacity,rolling_points,rolling_seasons_count,composite_score,effective_tier,tier_override,manager_rating,stadium_season_start_fill_pct,stadium_display_fill_pct,stadium_fill_target_pct,gate_fill_pct,cushion_pct,expected_points,actual_points,performance_gap,performance_band,prestige_base_fill_pct,expected_position,actual_position,last_seasons_json,projection_note,expansion_eligible"
    )
    .order("prestige_rank", { ascending: true });

  return { data, error: rpcError || error };
}

async function loadTable() {
  setStatus("pageStatus", "Loading…");
  const wrap = document.getElementById("tableWrap");
  if (wrap) wrap.innerHTML = '<p class="note">Loading clubs…</p>';

  await supabase.rpc("competition_stadium_sync_all_clubs");

  const { data, error } = await fetchOverviewRows();

  if (error) {
    setStatus(
      "pageStatus",
      "❌ " +
        formatLoadError(error) +
        " — run stadium_attendance_v2_fix_projection_note.sql (or stadium_attendance_v2_rest_access.sql) in Supabase.",
      false
    );
    if (wrap) wrap.innerHTML = "";
    return;
  }

  allRows = (data || []).filter((row) => row.club_short_name !== "FOREIGN");

  if (!allRows.length) {
    setStatus(
      "pageStatus",
      "No clubs found — run SQL patches then Recompute club rankings.",
      false
    );
    if (wrap) wrap.innerHTML = "";
    return;
  }

  setStatus("pageStatus", `✅ Loaded ${allRows.length} clubs (prestige rank 1–${allRows.length}).`, true);
  renderTable();
}

async function syncFill() {
  setStatus("pageStatus", "Syncing monthly fill drift…");
  const { data, error } = await supabase.rpc("competition_stadium_sync_all_clubs");

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("pageStatus", `✅ Synced fill for ${data ?? 0} club(s).`, true);
  await loadTable();
}

async function recomputeRankings() {
  setStatus("pageStatus", "Recomputing club rankings…");
  const { data, error } = await supabase.rpc("competition_club_ranking_recompute_all");

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  setStatus("pageStatus", `✅ Recomputed ${data ?? 0} club-season row(s). Syncing fill…`, true);
  await syncFill();
}

async function saveOverrides() {
  const overrides = document.querySelectorAll(".club-tier-override");
  const managers = document.querySelectorAll(".club-mgr-rating");

  setStatus("pageStatus", "Saving…");

  for (const sel of overrides) {
    const club = sel.dataset.club;
    const { error } = await supabase.rpc("admin_set_club_tier_override", {
      p_club_short_name: club,
      p_tier: sel.value || "auto",
    });
    if (error) {
      setStatus("pageStatus", "❌ " + error.message, false);
      return;
    }
  }

  for (const inp of managers) {
    const club = inp.dataset.club;
    const raw = String(inp.value ?? "").trim();
    const rating = raw === "" ? null : Number(raw);
    if (raw !== "" && (!Number.isFinite(rating) || rating < 1 || rating > 99)) {
      setStatus("pageStatus", `Invalid manager rating for ${club}.`, false);
      return;
    }
    const { error } = await supabase.rpc("admin_set_club_manager_rating", {
      p_club_short_name: club,
      p_rating: rating,
    });
    if (error) {
      setStatus("pageStatus", "❌ " + error.message, false);
      return;
    }
  }

  setStatus("pageStatus", "✅ Tier overrides and manager ratings saved.", true);
  await loadTable();
}
