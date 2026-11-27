import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import { CUP_LABELS, DIVISION_LABELS, formatMoney, GPSL_MONTH_LABELS } from "./competition.js?v=20261127-career-comps";
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
  contract_expiry: "Contract ended",
  emergency_loan: "Emergency loan",
  emergency_loan_return: "Emergency loan ended",
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
    <span><b>Yellows</b> ${t.yellow_cards ?? 0}</span>
    <span><b>Reds</b> ${t.red_cards ?? 0}</span>
  `;
}

function renderDiscipline(rows) {
  const el = document.getElementById("disciplinePanel");
  if (!el) return;
  if (!rows?.length) {
    el.innerHTML =
      '<p class="empty">No cards or suspensions recorded yet.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>Club</th>
          <th>Incident</th>
          <th>Matches</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((d) => {
            const matches = (d.matches || [])
              .map(
                (m) =>
                  `${m.label || "Match"}${m.served ? " ✓" : ""}`
              )
              .join("<br>") || "—";
            const active = d.status === "active";
            return `
          <tr class="${active ? "discipline-active" : ""}">
            <td>${d.season_label || "—"}</td>
            <td>${fullClubName(d.club_short_name) || d.club_short_name || "—"}</td>
            <td>${d.summary || d.reason || "—"}</td>
            <td>${matches}</td>
            <td>${active ? "Active" : d.status || "—"}</td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

function seasonSortKey(label) {
  const m = String(label || "").match(/(\d+)/);
  return m ? Number(m[1]) : 0;
}

