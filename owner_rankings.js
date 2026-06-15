import { supabase, initGlobal } from "./global.js";
import { renderNationFlag } from "./international_flags.js";

let myClub = null;
let activeTab = "rolling";
let schemaMissing = false;

const DEPLOY_MSG = `
  <p class="empty"><b>Owner ranking schema not deployed.</b></p>
  <p class="meta" style="color:#ccc;">
    In Supabase → SQL Editor, run the full file
    <code>supabase/sql/competition_owner_ranking.sql</code>
    (after <code>competition_history.sql</code> and <code>competition_international.sql</code>).
    Then run <b>Recompute all seasons</b> under Admin → World Cup &amp; nations.
  </p>`;

function isSchemaMissingError(err) {
  return (
    err?.code === "PGRST205" ||
    /could not find the table/i.test(err?.message || "")
  );
}

function fmtPts(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return v % 1 === 0 ? String(v) : v.toFixed(2);
}

function renderBreakdown(rows) {
  if (!rows?.length) return '<span class="empty">—</span>';
  return rows
    .map((s) => `${s.season_label}: ${fmtPts(s.season_total)}`)
    .join(" · ");
}

function renderWcBreakdown(rows) {
  if (!rows?.length) return '<span class="empty">—</span>';
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) return '<span class="empty">—</span>';
  return list
    .map((w) => `${w.cycle_label || "WC"} ${w.nation_code || ""}: ${fmtPts(w.points)}`)
    .join(" · ");
}

