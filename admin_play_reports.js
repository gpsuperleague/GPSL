import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js?v=20261123-play-coverage";
import { DIVISION_LABELS, CUP_LABELS, GPSL_MONTH_LABELS } from "./competition.js?v=20261123-play-coverage";

primeAdminPageChrome();

let filterStatus = "open";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("filterOpenBtn").onclick = () => {
    filterStatus = "open";
    loadQueue();
  };
  document.getElementById("filterDecidedBtn").onclick = () => {
    filterStatus = "decided";
    loadQueue();
  };
  document.getElementById("filterAllBtn").onclick = () => {
    filterStatus = "all";
    loadQueue();
  };
  await loadQueue();
});

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", { timeZone: "Europe/London", hour12: false });
}

function compLine(row) {
  const monthKey = String(row.gpsl_month || "").toLowerCase();
  const month = GPSL_MONTH_LABELS[monthKey] || row.gpsl_month || "";
  if (row.competition_type === "cup") {
    const cup = CUP_LABELS[row.cup_code] || row.cup_code || "Cup";
    return [cup, month].filter(Boolean).join(" · ");
  }
  const div = DIVISION_LABELS[row.division] || row.division || "League";
  const md = row.matchday != null && row.matchday !== "" ? `Matchday ${row.matchday}` : "";
  return [div, md, month].filter(Boolean).join(" · ");
}

function renderReports(rows) {
  const root = document.getElementById("reportsList");
  if (!rows.length) {
    root.innerHTML = `<p class="note">No reports in this list.</p>`;
    return;
  }
  root.innerHTML = rows
    .map((r) => {
      const video = r.video_url
        ? `<div class="pr-meta"><a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener">Match video</a></div>`
        : `<div class="pr-meta">No video — they did not say the match was played.</div>`;
      const decide =
        r.status === "open"
          ? `<label>Note
              <textarea id="note-${r.id}" placeholder="Optional note"></textarea>
            </label>
            <div class="pr-actions">
              <button type="button" class="button" data-decide="uphold" data-id="${r.id}">Uphold</button>
              <button type="button" class="button secondary" data-decide="dismiss" data-id="${r.id}">Dismiss</button>
            </div>`
          : r.admin_note
            ? `<div class="pr-meta">${escapeHtml(r.admin_note)}</div>`
            : "";
      return `<article class="pr-card">
        <h3>${escapeHtml(r.reporter_name || r.reporter_club)} reported ${escapeHtml(r.accused_name || r.accused_club)}</h3>
        <div class="pr-meta">
          <span class="status-pill status-${escapeHtml(r.status)}">${escapeHtml(r.status)}</span>
          ${r.match_played ? " · match was played" : " · did not turn up"}
          · ${escapeHtml(compLine(r))}
          · kick-off ${escapeHtml(when(r.kickoff_at))} UK
        </div>
        ${video}
        <div class="pr-meta"><a href="fixture_schedule.html?fixture=${r.fixture_id}">Schedule</a></div>
        ${decide}
      </article>`;
    })
    .join("");

  root.querySelectorAll("[data-decide]").forEach((btn) => {
    btn.onclick = () => decide(Number(btn.dataset.id), btn.dataset.decide === "uphold");
  });
}

function renderPlayed(rows) {
  const root = document.getElementById("playedList");
  if (!rows.length) {
    root.innerHTML = `<p class="note">No Already played filings with a video yet.</p>`;
    return;
  }
  root.innerHTML = rows
    .map(
      (r) => `<article class="pr-card">
        <h3>${escapeHtml(r.home_name || r.home_club_short_name)} vs ${escapeHtml(r.away_name || r.away_club_short_name)}</h3>
        <div class="pr-meta">
          Filed by ${escapeHtml(r.filed_by_name || r.filed_by_club || "a club")}
          · ${escapeHtml(compLine(r))}
          · ${escapeHtml(when(r.completed_at))} UK
        </div>
        <div class="pr-meta"><a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener">Match video</a>
          · <a href="fixture_schedule.html?fixture=${r.fixture_id}">Schedule</a></div>
      </article>`
    )
    .join("");
}

async function loadQueue() {
  setStatus("listStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_play_coverage_queue", {
    p_status: filterStatus,
  });
  if (error) {
    setStatus("listStatus", error.message, false);
    return;
  }
  const reports = Array.isArray(data?.reports) ? data.reports : [];
  const played = Array.isArray(data?.already_played) ? data.already_played : [];
  renderReports(reports);
  renderPlayed(played);
  setStatus("listStatus", "");
}

async function decide(id, uphold) {
  const note = document.getElementById(`note-${id}`)?.value || "";
  const verb = uphold ? "Uphold" : "Dismiss";
  if (!confirm(`${verb} this no-show report?`)) return;
  setStatus("listStatus", `${verb}…`);
  const { error } = await supabase.rpc("admin_play_report_decide", {
    p_id: id,
    p_uphold: uphold,
    p_note: note,
  });
  if (error) {
    setStatus("listStatus", error.message, false);
    return;
  }
  await loadQueue();
}