/** Destination club for a transfer (buyer / foreign name key). */
function transferDestClub(t) {
  return String(t.buyer_club_short_name || t.foreign_buyer_name || "").trim();
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function competitionDisplayName(row) {
  if (row.is_league === true || row.competition_code === "league") {
    return DIVISION_LABELS[row.division] || "League";
  }
  return CUP_LABELS[row.competition_code] || row.competition_code || "Cup";
}

function sumStat(rows, key) {
  return (rows || []).reduce((n, row) => n + (Number(row?.[key]) || 0), 0);
}

function weightedAvg(rows) {
  let weight = 0;
  let apps = 0;
  for (const row of rows || []) {
    const n = Number(row.appearances) || 0;
    if (row.avg_rating != null && row.avg_rating !== "" && n > 0) {
      weight += Number(row.avg_rating) * n;
      apps += n;
    }
  }
  return apps ? Math.round((weight / apps) * 100) / 100 : null;
}

function formatAvgCell(value) {
  return value != null && value !== "" ? Number(value).toFixed(2) : "—";
}

function renderStints(stints, transfers = [], competitions = []) {
  const el = document.getElementById("stintsPanel");
  if (!el) return;

  if (competitions?.length) {
    renderSeasonCompetitionHistory(el, stints, transfers, competitions);
    return;
  }

  const stintRows = (stints || []).map((s) => ({
    kind: "stint",
    season_label: s.season_label,
    season_key: seasonSortKey(s.season_label),
    club_key: String(s.club_short_name || "").trim(),
    sort_time: 0,
    data: s,
  }));

  const transferRows = (transfers || []).map((t) => ({
    kind: "transfer",
    season_label: t.season_label,
    season_key: seasonSortKey(t.season_label),
    club_key: transferDestClub(t),
    sort_time: t.transfer_time ? new Date(t.transfer_time).getTime() : 0,
    data: t,
  }));

  // Season desc → club → stint stats, then signed/transfer for that club
  const rows = [...stintRows, ...transferRows].sort((a, b) => {
    if (b.season_key !== a.season_key) return b.season_key - a.season_key;
    const clubCmp = String(a.club_key || "\uffff").localeCompare(
      String(b.club_key || "\uffff")
    );
    if (clubCmp !== 0) return clubCmp;
    if (a.kind !== b.kind) return a.kind === "stint" ? -1 : 1;
    if (a.kind === "transfer") return a.sort_time - b.sort_time;
    return 0;
  });

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No GPSL match stats or transfers yet — stats appear after confirmed league &amp; cup games.</p>';
    return;
  }

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>Club / move</th>
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
        ${rows
          .map((row) => {
            if (row.kind === "transfer") {
              const t = row.data;
              const when = t.transfer_time
                ? new Date(t.transfer_time).toLocaleDateString("en-GB")
                : null;
              const type = MOVE_LABELS[t.move_kind] || t.move_kind || "Transfer";
              const fee = formatTransferFee(t);
              return `
          <tr class="move-row">
            <td>${t.season_label || "—"}</td>
            <td>
              <span class="row-kind">Signed</span>${formatTransferParties(t)}
              <div class="move-meta">${[when, type, fee !== "—" ? fee : null].filter(Boolean).join(" · ")}</div>
            </td>
            <td>—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
          </tr>`;
            }

            const s = row.data;
            return `
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
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

function renderSeasonCompetitionHistory(el, stints, transfers, competitions) {
  const seasons = new Map();
  const bucket = (label) => {
    const name = label || "—";
    if (!seasons.has(name)) {
      seasons.set(name, {
        label: name,
        key: seasonSortKey(name),
        stints: [],
        transfers: [],
        comps: [],
      });
    }
    return seasons.get(name);
  };

  for (const stint of stints || []) bucket(stint.season_label).stints.push(stint);
  for (const transfer of transfers || []) bucket(transfer.season_label).transfers.push(transfer);
  for (const comp of competitions || []) bucket(comp.season_label).comps.push(comp);

  const ordered = [...seasons.values()].sort((a, b) => b.key - a.key);
  if (!ordered.length) {
    el.innerHTML =
      '<p class="empty">No GPSL match stats or transfers yet — stats appear after confirmed league &amp; cup games.</p>';
    return;
  }

  const body = ordered
    .map((season) => {
      const parts = [];
      const coveredClubs = new Set(
        season.comps.map((c) => String(c.club_short_name || "").trim())
      );
      const statRows = season.comps.length ? season.comps : season.stints;
      if (statRows.length) {
        const live = season.stints.some((s) => s.is_live);
        parts.push(`
          <tr class="season-total">
            <td>${escapeHtml(season.label)}${live ? " <small>(live)</small>" : ""}</td>
            <td>Season total</td>
            <td>—</td>
            <td class="num">${sumStat(statRows, "appearances")}</td>
            <td class="num">${sumStat(statRows, "goals")}</td>
            <td class="num">${sumStat(statRows, "assists")}</td>
            <td class="num">${season.stints.length ? sumStat(season.stints, "potm_awards") : "—"}</td>
            <td class="num">${season.stints.length ? sumStat(season.stints, "clean_sheets") : "—"}</td>
            <td class="num">${formatAvgCell(weightedAvg(statRows))}</td>
          </tr>`);
      }

      const comps = [...season.comps].sort((a, b) => {
        const league = Number(b.is_league === true) - Number(a.is_league === true);
        if (league) return league;
        const name = competitionDisplayName(a).localeCompare(competitionDisplayName(b));
        if (name) return name;
        return String(a.club_short_name || "").localeCompare(String(b.club_short_name || ""));
      });
      for (const comp of comps) {
        const club = clubLink(comp.club_short_name, comp.club_name);
        parts.push(`
          <tr class="comp-row">
            <td></td>
            <td class="comp-name">${escapeHtml(competitionDisplayName(comp))} · ${club}</td>
            <td>${comp.is_league ? divisionLabel(comp.division) : "—"}</td>
            <td class="num">${comp.appearances ?? 0}</td>
            <td class="num">${comp.goals ?? 0}</td>
            <td class="num">${comp.assists ?? 0}</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">${formatAvgCell(comp.avg_rating)}</td>
          </tr>`);
      }

      for (const stint of season.stints) {
        if (coveredClubs.has(String(stint.club_short_name || "").trim())) continue;
        parts.push(`
          <tr>
            <td></td>
            <td>${clubLink(stint.club_short_name, stint.club_name)}</td>
            <td>${divisionLabel(stint.division)}</td>
            <td class="num">${stint.appearances ?? 0}</td>
            <td class="num">${stint.goals ?? 0}</td>
            <td class="num">${stint.assists ?? 0}</td>
            <td class="num">${stint.potm_awards ?? 0}</td>
            <td class="num">${stint.clean_sheets ?? 0}</td>
            <td class="num">${formatAvgCell(stint.avg_rating)}</td>
          </tr>`);
      }

      const moves = [...season.transfers].sort((a, b) => {
        const ta = a.transfer_time ? new Date(a.transfer_time).getTime() : 0;
        const tb = b.transfer_time ? new Date(b.transfer_time).getTime() : 0;
        return ta - tb;
      });
      for (const transfer of moves) {
        const when = transfer.transfer_time
          ? new Date(transfer.transfer_time).toLocaleDateString("en-GB")
          : null;
        const type = MOVE_LABELS[transfer.move_kind] || transfer.move_kind || "Transfer";
        const fee = formatTransferFee(transfer);
        parts.push(`
          <tr class="move-row">
            <td>${escapeHtml(transfer.season_label || season.label)}</td>
            <td>
              <span class="row-kind">Signed</span>${formatTransferParties(transfer)}
              <div class="move-meta">${[when, type, fee !== "—" ? fee : null].filter(Boolean).join(" · ")}</div>
            </td>
            <td>—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
            <td class="num">—</td>
          </tr>`);
      }
      return parts.join("");
    })
    .join("");

  el.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Season</th>
          <th>Club / competition</th>
          <th>Div</th>
          <th class="num">Apps</th>
          <th class="num">G</th>
          <th class="num">A</th>
          <th class="num">POTM</th>
          <th class="num">CS</th>
          <th class="num">Avg</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;
}

function formatTransferParties(row) {
  const note = String(row.transfer_sale_note || "").trim();
  const sellerRaw = row.seller_club_short_name;
  const seller =
    displayClubName(sellerRaw) ||
    sellerRaw ||
    (note === "emergency_loan" || !sellerRaw ? "Free agent" : "—");
  let buyer;
  if (note === "emergency_loan_return") {
    buyer = "Free agent";
  } else {
    buyer =
      displayClubName(row.buyer_club_short_name) ||
      row.buyer_club_short_name ||
      row.foreign_buyer_name ||
      "—";
  }
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
        ? "Run supabase/sql/competition_history.sql and patches/player_career_all_seasons_fix.sql in Supabase first."
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
    player.height_cm != null ? `${player.height_cm} cm` : null,
    player.stronger_foot ? `${player.stronger_foot} foot` : null,
    player.weak_foot_usage
      ? `WF use ${player.weak_foot_usage}`
      : null,
    player.weak_foot_accuracy
      ? `WF acc ${player.weak_foot_accuracy}`
      : null,
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
  renderStints(bundle.stints || [], bundle.transfers || [], bundle.competitions || []);
  renderDiscipline(bundle.discipline || []);
  careerHonoursReal = bundle.honours || [];
  setupMedalsPreviewToggle();
  if (params.get("preview") === "medals") {
    setMedalsPreview(true);
  } else {
    renderHonours(careerHonoursReal);
  }
  renderAwards(bundle.awards || []);
});
