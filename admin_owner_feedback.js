import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { FEEDBACK_RATINGS, FEEDBACK_TEXTS } from "./feedback_survey_questions.js?v=20261006-feedback";

primeAdminPageChrome();

let surveys = [];
let current = null;

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtWhen(iso, withTime = true) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString(
    "en-GB",
    withTime
      ? { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }
      : { day: "2-digit", month: "short", year: "numeric" }
  );
}

function avgClass(v) {
  if (v == null) return "";
  if (v >= 4) return "good";
  if (v >= 3) return "mid";
  return "low";
}

function selectedSurvey() {
  const id = Number(document.getElementById("ofbSurvey").value);
  return surveys.find((s) => s.id === id) || null;
}

function whoLabel(r) {
  if (r.is_anonymous) return "Anonymous owner";
  const club = r.club_name || r.club_short_name || "";
  return [r.owner_tag, club].filter(Boolean).join(" — ") || "Owner";
}

function renderResults(res) {
  const wrap = document.getElementById("ofbResults");
  const pct = res.owners ? Math.round((100 * res.completed) / res.owners) : 0;
  const rec = res.recommend || {};
  const overall = res.ratings?.overall?.avg;

  const ratingRows = FEEDBACK_RATINGS.map((q) => {
    const st = res.ratings?.[q.key] || {};
    const dist = Array.isArray(st.dist) ? st.dist.map(Number) : [0, 0, 0, 0, 0];
    const max = Math.max(1, ...dist);
    const avg = st.avg != null ? Number(st.avg) : null;
    return `
      <tr>
        <td>${esc(q.label)}</td>
        <td><span class="ofb-avg ${avgClass(avg)}">${avg != null ? avg.toFixed(2) : "—"}</span></td>
        <td>${Number(st.count) || 0}</td>
        <td>
          <div class="ofb-bars" title="${dist.map((n, i) => `${i + 1}★: ${n}`).join(" · ")}">
            ${dist.map((n) => `<span style="height:${Math.round((n / max) * 100)}%"></span>`).join("")}
          </div>
        </td>
        <td class="ofb-muted">${dist.join(" / ")}</td>
      </tr>`;
  }).join("");

  const recos = (res.responses || []).filter((r) => r.recommendation);

  const responses = (res.responses || [])
    .map((r) => {
      const chips = FEEDBACK_RATINGS.filter((q) => r.ratings?.[q.key] != null)
        .map((q) => `<span class="chip">${esc(q.label)}: <b>${r.ratings[q.key]}</b></span>`)
        .join("");
      const texts = FEEDBACK_TEXTS.filter((t) => r[t.key])
        .map(
          (t) =>
            `<div class="${t.key === "recommendation" ? "ofb-reco" : ""}"><div class="q">${esc(t.label)}</div><div class="a">${esc(r[t.key])}</div></div>`
        )
        .join("");
      return `
        <div class="ofb-resp">
          <span class="who">${esc(whoLabel(r))}</span>
          <span class="when">${esc(fmtWhen(r.submitted_on, !r.is_anonymous))}</span>
          ${r.recommend_score != null ? `<span class="when">Recommend: <b>${r.recommend_score}</b>/10</span>` : ""}
          <div class="chips">${chips}</div>
          ${texts || '<div class="ofb-muted">No written comments.</div>'}
        </div>`;
    })
    .join("");

  wrap.innerHTML = `
    <div class="ofb-grid">
      <div class="ofb-card ofb-kpi"><div class="v">${res.completed} / ${res.owners}</div><div class="l">Owners responded (${pct}%)</div></div>
      <div class="ofb-card ofb-kpi"><div class="v ofb-avg ${avgClass(overall)}">${overall != null ? Number(overall).toFixed(2) : "—"}</div><div class="l">Overall enjoyment (out of 5)</div></div>
      <div class="ofb-card ofb-kpi" title="Net Promoter Score: % scoring 9–10 minus % scoring 0–6. Ranges −100 to +100.">
        <div class="v">${rec.nps != null ? rec.nps : "—"}</div>
        <div class="l">Recommend score (NPS) · avg ${rec.avg != null ? rec.avg : "—"}/10 · ${rec.promoters || 0} promoters / ${rec.detractors || 0} detractors</div>
      </div>
      <div class="ofb-card ofb-kpi"><div class="v">${recos.length}</div><div class="l">Recommendations written</div></div>
    </div>

    <div class="ofb-card" style="margin-bottom:16px;">
      <h2>Ratings by area</h2>
      <table class="ofb-table">
        <thead><tr><th>Area</th><th>Average</th><th>Answers</th><th>Spread 1→5</th><th>1 / 2 / 3 / 4 / 5</th></tr></thead>
        <tbody>${ratingRows}</tbody>
      </table>
    </div>

    <div class="ofb-card" style="margin-bottom:16px;">
      <h2>Recommendations (${recos.length})</h2>
      ${
        recos.length
          ? recos
              .map(
                (r) =>
                  `<div class="ofb-resp ofb-reco"><span class="who">${esc(whoLabel(r))}</span><div class="a" style="margin-top:6px">${esc(r.recommendation)}</div></div>`
              )
              .join("")
          : '<p class="ofb-muted">No recommendations yet.</p>'
      }
    </div>

    <div class="ofb-card" style="margin-bottom:16px;">
      <h2>All responses (${(res.responses || []).length})</h2>
      ${responses || '<p class="ofb-muted">No responses yet.</p>'}
    </div>

    <div class="ofb-card">
      <h2>Not responded yet (${(res.not_responded || []).length})</h2>
      ${
        (res.not_responded || []).length
          ? `<ul class="ofb-pending">${res.not_responded
              .map((c) => `<li>${esc(c.club_name || c.club_short_name)}</li>`)
              .join("")}</ul>`
          : '<p class="ofb-muted">Everyone has responded.</p>'
      }
    </div>`;
}

