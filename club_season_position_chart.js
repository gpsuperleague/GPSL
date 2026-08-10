/**
 * Shared Chart.js line chart: final league position by season.
 * Used by History (legacy callers) and Boardroom analysis.
 */
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
import { DIVISION_LABELS } from "./competition.js";

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

function divisionLabel(div) {
  return DIVISION_LABELS[div] || div || "—";
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

/**
 * @param {object} opts
 * @param {HTMLCanvasElement|null} opts.canvas
 * @param {HTMLElement|null} opts.empty
 * @param {object} opts.data - RPC competition_club_position_charts payload
 * @param {number|null} [opts.maxSeasons] - if set, keep only the last N seasons (chronological)
 * @param {string} [opts.emptyMessage]
 * @returns {Chart|null}
 */
export function renderSeasonPositionChart({
  canvas,
  empty,
  data,
  maxSeasons = null,
  emptyMessage = "No season position history yet. Archive past seasons from Admin → Season management, or wait for live standings this year.",
} = {}) {
  const wrap = canvas?.closest(".chart-wrap");
  if (!canvas || !empty) return null;

  let rows = Array.isArray(data?.seasons) ? [...data.seasons] : [];
  if (maxSeasons != null && Number.isFinite(Number(maxSeasons)) && Number(maxSeasons) > 0) {
    rows = rows.slice(-Number(maxSeasons));
  }

  if (!rows.length) {
    if (wrap) wrap.style.display = "none";
    empty.style.display = "block";
    empty.textContent = emptyMessage;
    return null;
  }

  if (wrap) wrap.style.display = "block";
  empty.style.display = "none";

  const existing = Chart.getChart(canvas);
  if (existing) existing.destroy();

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

  return new Chart(canvas, {
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

/**
 * Load RPC and render into the given canvas / empty elements.
 * @param {import("@supabase/supabase-js").SupabaseClient} client
 * @param {string} shortName
 * @param {object} opts
 * @param {string} [opts.canvasId]
 * @param {string} [opts.emptyId]
 * @param {number|null} [opts.maxSeasons]
 */
export async function loadSeasonPositionChart(
  client,
  shortName,
  {
    canvasId = "seasonPositionChart",
    emptyId = "seasonPositionEmpty",
    maxSeasons = null,
  } = {}
) {
  const canvas = document.getElementById(canvasId);
  const empty = document.getElementById(emptyId);
  const wrap = canvas?.closest(".chart-wrap");

  const { data, error } = await client.rpc("competition_club_position_charts", {
    p_club_short_name: shortName,
  });

  if (error) {
    console.warn("competition_club_position_charts:", error.message);
    if (wrap) wrap.style.display = "none";
    if (empty) {
      empty.style.display = "block";
      empty.textContent = error.message.includes("competition_club_position_charts")
        ? "Run supabase/sql/patches/competition_club_position_charts.sql in Supabase to enable position charts."
        : `Could not load season chart (${error.message}).`;
    }
    return null;
  }

  return renderSeasonPositionChart({
    canvas,
    empty,
    data: data || {},
    maxSeasons,
  });
}
