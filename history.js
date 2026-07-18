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
import { playerNameLinkHtml } from "./player_links.js";
import {
  Chart,
  LineController,
  LineElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend,
} from "https://cdn.jsdelivr.net/npm/chart.js@4.4.1/+esm";

Chart.register(
  LineController,
  LineElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend
);

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
  return playerNameLinkHtml(id, name || id);
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

function positionYScale(maxPos) {
  const top = Math.max(2, Number(maxPos) || 20);
  return {
    reverse: true,
    min: 1,
    max: top,
    ticks: {
      stepSize: 1,
      color: "#aaa",
      callback: (v) => (Number.isInteger(v) ? v : ""),
    },
    grid: { color: "rgba(255,255,255,0.06)" },
    title: {
      display: true,
      text: "League position",
      color: "#888",
      font: { size: 11 },
    },
  };
}

function chartDefaults() {
  return {
    responsive: true,
    maintainAspectRatio: false,
    interaction: { mode: "index", intersect: false },
    plugins: {
      legend: { display: false },
      tooltip: {
        backgroundColor: "#1a1a1a",
        titleColor: "#ffcc66",
        bodyColor: "#ddd",
        borderColor: "#444",
        borderWidth: 1,
      },
    },
  };
}

function formatAttendance(n) {
  if (n == null || !Number.isFinite(Number(n))) return null;
  return Math.round(Number(n)).toLocaleString("en-GB");
}

function renderMonthlyChart(data) {
  const canvas = document.getElementById("monthlyPositionChart");
  const empty = document.getElementById("monthlyPositionEmpty");
  const wrap = canvas?.closest(".chart-wrap");
  if (!canvas || !empty) return;

  const rows = data?.monthly || [];
  if (!rows.length) {
    if (wrap) wrap.style.display = "none";
    empty.style.display = "block";
    empty.textContent =
      "No monthly league positions yet — positions appear once league fixtures are played this season.";
    return;
  }

  if (wrap) wrap.style.display = "block";
  empty.style.display = "none";

  const labels = rows.map((r) => r.month_label || r.gpsl_month);
  const positions = rows.map((r) => Number(r.position));
  const attendance = rows.map((r) => {
    const n = Number(r.avg_home_attendance);
    return Number.isFinite(n) && n > 0 ? n : null;
  });
  const maxPos = Math.max(
    Number(data.division_size) || 0,
    ...positions.filter((n) => Number.isFinite(n))
  );
  const attValues = attendance.filter((n) => n != null);
  const maxAtt = attValues.length ? Math.max(...attValues) : 0;
  const hasAttendance = attValues.length > 0;

  new Chart(canvas, {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: "Position",
          data: positions,
          yAxisID: "y",
          borderColor: "#ff9900",
          backgroundColor: "rgba(255,153,0,0.12)",
          pointBackgroundColor: "#ffcc66",
          pointBorderColor: "#ff9900",
          pointRadius: 4,
          pointHoverRadius: 6,
          tension: 0.25,
          fill: true,
          spanGaps: true,
          order: 1,
        },
        ...(hasAttendance
          ? [
              {
                label: "Avg home attendance",
                data: attendance,
                yAxisID: "yAtt",
                borderColor: "rgba(180, 190, 210, 0.55)",
                backgroundColor: "rgba(140, 155, 180, 0.18)",
                pointBackgroundColor: "rgba(200, 210, 225, 0.7)",
                pointBorderColor: "rgba(160, 170, 190, 0.6)",
                pointRadius: 3,
                pointHoverRadius: 5,
                tension: 0.3,
                fill: true,
                spanGaps: true,
                borderWidth: 1.5,
                order: 2,
              },
            ]
          : []),
      ],
    },
    options: {
      ...chartDefaults(),
      plugins: {
        ...chartDefaults().plugins,
        legend: {
          display: hasAttendance,
          labels: { color: "#bbb", boxWidth: 12 },
        },
        tooltip: {
          ...chartDefaults().plugins.tooltip,
          callbacks: {
            label(ctx) {
              const row = rows[ctx.dataIndex];
              if (ctx.dataset.yAxisID === "yAtt") {
                const att = formatAttendance(row?.avg_home_attendance);
                const games = row?.home_games;
                const bits = [att ? `Avg home att. ${att}` : "No attendance data"];
                if (games != null) bits.push(`${games} home game${games === 1 ? "" : "s"}`);
                return bits.join(" · ");
              }
              const pos = row?.position ?? ctx.parsed.y;
              const bits = [`${pos}${ordinalSuffix(pos)}`];
              if (row?.pts != null) bits.push(`${row.pts} pts`);
              if (row?.mp != null) bits.push(`${row.mp} played`);
              const att = formatAttendance(row?.avg_home_attendance);
              if (att) bits.push(`att. ${att}`);
              return bits.join(" · ");
            },
          },
        },
      },
      scales: {
        x: {
          ticks: { color: "#aaa" },
          grid: { color: "rgba(255,255,255,0.04)" },
        },
        y: positionYScale(maxPos),
        ...(hasAttendance
          ? {
              yAtt: {
                position: "right",
                beginAtZero: true,
                suggestedMax: maxAtt > 0 ? maxAtt * 1.08 : undefined,
                ticks: {
                  color: "rgba(170, 180, 200, 0.85)",
                  callback(v) {
                    return Number(v).toLocaleString("en-GB");
                  },
                },
                grid: { drawOnChartArea: false },
                title: {
                  display: true,
                  text: "Avg home attendance",
                  color: "rgba(170, 180, 200, 0.75)",
                  font: { size: 11 },
                },
              },
            }
          : {}),
      },
    },
  });
}

