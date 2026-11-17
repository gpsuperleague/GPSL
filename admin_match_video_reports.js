import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { DIVISION_LABELS, CUP_LABELS, GPSL_MONTH_LABELS } from "./competition.js";
import {
  loadFixtureUnavailable,
  formatFixtureUnavailableHtml,
} from "./player_discipline.js?v=20261116-review-fix";

primeAdminPageChrome();

let filterStatus = "open";
let tariffEffects = new Map();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  document.getElementById("filterOpenBtn").onclick = () => {
    filterStatus = "open";
    loadReports();
  };
  document.getElementById("filterApprovedBtn").onclick = () => {
    filterStatus = "approved";
    loadReports();
  };
  document.getElementById("filterRejectedBtn").onclick = () => {
    filterStatus = "rejected";
    loadReports();
  };
  document.getElementById("filterAllBtn").onclick = () => {
    filterStatus = "all";
    loadReports();
  };
  await loadTariffEffects();
  await loadReports();
});

async function loadTariffEffects() {
  const { data } = await supabase.from("competition_fine_tariff").select("code, match_effect");
  tariffEffects = new Map((data || []).map((t) => [t.code, t.match_effect || "none"]));
}

function reportNeedsReplayChoice(r) {
  const list = Array.isArray(r.breaches) ? r.breaches : [];
  return list.some((b) => tariffEffects.get(b.code) === "admin_decides");
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function monthLabel(r) {
  const key = String(r.gpsl_month || "").toLowerCase();
  return GPSL_MONTH_LABELS[key] || r.gpsl_month || "";
}

function competitionLine(r) {
  const month = monthLabel(r);
  if (r.competition_type === "cup") {
    const cup = CUP_LABELS[r.cup_code] || r.cup_code || "Cup";
    const round = r.cup_round != null && r.cup_round !== "" ? `Round ${r.cup_round}` : "";
    return [cup, round, month].filter(Boolean).join(" · ");
  }
  const div = DIVISION_LABELS[r.division] || r.division || "League";
  const md = r.matchday != null && r.matchday !== "" ? `Matchday ${r.matchday}` : "";
  return [div, md, month].filter(Boolean).join(" · ");
}

function fixturePageHref(r) {
  const id = Number(r.fixture_id);
  if (!id) return "";
  const params = new URLSearchParams();
  params.set("locate", String(id));
  if (r.competition_type === "cup") {
    params.set("view", "cups");
    if (r.cup_code) params.set("cup", r.cup_code);
  } else {
    params.set("view", "league");
    if (r.division) params.set("division", r.division);
    if (r.gpsl_month) params.set("month", String(r.gpsl_month).toLowerCase());
  }
  return `fixtures.html?${params.toString()}`;
}

function formationDragOutcome(r, instances) {
  const accused = String(r.accused_club_short_name || "").toUpperCase();
  const home = String(r.home_club_short_name || "").toUpperCase();
  const hg = Number(r.home_goals);
  const ag = Number(r.away_goals);
  const pen = String(r.cup_pen_winner_club_short_name || "").toUpperCase();
  let offenderWonOrDrew = false;
  if (Number.isFinite(hg) && Number.isFinite(ag)) {
    if (hg === ag && !pen) offenderWonOrDrew = true;
    else if (hg === ag && pen) offenderWonOrDrew = pen === accused;
    else if (hg > ag) offenderWonOrDrew = accused === home;
    else offenderWonOrDrew = accused !== home && accused !== "";
  }
  const n = Number(instances) || 1;
  const points = n >= 2 ? " −1 league point." : "";
  return offenderWonOrDrew
    ? `If you approve: match is replayed.${points}`
    : `If you approve: result stands.${points}`;
}

function breachesHtml(r) {
  const list = Array.isArray(r.breaches) ? r.breaches : [];
  if (!list.length) {
    return r.note
      ? `<div class="mvr-breach"><b>${escapeHtml(r.breach_tariff_code || "Breach")}</b><br>${escapeHtml(
          r.note
        )}</div>`
      : `<p class="note">No breach details.</p>`;
  }
  return list
    .map(
      (b) => `
      <div class="mvr-breach">
        <b>${escapeHtml(b.label || b.code)}</b>
        ${
          b.code === "formation_player_drag"
            ? `<div class="mvr-note">Drags reported: <b>${escapeHtml(
                String(b.instances || 1)
              )}</b>. ${escapeHtml(formationDragOutcome(r, b.instances || 1))}</div>`
            : tariffEffects.get(b.code) === "replay_if_won_or_drew"
              ? `<div class="mvr-note">${escapeHtml(formationDragOutcome(r, 1))}</div>`
              : ""
        }
        <div class="mvr-note">${escapeHtml(b.note || "—")}</div>
      </div>`
    )
    .join("");
}

async function loadReports() {
  const list = document.getElementById("reportsList");
  setStatus("reportsStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_match_video_list_breach_reports", {
    p_status: filterStatus,
    p_limit: 150,
  });
  if (error) {
    setStatus("reportsStatus", error.message, false);
    list.innerHTML = "";
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  const fixtureIds = [...new Set(rows.map((r) => Number(r.fixture_id)).filter((id) => id > 0))];
  const unavailableByFixture = new Map();
  await Promise.all(
    fixtureIds.map(async (id) => {
      unavailableByFixture.set(id, await loadFixtureUnavailable(supabase, id));
    })
  );
  if (!rows.length) {
    list.innerHTML = `<p class="note">No ${
      filterStatus === "all" ? "" : filterStatus + " "
    }reports.</p>`;
    setStatus("reportsStatus", "", true);
    return;
  }

  list.innerHTML = rows
    .map((r) => {
      const status = r.status || "open";
      const pill = `<span class="status-pill status-${escapeHtml(status)}">${escapeHtml(
        status
      )}</span>`;
      const recording = r.video_url
        ? `<a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener noreferrer">Open recording</a>`
        : "";
      const fixtureHref = fixturePageHref(r);
      const fixtureLink = fixtureHref
        ? `<a href="${escapeHtml(fixtureHref)}">Open fixture</a>`
        : "";
      const links = [recording, fixtureLink].filter(Boolean).join("");
      const sideLabel =
        String(r.side || "").toLowerCase() === "away" ? "Away video" : "Home video";
      const count = r.breach_count ?? (Array.isArray(r.breaches) ? r.breaches.length : 0);
      const replayChoice = reportNeedsReplayChoice(r)
        ? `
        <label>This match
          <select data-replay="${r.id}">
            <option value="leave">Leave the result</option>
            <option value="replay">Replay</option>
          </select>
        </label>
        <p class="note" style="margin:8px 0 0">This tariff asks you to decide. Leave the result unless you choose Replay.</p>`
        : "";
      const openActions =
        status === "open"
          ? `
        <label>Staff note (optional)
          <textarea data-note="${r.id}" maxlength="500" placeholder="Optional review note"></textarea>
        </label>
        ${replayChoice}
        <div class="mvr-actions">
          <button type="button" class="button" data-approve="${r.id}">OK / Approve</button>
          <button type="button" class="button secondary" data-reject="${r.id}">Reject</button>
        </div>
        <p class="note" style="margin:8px 0 0">
          Approve applies a fine for each listed breach and credits the reporter ₿2,000 Building Society, once per match.
          A formation-drag breach is not a fine: approve replays the match if the offender won or drew, leaves the result if the opponent won, and deducts 1 league point when 2 or more drags were reported.
          Reject closes this match side forever (no re-report).
        </p>`
          : `<p class="note" style="margin:0">Resolved ${
              r.reviewed_at ? new Date(r.reviewed_at).toLocaleString("en-GB") : ""
            }${r.reward_ledger_id ? " · reporter rewarded ₿2,000" : ""}${
              r.review_note ? ` · ${escapeHtml(r.review_note)}` : ""
            }</p>`;

      const outs = formatFixtureUnavailableHtml(unavailableByFixture.get(Number(r.fixture_id)), {
        homeName: r.home_club_short_name,
        awayName: r.away_club_short_name,
        title: "Should not have played",
      });
      return `
        <article class="mvr-card" data-id="${r.id}">
          <h3>${count} breach${count === 1 ? "" : "es"} ${pill}</h3>
          <div class="mvr-outs">${outs}</div>
          <div class="mvr-meta">
            <div class="mvr-where">${escapeHtml(competitionLine(r))}</div>
            ${escapeHtml(r.home_club_short_name)} vs ${escapeHtml(r.away_club_short_name)} ·
            ${escapeHtml(sideLabel)} ·
            accused <b>${escapeHtml(r.accused_club_short_name)}</b> ·
            #${r.id} · ${new Date(r.created_at).toLocaleString("en-GB")}
            ${links ? `<div class="mvr-links">${links}</div>` : ""}
          </div>
          <div class="mvr-breaches">${breachesHtml(r)}</div>
          ${openActions}
        </article>`;
    })
    .join("");

  list.querySelectorAll("[data-approve]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-approve")), "approve");
  });
  list.querySelectorAll("[data-reject]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-reject")), "reject");
  });
  setStatus("reportsStatus", `${rows.length} report(s)`, true);
}

