import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import { DIVISION_LABELS, formatMoney } from "./competition.js";
import {
  pesdbPlayerUrl,
  pesdbPlayerCardUrl,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";

const AWARD_LABELS = {
  ballon_dor: "Ballon d'Or",
  golden_boot: "Golden Boot",
  golden_playmaker: "Golden Playmaker",
  golden_glove: "Golden Glove",
  season_potm: "Most POTM",
};

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

function renderAwards(awards) {
  const el = document.getElementById("awardsPanel");
  if (!awards?.length) {
    el.innerHTML = '<p class="empty">No season awards yet.</p>';
    return;
  }
  el.innerHTML = awards
    .map(
      (a) =>
        `<span class="award-pill">${AWARD_LABELS[a.award_type] || a.award_type} · ${a.season_label} · ${fullClubName(a.club_short_name) || a.club_name}</span>`
    )
    .join("");
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
  renderAwards(bundle.awards || []);
});