function renderSeasonChart(data) {
  const canvas = document.getElementById("seasonPositionChart");
  const empty = document.getElementById("seasonPositionEmpty");
  const wrap = canvas?.closest(".chart-wrap");
  if (!canvas || !empty) return;

  const rows = data?.seasons || [];
  if (!rows.length) {
    if (wrap) wrap.style.display = "none";
    empty.style.display = "block";
    empty.textContent =
      "No season position history yet. Archive past seasons from Admin → Season management, or wait for live standings this year.";
    return;
  }

  if (wrap) wrap.style.display = "block";
  empty.style.display = "none";

  const labels = rows.map((r) => {
    const base = r.season_label || "Season";
    return r.is_current && !r.is_final ? `${base} (live)` : base;
  });
  const positions = rows.map((r) => Number(r.position));
  const maxPos = Math.max(
    20,
    ...positions.filter((n) => Number.isFinite(n)),
    Number(data.division_size) || 0
  );

  new Chart(canvas, {
    type: "line",
    data: {
      labels,
      datasets: [
        {
          label: "Final position",
          data: positions,
          borderColor: "#6cf",
          backgroundColor: "rgba(102,204,255,0.12)",
          pointBackgroundColor: rows.map((r) =>
            r.is_current && !r.is_final ? "#ffcc66" : "#9fd4ff"
          ),
          pointBorderColor: rows.map((r) =>
            r.is_current && !r.is_final ? "#ff9900" : "#6cf"
          ),
          pointRadius: 4,
          pointHoverRadius: 6,
          tension: 0.25,
          fill: true,
          spanGaps: true,
        },
      ],
    },
    options: {
      ...chartDefaults(),
      plugins: {
        ...chartDefaults().plugins,
        tooltip: {
          ...chartDefaults().plugins.tooltip,
          callbacks: {
            label(ctx) {
              const row = rows[ctx.dataIndex];
              const pos = row?.position ?? ctx.parsed.y;
              const div = divisionLabel(row?.division);
              const tag =
                row?.is_current && !row?.is_final
                  ? "live"
                  : row?.is_final
                    ? "final"
                    : "";
              return `${pos}${ordinalSuffix(pos)} · ${div}${tag ? ` · ${tag}` : ""}`;
            },
          },
        },
      },
      scales: {
        x: {
          ticks: { color: "#aaa", maxRotation: 45, minRotation: 0 },
          grid: { color: "rgba(255,255,255,0.04)" },
        },
        y: positionYScale(maxPos),
      },
    },
  });
}

function ordinalSuffix(n) {
  const num = Number(n);
  if (!Number.isFinite(num)) return "";
  const v = num % 100;
  if (v >= 11 && v <= 13) return "th";
  switch (num % 10) {
    case 1:
      return "st";
    case 2:
      return "nd";
    case 3:
      return "rd";
    default:
      return "th";
  }
}

async function loadPositionCharts(shortName) {
  const { data, error } = await supabase.rpc("competition_club_position_charts", {
    p_club_short_name: shortName,
  });

  if (error) {
    console.warn("competition_club_position_charts:", error.message);
    const monthlyEmpty = document.getElementById("monthlyPositionEmpty");
    const seasonEmpty = document.getElementById("seasonPositionEmpty");
    const monthlyWrap = document
      .getElementById("monthlyPositionChart")
      ?.closest(".chart-wrap");
    const seasonWrap = document
      .getElementById("seasonPositionChart")
      ?.closest(".chart-wrap");
    if (monthlyWrap) monthlyWrap.style.display = "none";
    if (seasonWrap) seasonWrap.style.display = "none";
    if (monthlyEmpty) {
      monthlyEmpty.style.display = "block";
      monthlyEmpty.textContent = error.message.includes(
        "competition_club_position_charts"
      )
        ? "Run supabase/sql/patches/competition_club_position_charts.sql in Supabase to enable position charts."
        : `Could not load monthly chart (${error.message}).`;
    }
    if (seasonEmpty) {
      seasonEmpty.style.display = "block";
      seasonEmpty.textContent = error.message.includes(
        "competition_club_position_charts"
      )
        ? "Run supabase/sql/patches/competition_club_position_charts.sql in Supabase to enable position charts."
        : `Could not load season chart (${error.message}).`;
    }
    return;
  }

  renderMonthlyChart(data || {});
  renderSeasonChart(data || {});
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
  await loadPositionCharts(shortName);
});
