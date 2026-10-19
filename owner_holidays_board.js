/**
 * Owners → Info → Owner Holidays board.
 * Public holiday status + early-play fixtures. Never shows email / passwords.
 */
import { initGlobal } from "./global.js";
import { loadClubsMap, fullClubName, clubWithOwnerHtml } from "./clubs_lookup.js";
import { holidayStatusMarkHtml } from "./owner_badge.js";
import { formatUkDateRange } from "./owner_holidays.js";
import { supabase } from "./global.js";

let directory = { holidays: [] };
let filterText = "";

function setStatus(msg, isError = false) {
  const el = document.getElementById("holStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("error", !!isError);
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function matchesFilter(row) {
  const q = filterText.trim().toLowerCase();
  if (!q) return true;
  const blob = [
    row.club_short_name,
    row.club_name,
    row.owner_tag,
    row.status,
    row.status_code,
    ...(row.fixtures || []).flatMap((f) => [
      f.home_club,
      f.away_club,
      f.gpsl_month,
      f.competition,
    ]),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  return blob.includes(q);
}

function fixtureLine(f) {
  const home = fullClubName(f.home_club) || f.home_club;
  const away = fullClubName(f.away_club) || f.away_club;
  const month = f.gpsl_month || "—";
  const comp = f.competition || "Match";
  return `<li><b>${escapeHtml(comp)}</b> · ${escapeHtml(month)} · ${escapeHtml(home)} vs ${escapeHtml(away)}</li>`;
}

function renderTable(rows, emptyMsg) {
  if (!rows.length) {
    return `<p class="hol-empty">${escapeHtml(emptyMsg)}</p>`;
  }
  return `
    <table class="hol-table">
      <thead>
        <tr>
          <th>Status</th>
          <th>Club / owner</th>
          <th>Dates</th>
          <th>Days</th>
          <th>Fixtures to arrange / play early</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const code = row.status_code || (row.status === "active" ? "OH" : "UH");
            const club = clubWithOwnerHtml(
              row.club_name || row.club_short_name,
              row.club_short_name,
              "inline"
            );
            const fixtures = Array.isArray(row.fixtures) ? row.fixtures : [];
            const fixHtml = fixtures.length
              ? `<ul class="hol-fixtures">${fixtures.map(fixtureLine).join("")}</ul>`
              : `<span class="muted">No overlapping scheduled fixtures yet</span>`;
            return `
          <tr>
            <td>${holidayStatusMarkHtml(code)} <span class="muted">${
              code === "OH" ? "On holiday" : "Upcoming"
            }</span></td>
            <td>${club}</td>
            <td>${escapeHtml(formatUkDateRange(row.starts_at, row.ends_at))}</td>
            <td>${Number(row.day_count) || "—"}</td>
            <td>${fixHtml}</td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

function render() {
  const list = (directory.holidays || []).filter(matchesFilter);
  const active = list.filter((h) => h.status === "active" || h.status_code === "OH");
  const upcoming = list.filter((h) => h.status === "upcoming" || h.status_code === "UH");

  const activeWrap = document.getElementById("holActiveWrap");
  const upcomingWrap = document.getElementById("holUpcomingWrap");
  if (activeWrap) {
    activeWrap.innerHTML = renderTable(active, "Nobody is on holiday right now.");
  }
  if (upcomingWrap) {
    upcomingWrap.innerHTML = renderTable(
      upcoming,
      "No upcoming holidays booked."
    );
  }
}

async function loadDirectory() {
  setStatus("Loading…");
  const { data, error } = await supabase.rpc("owner_holidays_directory");
  if (error) {
    setStatus(
      `${error.message}${
        /owner_holidays_directory/i.test(error.message || "")
          ? " — run owner_holiday_inbox_directory_20261019.sql"
          : ""
      }`,
      true
    );
    directory = { holidays: [] };
    render();
    return;
  }
  directory = data && typeof data === "object" ? data : { holidays: [] };
  const n = Array.isArray(directory.holidays) ? directory.holidays.length : 0;
  setStatus(
    n
      ? `${n} holiday booking${n === 1 ? "" : "s"} (upcoming or active).`
      : "No upcoming or active holidays."
  );
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  document.getElementById("holSearch")?.addEventListener("input", (e) => {
    filterText = e.target.value || "";
    render();
  });
  document.getElementById("holRefreshBtn")?.addEventListener("click", () => loadDirectory());
  await loadDirectory();
});
