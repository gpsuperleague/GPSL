import { supabase, initGlobal } from "./global.js";
import {
  loadClubsMap,
  fullClubName,
  displayClubName,
  formatSeasonSaleDestination,
  formatSeasonSaleType,
  clubPageHref,
  resolveClubShortName,
} from "./clubs_lookup.js";
import { DIVISION_LABELS } from "./competition.js";
import { renderTrophyCabinet } from "./history_trophies.js";
import { playerNameLinkHtml } from "./player_links.js";
import { formatSeasonStripLabel } from "./season_transfer_schedule.js";
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

function seasonLabelText(raw) {
  if (raw == null || String(raw).trim() === "") return null;
  return formatSeasonStripLabel(raw);
}

function appsText(n) {
  const apps = Number(n);
  if (!Number.isFinite(apps)) return null;
  return `${apps} game${apps === 1 ? "" : "s"}`;
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
    const monthlyWrap = document
      .getElementById("monthlyPositionChart")
      ?.closest(".chart-wrap");
    if (monthlyWrap) monthlyWrap.style.display = "none";
    if (monthlyEmpty) {
      monthlyEmpty.style.display = "block";
      monthlyEmpty.textContent = error.message.includes(
        "competition_club_position_charts"
      )
        ? "Run supabase/sql/patches/competition_club_position_charts.sql in Supabase to enable position charts."
        : `Could not load monthly chart (${error.message}).`;
    }
    return;
  }

  renderMonthlyChart(data || {});
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
            <td>${seasonLabelText(s.season_label) || s.season_label || "—"}</td>
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

  const seasonMeta = (x, main) => {
    const season = seasonLabelText(x.season_label);
    const apps = appsText(x.appearances ?? x.total_apps);
    const bits = [main];
    if (apps) bits.push(apps);
    if (season) bits.push(season);
    return bits.join(" · ");
  };

  el.innerHTML = [
    recordCard(
      "All-time top scorer",
      r.all_time_top_scorer,
      (x) =>
        seasonMeta(x, `${x.total_goals ?? 0} goals`) ||
        `${x.total_goals ?? 0} goals`
    ),
    recordCard(
      "All-time top assists",
      r.all_time_top_assists,
      (x) =>
        seasonMeta(x, `${x.total_assists ?? 0} assists`) ||
        `${x.total_assists ?? 0} assists`
    ),
    recordCard(
      "All-time most appearances",
      r.all_time_top_apps,
      (x) => `${x.total_apps ?? 0} games · ${x.total_goals ?? 0} goals · ${x.total_assists ?? 0} assists`
    ),
    recordCard(
      "All-time most POTM",
      r.all_time_top_potm,
      (x) =>
        seasonMeta(x, `${x.total_potm ?? 0} awards`) ||
        `${x.total_potm ?? 0} awards`
    ),
    recordCard(
      "Most goals in a season",
      r.season_top_goals,
      (x) => seasonMeta(x, `${x.goals ?? 0} goals`)
    ),
    recordCard(
      "Most assists in a season",
      r.season_top_assists,
      (x) => seasonMeta(x, `${x.assists ?? 0} assists`)
    ),
    recordCard(
      "Most POTM in a season",
      r.season_top_potm,
      (x) => seasonMeta(x, `${x.potm_awards ?? 0} awards`)
    ),
    recordCard(
      "Record signing",
      r.record_signing,
      (x) => {
        let line = `${formatMoney(x.fee)}`;
        if (Number(x.agent_fee) > 0) {
          line += ` (+ ${formatMoney(x.agent_fee)} agent)`;
        }
        const season = seasonLabelText(x.season_label) || "—";
        line += ` · ${season} · from ${signingSourceLabel(x)}`;
        return line;
      }
    ),
    recordCard(
      "Record sale",
      r.record_sale,
      (x) => {
        const season = seasonLabelText(x.season_label) || "—";
        return `${formatMoney(x.fee)} · ${season} · ${formatSeasonSaleDestination(x)} (${formatSeasonSaleType(x)})`;
      }
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
            <td>${seasonLabelText(a.season_label) || a.season_label || "—"}</td>
            <td>${playerLink(a.player_id, a.player_name)}</td>
            <td class="num">${Number(a.stat_value).toFixed(1)}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderOwners(owners) {
  const el = document.getElementById("ownersPanel");
  if (!el) return;
  if (!owners?.length) {
    el.innerHTML =
      '<p class="empty">No owner seasons archived for this club yet. Current owner appears after season ranking is written at archive.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Owner</th>
          <th>Seasons</th>
          <th>Charge</th>
          <th class="num">W-D-L</th>
          <th>Trophies</th>
        </tr>
      </thead>
      <tbody>
        ${owners
          .map((o) => {
            const tag = o.owner_tag || o.owner_name || "Owner";
            const nameLink = o.owner_id
              ? `<a class="gpsl-link" href="owner_profile.html?owner=${encodeURIComponent(
                  o.owner_id
                )}">${escapeHtml(tag)}</a>`
              : escapeHtml(tag);
            const current = o.is_current
              ? ` <span style="color:#9fd4b0;font-size:11px;">(current)</span>`
              : "";
            const first = seasonLabelText(o.first_season_label) || o.first_season_label;
            const last = seasonLabelText(o.last_season_label) || o.last_season_label;
            let charge = "—";
            if (first && last && first !== last) charge = `${first} → ${last}`;
            else if (first || last) charge = first || last;
            else if (o.is_current) charge = "Current season";

            const trophies = Array.isArray(o.trophies) ? o.trophies : [];
            const trophyHtml = trophies.length
              ? trophies
                  .map(
                    (t) =>
                      `<div style="font-size:12px;margin:1px 0;">${escapeHtml(
                        t.honour_label || t.honour_type || "Trophy"
                      )} <span style="color:#888;">(${escapeHtml(
                        seasonLabelText(t.season_label) || t.season_label || "—"
                      )})</span></div>`
                  )
                  .join("")
              : '<span class="empty">—</span>';

            return `<tr>
              <td>${nameLink}${current}</td>
              <td class="num">${o.seasons_count ?? 0}</td>
              <td>${escapeHtml(charge)}</td>
              <td class="num">${o.won ?? 0}-${o.drawn ?? 0}-${o.lost ?? 0}</td>
              <td>${trophyHtml}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

async function resolveHistoryClub(user) {
  const params = new URLSearchParams(window.location.search);
  const q = (params.get("club") || "").trim();
  if (q) {
    const short = resolveClubShortName(q) || q.toUpperCase();
    const { data: row } = await supabase
      .from("Clubs")
      .select("ShortName, Club, is_archived")
      .eq("ShortName", short)
      .maybeSingle();
    if (row?.ShortName) {
      return {
        shortName: row.ShortName,
        title: fullClubName(row.ShortName) || row.Club || row.ShortName,
        archived: row.is_archived === true,
      };
    }
    // Fallback if is_archived column missing
    const { data: row2 } = await supabase
      .from("Clubs")
      .select("ShortName, Club")
      .eq("ShortName", short)
      .maybeSingle();
    if (row2?.ShortName) {
      return {
        shortName: row2.ShortName,
        title: fullClubName(row2.ShortName) || row2.Club || row2.ShortName,
        archived: false,
      };
    }
    return { error: `Club not found: ${q}` };
  }

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (clubErr || !club?.ShortName) {
    return { error: "No club linked to your account. Open history via a club name link, or use ?club=SHORT." };
  }
  return {
    shortName: club.ShortName,
    title: fullClubName(club.ShortName) || club.Club || club.ShortName,
    archived: false,
  };
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

  const resolved = await resolveHistoryClub(user);
  if (resolved.error) {
    showError(resolved.error);
    return;
  }

  const shortName = resolved.shortName;
  const detailsHref = clubPageHref(shortName);
  document.getElementById("historyTitle").textContent = `${resolved.title} — History`;
  document.getElementById("historySubtitle").innerHTML =
    `Owners, honours, league positions, records &amp; Ballon d'Or.` +
    (resolved.archived
      ? ` <span style="color:#f8a;">(Archived club — history retained.)</span>`
      : "") +
    (detailsHref
      ? ` · <a class="gpsl-link" href="${detailsHref}">Club details</a>`
      : "");

  const [{ data, error }, ownersRes] = await Promise.all([
    supabase.rpc("competition_club_history_bundle", {
      p_club_short_name: shortName,
    }),
    supabase.rpc("competition_club_owners_roster", {
      p_club_short_name: shortName,
    }),
  ]);

  if (error) {
    console.error("competition_club_history_bundle:", error);
    showError(
      error.message.includes("competition_club_history_bundle")
        ? "Run supabase/sql/competition_history.sql in Supabase first."
        : error.message
    );
    return;
  }

  if (ownersRes.error) {
    console.warn("competition_club_owners_roster:", ownersRes.error);
    const el = document.getElementById("ownersPanel");
    if (el) {
      el.innerHTML =
        '<p class="empty">Owners roster unavailable — run club_management_archive_owners_20260813.sql</p>';
    }
  } else {
    renderOwners(ownersRes.data?.owners || []);
  }

  const bundle = data || {};
  renderHonours(bundle.honours || []);
  renderSeasons(bundle.seasons || []);
  renderRecords(bundle.records || {});
  renderBallon(bundle.ballon_winners || []);
  await loadPositionCharts(shortName);
});
