import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import { DIVISION_LABELS, formatMoney, GPSL_MONTH_LABELS } from "./competition.js";
import {
  pesdbPlayerUrl,
  pesdbPlayerCardUrl,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";
import {
  PLAYER_MEDALS_PREVIEW_HONOURS,
  renderHonoursHtml,
} from "./player_career_medals.js";

let careerHonoursReal = [];
let medalsPreviewOn = false;

const AWARD_LABELS = {
  ballon_dor: "Ballon d'Or",
  golden_boot: "Golden Boot",
  golden_playmaker: "Golden Playmaker",
  golden_glove: "Golden Glove",
  season_potm: "Most POTM",
  team_of_month: "Super League Team of the Month",
  championship_team_of_month: "Championship Team of the Month",
  team_of_season: "Team of the Season",
  championship_player_of_season: "Championship Player of the Season",
};

const AWARD_TROPHY = {
  ballon_dor: "🏆",
  golden_boot: "👟",
  golden_playmaker: "🎯",
  golden_glove: "🧤",
  season_potm: "⭐",
  team_of_month: "📅",
  championship_team_of_month: "📅",
  team_of_season: "🌟",
  championship_player_of_season: "🏅",
};

function isTeamOfMonthAward(awardType) {
  return awardType === "team_of_month" || awardType === "championship_team_of_month";
}

function awardGpslMonth(a) {
  return a.gpsl_month || a.detail?.gpsl_month || null;
}

function awardSeasonLabel(a) {
  return a.season_label || a.detail?.season_label || null;
}

function formatGpslMonthLabel(month) {
  if (!month) return "";
  const key = String(month).toLowerCase();
  return GPSL_MONTH_LABELS[key] || String(month).replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function formatAwardTitle(a) {
  const base = AWARD_LABELS[a.award_type] || a.award_type;
  if (isTeamOfMonthAward(a.award_type)) {
    const season = awardSeasonLabel(a);
    const month = awardGpslMonth(a);
    const parts = [season, month ? formatGpslMonthLabel(month) : null].filter(Boolean);
    if (parts.length) return `${base} (${parts.join(" · ")})`;
  }
  return base;
}

function formatAwardDetail(a) {
  const club = fullClubName(a.club_short_name) || a.club_name || a.club_short_name;
  const parts = isTeamOfMonthAward(a.award_type) ? [club] : [awardSeasonLabel(a), club];
  if (
    isTeamOfMonthAward(a.award_type) ||
    a.award_type === "team_of_season"
  ) {
    const slot = a.detail?.slot_label || a.detail?.pitch_slot;
    if (slot) parts.push(String(slot));
  }
  return parts.filter(Boolean).join(" · ");
}

const MOVE_LABELS = {
  transfer: "Transfer",
  free: "Free transfer",
  foreign_sale: "Foreign sale",
  overflow_release: "Squad release",
};

function divisionLabel(div) {
  return DIVISION_LABELS[div] || div || "—";
}

function clubLink(shortName, name) {
  if (!shortName) return name || "—";
  return `<a class="gpsl-link" href="club.html?club=${encodeURIComponent(shortName)}">${name || shortName}</a>`;
}

function showError(msg) {
  const el = document.getElementById("careerError");
  if (!el) return;
  if (!msg) {
    el.style.display = "none";
    return;
  }
  el.style.display = "block";
  el.textContent = msg;
}

function renderTotals(totals) {
  const t = totals || {};
  document.getElementById("totalsRow").innerHTML = `
    <span><b>Apps</b> ${t.appearances ?? 0}</span>
    <span><b>Goals</b> ${t.goals ?? 0}</span>
    <span><b>Assists</b> ${t.assists ?? 0}</span>
    <span><b>POTM</b> ${t.potm_awards ?? 0}</span>
    <span><b>Clean sheets</b> ${t.clean_sheets ?? 0}</span>
    <span><b>Avg rating</b> ${t.avg_rating != null ? Number(t.avg_rating).toFixed(2) : "—"}</span>
  `;
}

function renderStints(stints) {
  const el = document.getElementById("stintsPanel");
  if (!stints?.length) {
    el.innerHTML =
      '<p class="empty">No GPSL match stats yet — stats appear after confirmed league &amp; cup games.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>Club</th>
          <th>Div</th>
          <th class="num">Apps</th>
          <th class="num">G</th>
          <th class="num">A</th>
          <th class="num">POTM</th>
          <th class="num">CS</th>
          <th class="num">Avg</th>
        </tr>
      </thead>
      <tbody>
        ${stints
          .map(
            (s) => `
          <tr>
            <td>${s.season_label}${s.is_live ? " <small>(live)</small>" : ""}</td>
            <td>${clubLink(s.club_short_name, s.club_name)}</td>
            <td>${divisionLabel(s.division)}</td>
            <td class="num">${s.appearances ?? 0}</td>
            <td class="num">${s.goals ?? 0}</td>
            <td class="num">${s.assists ?? 0}</td>
            <td class="num">${s.potm_awards ?? 0}</td>
            <td class="num">${s.clean_sheets ?? 0}</td>
            <td class="num">${s.avg_rating != null ? Number(s.avg_rating).toFixed(2) : "—"}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function formatTransferParties(row) {
  const seller = displayClubName(row.seller_club_short_name) || row.seller_club_short_name || "—";
  const buyer =
    row.foreign_buyer_name ||
    displayClubName(row.buyer_club_short_name) ||
    row.buyer_club_short_name ||
    "—";
  return `${seller} → ${buyer}`;
}

function formatTransferFee(row) {
  const fee = Number(row.fee || 0);
  const agent = Number(row.agent_fee || 0);
  if (fee <= 0 && agent <= 0) return "—";
  if (agent > 0) {
    return `${formatMoney(fee)} (+ ${formatMoney(agent)} agent)`;
  }
  return formatMoney(fee);
}

function renderTransfers(transfers) {
  const el = document.getElementById("transfersPanel");
  if (!el) return;

  if (!transfers?.length) {
    el.innerHTML =
      '<p class="empty">No completed GPSL transfers recorded for this player yet.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>When</th>
          <th>Move</th>
          <th>Type</th>
          <th class="num">Fee</th>
        </tr>
      </thead>
      <tbody>
        ${transfers
          .map(
            (t) => `
          <tr>
            <td>${t.season_label || "—"}</td>
            <td>${t.transfer_time ? new Date(t.transfer_time).toLocaleDateString("en-GB") : "—"}</td>
            <td>${formatTransferParties(t)}</td>
            <td>${MOVE_LABELS[t.move_kind] || t.move_kind || "Transfer"}</td>
            <td class="num">${formatTransferFee(t)}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function renderHonours(honours) {
  const el = document.getElementById("medalsPanel");
  if (!el) return;
  el.innerHTML = renderHonoursHtml(honours);
}

function setMedalsPreview(on) {
  medalsPreviewOn = on;
  const banner = document.getElementById("previewBanner");
  const btn = document.getElementById("previewMedalsBtn");
  if (banner) banner.hidden = !on;
  if (btn) {
    btn.textContent = on ? "Show real medals" : "Preview sample medals";
    btn.classList.toggle("is-active", on);
    btn.setAttribute("aria-pressed", on ? "true" : "false");
  }
  renderHonours(on ? PLAYER_MEDALS_PREVIEW_HONOURS : careerHonoursReal);
}

function setupMedalsPreviewToggle() {
  const btn = document.getElementById("previewMedalsBtn");
  if (!btn) return;
  btn.hidden = false;
  btn.addEventListener("click", () => setMedalsPreview(!medalsPreviewOn));
}

function renderAwards(awards) {
  const el = document.getElementById("awardsPanel");
  if (!awards?.length) {
    el.innerHTML =
      '<p class="empty">No individual GPSL awards yet — Ballon d\'Or, Golden Boot, Team of the Month, and similar honours appear after season archive.</p>';
    return;
  }

  const sorted = [...awards].sort((a, b) => {
    const pri = (t) =>
      t === "ballon_dor"
        ? 0
        : t === "championship_player_of_season"
          ? 1
          : t === "team_of_season"
            ? 2
            : t === "team_of_month" || t === "championship_team_of_month"
              ? 3
              : 9;
    const p = pri(a.award_type) - pri(b.award_type);
    if (p !== 0) return p;
    const seasonCmp = String(b.season_label || "").localeCompare(String(a.season_label || ""));
    if (seasonCmp !== 0) return seasonCmp;
    if (isTeamOfMonthAward(a.award_type) && isTeamOfMonthAward(b.award_type)) {
      return String(awardGpslMonth(b) || "").localeCompare(String(awardGpslMonth(a) || ""));
    }
    return 0;
  });

  el.innerHTML = `
    <ul class="trophy-list">
      ${sorted
        .map(
          (a) => `
        <li class="trophy-item">
          <span class="trophy-icon" aria-hidden="true">${AWARD_TROPHY[a.award_type] || "🏆"}</span>
          <div class="trophy-body">
            <div class="trophy-title">${formatAwardTitle(a)}</div>
            <div class="trophy-meta">${formatAwardDetail(a)}</div>
          </div>
        </li>`
        )
        .join("")}
    </ul>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const params = new URLSearchParams(window.location.search);
  const playerId = params.get("id")?.trim();

  if (!playerId) {
    showError("Missing player id.");
    return;
  }

  const { data, error } = await supabase.rpc("competition_player_career_bundle", {
    p_player_id: playerId,
  });

  if (error) {
    console.error("competition_player_career_bundle:", error);
    showError(
      error.message.includes("competition_player_career_bundle")
        ? "Run supabase/sql/competition_history.sql and patches/player_career_transfers.sql in Supabase first."
        : error.message
    );
    return;
  }

  const bundle = data || {};
  const player = bundle.player || {};

  document.getElementById("playerTitle").textContent =
    player.player_name || `Player ${playerId}`;
  document.getElementById("playerMeta").textContent = [
    player.position,
    player.nation,
    player.rating != null ? `Rating ${player.rating}` : null,
    player.current_club
      ? `Current club: ${fullClubName(player.current_club) || player.current_club}`
      : "Free agent",
  ]
    .filter(Boolean)
    .join(" · ");

  const img = document.getElementById("playerImg");
  const imgLink = document.getElementById("playerImgLink");
  img.src = pesdbPlayerCardUrl(playerId);
  img.onerror = () => {
    img.src = PESDB_FALLBACK_CARD_IMG;
  };
  if (imgLink) imgLink.href = pesdbPlayerUrl(playerId);

  renderTotals(bundle.totals);
  renderStints(bundle.stints || []);
  renderTransfers(bundle.transfers || []);
  careerHonoursReal = bundle.honours || [];
  setupMedalsPreviewToggle();
  if (params.get("preview") === "medals") {
    setMedalsPreview(true);
  } else {
    renderHonours(careerHonoursReal);
  }
  renderAwards(bundle.awards || []);
});
