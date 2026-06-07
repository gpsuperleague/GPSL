import { supabase, initGlobal } from "./global.js";
import {
  loadClubsMap,
  fullClubName,
  displayClubName,
  formatSeasonSaleDestination,
  formatSeasonSaleType,
} from "./clubs_lookup.js";
import { DIVISION_LABELS } from "./competition.js";
import { renderTrophyCabinet } from "./history_trophies.js";

const AWARD_LABELS = {
  ballon_dor: "Ballon d'Or",
  golden_boot: "Golden Boot",
  golden_playmaker: "Golden Playmaker",
  golden_glove: "Golden Glove",
  season_potm: "Most POTM",
};

function divisionLabel(div) {
  return DIVISION_LABELS[div] || div || "—";
}

function formatMoney(amount) {
  if (amount == null || Number.isNaN(Number(amount))) return "—";
  return `₿ ${Number(amount).toLocaleString("en-GB")}`;
}

function signingSourceLabel(row) {
  if (!row?.seller_club_id) return "Free agent / draft";
  return displayClubName(row.seller_club_id);
}

function playerLink(id, name) {
  if (!id) return name || "—";
  const label = name || id;
  return `<a class="gpsl-link" href="player_career.html?id=${encodeURIComponent(id)}">${label}</a>`;
}

function showError(msg) {
  const el = document.getElementById("historyError");
  if (!el) return;
  if (!msg) {
    el.style.display = "none";
    el.textContent = "";
    return;
  }
  el.style.display = "block";
  el.textContent = msg;
}

function renderHonours(honours) {
  const el = document.getElementById("honoursPanel");
  if (!el) return;
  el.innerHTML = renderTrophyCabinet(honours || []);
}

function renderSeasons(seasons) {
  const el = document.getElementById("seasonsPanel");
  if (!seasons?.length) {
    el.innerHTML =
      '<p class="empty">No season archives yet. Admin can archive the current season from Season management.</p>';
    return;
  }

  const rows = [...seasons].sort((a, b) =>
    String(b.season_label).localeCompare(String(a.season_label))
  );

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>Division</th>
          <th class="num">Pos</th>
          <th class="num">P</th>
          <th class="num">W</th>
          <th class="num">D</th>
          <th class="num">L</th>
          <th class="num">GF</th>
          <th class="num">GA</th>
          <th class="num">GD</th>
          <th class="num">Pts</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (s) => `
          <tr>
            <td>${s.season_label}</td>
            <td>${divisionLabel(s.division)}</td>
            <td class="num">${s.final_position ?? "—"}</td>
            <td class="num">${s.mp ?? "—"}</td>
            <td class="num">${s.won ?? "—"}</td>
            <td class="num">${s.drawn ?? "—"}</td>
            <td class="num">${s.lost ?? "—"}</td>
            <td class="num">${s.gf ?? "—"}</td>
            <td class="num">${s.ga ?? "—"}</td>
            <td class="num">${s.gd ?? "—"}</td>
            <td class="num">${s.pts ?? "—"}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function recordCard(title, row, valueFmt) {
  if (!row || row.player_id == null) {
    return `
      <div class="record-card">
        <div class="label">${title}</div>
        <div class="value">—</div>
        <div class="meta">No data yet</div>
      </div>`;
  }
  return `
    <div class="record-card">
      <div class="label">${title}</div>
      <div class="value">${playerLink(row.player_id, row.player_name)}</div>
      <div class="meta">${valueFmt(row)}</div>
    </div>`;
}

function renderRecords(records) {
  const el = document.getElementById("recordsPanel");
  const r = records || {};
  el.innerHTML = [
    recordCard(
      "All-time top scorer",
      r.all_time_top_scorer,
      (x) => `${x.total_goals ?? 0} goals · ${x.total_apps ?? 0} apps`
    ),
    recordCard(
      "All-time top assists",
      r.all_time_top_assists,
      (x) => `${x.total_assists ?? 0} assists`
    ),
    recordCard(
      "All-time most POTM",
      r.all_time_top_potm,
      (x) => `${x.total_potm ?? 0} awards`
    ),
    recordCard(
      "Most goals in a season",
      r.season_top_goals,
      (x) => `${x.goals ?? 0} goals (${x.season_label || "season"})`
    ),
    recordCard(
      "Most assists in a season",
      r.season_top_assists,
      (x) => `${x.assists ?? 0} assists (${x.season_label || "season"})`
    ),
    recordCard(
      "Most POTM in a season",
      r.season_top_potm,
      (x) => `${x.potm_awards ?? 0} awards (${x.season_label || "season"})`
    ),
    recordCard(
      "Record signing",
      r.record_signing,
      (x) => {
        let line = `${formatMoney(x.fee)}`;
        if (Number(x.agent_fee) > 0) {
          line += ` (+ ${formatMoney(x.agent_fee)} agent)`;
        }
        line += ` · ${x.season_label || "—"} · from ${signingSourceLabel(x)}`;
        return line;
      }
    ),
    recordCard(
      "Record sale",
      r.record_sale,
      (x) =>
        `${formatMoney(x.fee)} · ${x.season_label || "—"} · ${formatSeasonSaleDestination(x)} (${formatSeasonSaleType(x)})`
    ),
  ].join("");
}

function renderBallon(rows) {
  const el = document.getElementById("ballonPanel");
  if (!rows?.length) {
    el.innerHTML =
      '<p class="empty">No Ballon d\'Or winners at this club yet. Awarded when the season is archived.</p>';
    return;
  }
  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr><th>Season</th><th>Player</th><th class="num">Points</th></tr>
      </thead>
      <tbody>
        ${rows
          .map(
            (a) => `
          <tr>
            <td>${a.season_label}</td>
            <td>${playerLink(a.player_id, a.player_name)}</td>
            <td class="num">${Number(a.stat_value).toFixed(1)}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (clubErr || !club?.ShortName) {
    showError("No club linked to your account.");
    return;
  }

  const shortName = club.ShortName;
  const title = fullClubName(shortName) || club.Club || shortName;
  document.getElementById("historyTitle").textContent = `${title} — History`;
  document.getElementById("historySubtitle").textContent =
    "Honours, league positions, records (incl. signings & sales) & Ballon d'Or winners.";

  const { data, error } = await supabase.rpc("competition_club_history_bundle", {
    p_club_short_name: shortName,
  });

  if (error) {
    console.error("competition_club_history_bundle:", error);
    showError(
      error.message.includes("competition_club_history_bundle")
        ? "Run supabase/sql/competition_history.sql in Supabase first."
        : error.message
    );
    return;
  }

  const bundle = data || {};
  renderHonours(bundle.honours || []);
  renderSeasons(bundle.seasons || []);
  renderRecords(bundle.records || {});
  renderBallon(bundle.ballon_winners || []);
});