function tableHtml(headers, bodyRows) {
  if (!bodyRows.length) {
    return '<p class="empty">No ranking data yet. Admin archives a season to compute points.</p>';
  }
  const head = headers.map((h) => `<th>${h}</th>`).join("");
  const body = bodyRows.join("");
  return `<table class="lb"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function rowClass(clubShort) {
  const parts = [];
  if (clubShort && clubShort === myClub) parts.push("me");
  return parts.join(" ");
}

function renderNationCell(r) {
  if (!r.nation_code) return '<span class="empty">—</span>';
  const label = r.nation_name || r.nation_code;
  return (
    `<span class="nation-cell">${renderNationFlag(
      { code: r.nation_code, flag_emoji: r.flag_emoji, name: label },
      "sm"
    )} ${label}</span>`
  );
}

async function loadRolling() {
  const { data, error } = await supabase
    .from("competition_owner_ranking_rolling4_public")
    .select("*")
    .order("rank_position", { ascending: true });
  if (error) {
    if (isSchemaMissingError(error)) schemaMissing = true;
    throw error;
  }
  const rows = (data || []).map(
    (r) => `
    <tr class="${rowClass(r.club_short_name)}">
      <td class="num">${r.rank_position}</td>
      <td>${r.owner_tag || r.owner_name}</td>
      <td>${r.club_name || r.club_short_name}</td>
      <td>${renderNationCell(r)}</td>
      <td class="num"><b>${fmtPts(r.rolling_points)}</b></td>
      <td class="num">${r.seasons_count}/4</td>
      <td class="breakdown">${renderBreakdown(r.season_breakdown)}</td>
    </tr>`
  );
  return tableHtml(
    ["#", "Owner", "Club", "Nation", "Points", "Seasons", "Breakdown"],
    rows
  );
}

async function loadAllTime() {
  const { data, error } = await supabase
    .from("competition_owner_ranking_alltime_public")
    .select("*")
    .order("rank_position", { ascending: true });
  if (error) {
    if (isSchemaMissingError(error)) schemaMissing = true;
    throw error;
  }
  const rows = (data || []).map(
    (r) => `
    <tr>
      <td class="num">${r.rank_position}</td>
      <td>${r.owner_name}</td>
      <td class="num">${fmtPts(r.club_points)}</td>
      <td class="num">${fmtPts(r.wc_points)}</td>
      <td class="num"><b>${fmtPts(r.total_points)}</b></td>
      <td class="num">${r.seasons_count}</td>
      <td class="breakdown">${renderWcBreakdown(r.wc_breakdown)}</td>
      <td>${r.first_season_label || "—"} – ${r.last_season_label || "—"}</td>
    </tr>`
  );
  return tableHtml(
    ["#", "Owner", "Club", "World Cup", "Total", "Seasons", "WC results", "Active"],
    rows
  );
}

async function loadSeasonList() {
  const { data, error } = await supabase
    .from("competition_owner_season_ranking_public")
    .select("season_id, season_label")
    .order("season_id", { ascending: false });
  if (error) {
    if (isSchemaMissingError(error)) schemaMissing = true;
    throw error;
  }
  const seen = new Set();
  return (data || []).filter((r) => {
    if (seen.has(r.season_id)) return false;
    seen.add(r.season_id);
    return true;
  });
}

async function loadSeason(seasonId) {
  const { data, error } = await supabase
    .from("competition_owner_season_ranking_public")
    .select("*")
    .eq("season_id", seasonId)
    .order("season_total", { ascending: false });
  if (error) {
    if (isSchemaMissingError(error)) schemaMissing = true;
    throw error;
  }
  const rows = (data || []).map(
    (r, i) => `
    <tr class="${rowClass(r.club_short_name)}">
      <td class="num">${i + 1}</td>
      <td>${r.owner_tag || r.owner_name}</td>
      <td>${r.club_name || r.club_short_name}</td>
      <td class="num">${fmtPts(r.league_points)}</td>
      <td class="num">${fmtPts(r.super8_points)}</td>
      <td class="num">${fmtPts(r.plate_points)}</td>
      <td class="num">${fmtPts(r.shield_points)}</td>
      <td class="num">${fmtPts(r.spoon_points)}</td>
      <td class="num">${fmtPts(r.league_cup_points)}</td>
      <td class="num"><b>${fmtPts(r.season_total)}</b></td>
    </tr>`
  );
  return tableHtml(
    [
      "#",
      "Owner",
      "Club",
      "League",
      "Super8",
      "Plate",
      "Shield",
      "Spoon",
      "L.Cup",
      "Total",
    ],
    rows
  );
}

async function refresh() {
  const el = document.getElementById("rankTable");
  if (!el) return;
  el.textContent = "Loading…";
  try {
    if (activeTab === "rolling") {
      el.innerHTML = await loadRolling();
    } else if (activeTab === "alltime") {
      el.innerHTML = await loadAllTime();
    } else {
      const sel = document.getElementById("seasonSelect");
      const seasonId = Number(sel?.value);
      if (!seasonId) {
        el.innerHTML = '<p class="empty">No archived seasons with ranking data yet.</p>';
        return;
      }
      el.innerHTML = await loadSeason(seasonId);
    }
  } catch (err) {
    console.error(err);
    el.innerHTML = schemaMissing
      ? DEPLOY_MSG
      : `<p class="empty">Could not load rankings: ${err?.message || "unknown error"}</p>`;
  }
}

function setTab(tab) {
  activeTab = tab;
  document.querySelectorAll(".tabs button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === tab);
  });
  const seasonToolbar = document.getElementById("seasonToolbar");
  if (seasonToolbar) seasonToolbar.hidden = tab !== "season";
  refresh();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) {
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", user.id)
      .maybeSingle();
    myClub = clubRow?.ShortName || null;
  }

  const seasons = await loadSeasonList().catch(() => []);
  const sel = document.getElementById("seasonSelect");
  if (sel) {
    sel.innerHTML = seasons
      .map(
        (s) =>
          `<option value="${s.season_id}">${s.season_label}</option>`
      )
      .join("");
    sel.onchange = () => refresh();
  }

  document.querySelectorAll(".tabs button").forEach((btn) => {
    btn.addEventListener("click", () => setTab(btn.dataset.tab));
  });

  setTab("rolling");
});