async function resolveReport(id, action) {
  const card = document.querySelector(`.mvr-card[data-id="${id}"]`);
  const note = card?.querySelector(`[data-note="${id}"]`)?.value || null;
  const replaySel = card?.querySelector(`[data-replay="${id}"]`);
  const replayChoice = replaySel ? replaySel.value === "replay" : null;
  if (
    action === "reject" &&
    !confirm("Reject this report? This match side can never be reported again.")
  ) {
    return;
  }
  if (
    action === "approve" &&
    !confirm(
      `Approve this report? Fines apply to ordinary breaches. A formation-drag breach replays the match if the offender won or drew, leaves the result if the opponent won, and deducts 1 league point when 2 or more drags were reported. The reporter gets ₿2,000 Building Society, unless they were already rewarded for the other video of this match.${
        replaySel
          ? replayChoice
            ? " You chose to replay this match."
            : " You chose to leave the result."
          : ""
      }`
    )
  ) {
    return;
  }
  setStatus(
    "reportsStatus",
    `${action === "approve" ? "Approving" : "Rejecting"} #${id}…`
  );
  const { data, error } = await supabase.rpc("admin_match_video_resolve_breach_report", {
    p_report_id: id,
    p_action: action,
    p_tariff_code: null,
    p_review_note: note,
    p_amount_override: null,
    p_replay: replayChoice,
  });
  if (error) {
    setStatus("reportsStatus", error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus("reportsStatus", data?.reason || "Failed", false);
    return;
  }
  setStatus(
    "reportsStatus",
    action === "approve"
      ? `Approved #${id}${data.reward_ledger_id ? " · reporter +₿2,000 BS" : ""}`
      : `Rejected #${id}`,
    true
  );
  await loadReports();
}
