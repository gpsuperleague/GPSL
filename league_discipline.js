import { supabase, initGlobal } from "./global.js?v=20261111-discipline";
import { loadCurrentSeason, DIVISION_LABELS } from "./competition.js";
import { gpslPlayerCareerUrl } from "./player_links.js";
import { YELLOW_BAN_EVERY } from "./player_discipline.js?v=20261111-yc5";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function divisionLabel(division) {
  return DIVISION_LABELS[division] || division || "—";
}

function clubHref(shortName) {
  return `club.html?club=${encodeURIComponent(String(shortName || "").trim())}`;
}

function clubLinkHtml(shortName, displayName) {
  const short = String(shortName || "").trim();
  const label = displayName || short || "—";
  if (!short) return escapeHtml(label);
  return `<a class="gpsl-link" href="${clubHref(short)}">${escapeHtml(label)}</a>`;
}

function playerLinkHtml(playerId, name) {
  const id = String(playerId || "").trim();
  const label = name || id || "—";
  if (!id) return escapeHtml(label);
  return `<a class="gpsl-link" href="${gpslPlayerCareerUrl(id)}">${escapeHtml(label)}</a>`;
}

function towardBan(yellows) {
  const y = Number(yellows) || 0;
  if (y <= 0) return 0;
  const rem = y % YELLOW_BAN_EVERY;
  return rem === 0 ? YELLOW_BAN_EVERY : rem;
}

function sortRows(rows) {
  return [...rows].sort((a, b) => {
    return (
      (b.red_cards || 0) - (a.red_cards || 0) ||
      (b.yellow_cards || 0) - (a.yellow_cards || 0) ||
      String(a.player_name || "").localeCompare(String(b.player_name || ""))
    );
  });
}

function renderSummary(rows, seasonLabel) {
  const wrap = document.getElementById("disciplineSummary");
  if (!wrap) return;
  const reds = rows.reduce((sum, row) => sum + (Number(row.red_cards) || 0), 0);
  const yellows = rows.reduce((sum, row) => sum + (Number(row.yellow_cards) || 0), 0);
  const top = rows.find((row) => (Number(row.red_cards) || 0) > 0) || rows[0];
  const topLabel = top
    ? `${playerLinkHtml(top.player_id, top.player_name)} <span class="muted">(${top.red_cards} red${top.red_cards === 1 ? "" : "s"})</span>`
    : "—";

  wrap.innerHTML = `
    <div class="card"><div class="metric-label">Season</div><div class="metric-value" style="font-size:20px">${escapeHtml(seasonLabel || "Current")}</div></div>
    <div class="card"><div class="metric-label">Players</div><div class="metric-value">${rows.length}</div></div>
    <div class="card"><div class="metric-label">Red cards</div><div class="metric-value">${reds}</div></div>
    <div class="card"><div class="metric-label">Yellow cards</div><div class="metric-value">${yellows}</div></div>
    <div class="card"><div class="metric-label">Most reds</div><div class="metric-value" style="font-size:16px;line-height:1.35">${topLabel}</div></div>
  `;
}

function renderTable(rows, myClub) {
  const wrap = document.getElementById("leagueDisciplineTableWrap");
  if (!wrap) return;

  if (!rows.length) {
    wrap.innerHTML = `<div class="empty">No cards recorded this season yet.</div>`;
    return;
  }

  const mine = String(myClub || "").trim().toUpperCase();
  wrap.innerHTML = `
    <table>
      <thead>
        <tr>
          <th class="num">#</th>
          <th>Player</th>
          <th>Club</th>
          <th>Division</th>
          <th class="num">Reds</th>
          <th class="num">Yellows</th>
          <th class="num">Toward ban</th>
          <th class="num">Bans</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row, index) => {
            const club = String(row.club_short_name || "").trim().toUpperCase();
            const y = Number(row.yellow_cards) || 0;
            return `
              <tr class="${mine && club === mine ? "highlight" : ""}">
                <td class="num">${index + 1}</td>
                <td>${playerLinkHtml(row.player_id, row.player_name)}</td>
                <td>${clubLinkHtml(row.club_short_name, row.club_name || row.club_short_name)}</td>
                <td>${escapeHtml(divisionLabel(row.division))}</td>
                <td class="num rc">${Number(row.red_cards) || 0}</td>
                <td class="num">${y}</td>
                <td class="num">${towardBan(y)}/${YELLOW_BAN_EVERY}</td>
                <td class="num">${Number(row.suspensions) || 0}</td>
              </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;
}

async function loadMyClubShort() {
  const { data: userData } = await supabase.auth.getUser();
  const user = userData?.user;
  if (!user) return "";
  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  return club?.ShortName || "";
}

async function loadLeagueDiscipline() {
  const status = document.getElementById("leagueDisciplineStatus");
  const tableWrap = document.getElementById("leagueDisciplineTableWrap");
  try {
    status.textContent = "Loading discipline…";
    tableWrap.innerHTML = "";

    const [season, mine, rpc] = await Promise.all([
      loadCurrentSeason(supabase),
      loadMyClubShort(),
      supabase.rpc("competition_league_discipline_leaders", {
        p_season_id: null,
        p_division: null,
        p_limit: 2000,
      }),
    ]);

    if (rpc.error) throw rpc.error;
    const rows = sortRows(Array.isArray(rpc.data) ? rpc.data : []);
    renderSummary(rows, season?.name || season?.label || "Current season");
    renderTable(rows, mine);
    status.innerHTML = `<span class="muted">Sorted by red cards, then yellow cards, then name. Toward ban resets after each 5th yellow. Bans are red cards plus yellow-card bans already issued.</span>`;
  } catch (err) {
    console.error("loadLeagueDiscipline failed:", err);
    status.textContent = "";
    tableWrap.innerHTML = `<div class="error">Could not load discipline: ${escapeHtml(err.message || err)}</div>`;
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadLeagueDiscipline();
});