function csvCell(v) {
  const s = String(v ?? "");
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function downloadCsv() {
  if (!current) return;
  const head = [
    "submitted",
    "who",
    ...FEEDBACK_RATINGS.map((q) => q.label),
    "recommend_0_10",
    ...FEEDBACK_TEXTS.map((t) => t.label),
  ];
  const rows = (current.responses || []).map((r) => [
    fmtWhen(r.submitted_on, !r.is_anonymous),
    whoLabel(r),
    ...FEEDBACK_RATINGS.map((q) => r.ratings?.[q.key] ?? ""),
    r.recommend_score ?? "",
    ...FEEDBACK_TEXTS.map((t) => r[t.key] ?? ""),
  ]);
  const csv = [head, ...rows].map((row) => row.map(csvCell).join(",")).join("\r\n");
  const blob = new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `gpsl_owner_feedback_${selectedSurvey()?.id || "survey"}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

function updateButtons() {
  const s = selectedSurvey();
  document.getElementById("ofbExtendBtn").hidden = !s;
  document.getElementById("ofbCloseBtn").hidden = !s?.is_open;
  document.getElementById("ofbCsvBtn").hidden = !s;
}

async function loadResults() {
  const s = selectedSurvey();
  updateButtons();
  const wrap = document.getElementById("ofbResults");
  if (!s) {
    wrap.innerHTML =
      '<p class="ofb-muted">No surveys yet. The first one opens automatically when the calendar moves past August.</p>';
    return;
  }
  wrap.innerHTML = '<p class="ofb-muted">Loading…</p>';
  const { data, error } = await supabase.rpc("admin_owner_feedback_results", { p_survey_id: s.id });
  if (error) {
    setStatus("pageStatus", `❌ ${error.message}`, false);
    return;
  }
  current = data;
  renderResults(data);
}

async function loadSurveys(selectId = null) {
  const { data, error } = await supabase.rpc("admin_owner_feedback_surveys");
  if (error) {
    setStatus(
      "pageStatus",
      `❌ ${error.message} — run supabase/sql/patches/owner_feedback_survey_20261006.sql`,
      false
    );
    document.getElementById("ofbResults").innerHTML = "";
    return;
  }
  surveys = Array.isArray(data) ? data : [];
  const sel = document.getElementById("ofbSurvey");
  sel.innerHTML = surveys.length
    ? surveys
        .map(
          (s) =>
            `<option value="${s.id}">${esc(s.title)} — ${esc(fmtWhen(s.opens_at, false))} → ${esc(
              fmtWhen(s.closes_at, false)
            )} · ${s.is_open ? "OPEN" : "closed"} · ${s.responses}/${s.invited_count || "?"} responses</option>`
        )
        .join("")
    : '<option value="">No surveys yet</option>';
  if (selectId) sel.value = String(selectId);
  await loadResults();
}

async function setClose(closesAt, label) {
  const s = selectedSurvey();
  if (!s) return;
  const { error } = await supabase.rpc("admin_owner_feedback_set_close", {
    p_survey_id: s.id,
    p_closes_at: closesAt.toISOString(),
  });
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  setStatus("pageStatus", `✅ ${label}`);
  await loadSurveys(s.id);
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("ofbSurvey").addEventListener("change", loadResults);
  document.getElementById("ofbCsvBtn").addEventListener("click", downloadCsv);
  document.getElementById("ofbExtendBtn").addEventListener("click", () => {
    const s = selectedSurvey();
    if (!s) return;
    const base = Math.max(Date.now(), new Date(s.closes_at).getTime());
    setClose(new Date(base + 7 * 864e5), "Survey extended by 7 days.");
  });
  document.getElementById("ofbCloseBtn").addEventListener("click", () => {
    if (!window.confirm("Close this survey now? Owners will no longer be able to respond.")) return;
    setClose(new Date(), "Survey closed.");
  });
  document.getElementById("ofbOpenNowBtn").addEventListener("click", async () => {
    const days = window.prompt(
      "Open a survey now and send an inbox invite to every club owner?\n\n(It also opens automatically after August each season.)\n\nHow many days should it stay open?",
      "14"
    );
    if (days == null) return;
    const n = Math.trunc(Number(days));
    if (!Number.isFinite(n) || n < 1) return setStatus("pageStatus", "Enter a number of days.", false);
    const { data, error } = await supabase.rpc("admin_owner_feedback_open_now", { p_days: n });
    if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
    setStatus("pageStatus", `✅ Survey opened — invites sent to ${data?.invited ?? 0} owners.`);
    await loadSurveys(data?.survey_id);
  });
  await loadSurveys();
});
