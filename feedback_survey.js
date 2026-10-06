import { initGlobal } from "./global.js";
import { supabase } from "./supabase_client.js";
import { FEEDBACK_RATINGS, FEEDBACK_TEXTS } from "./feedback_survey_questions.js?v=20261006-feedback";

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", { weekday: "short", day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
}

function ratingRow(q) {
  const opts = [1, 2, 3, 4, 5]
    .map(
      (n) =>
        `<input type="radio" name="r_${q.key}" id="r_${q.key}_${n}" value="${n}"${q.required ? " required" : ""}>` +
        `<label for="r_${q.key}_${n}">${n}</label>`
    )
    .join("");
  const na = q.required
    ? ""
    : `<input type="radio" name="r_${q.key}" id="r_${q.key}_na" value="" checked>` +
      `<label for="r_${q.key}_na" class="na" title="Skip — no opinion">–</label>`;
  return `
    <div class="fb-rate">
      <div class="lbl">${esc(q.label)}${q.required ? ' <span style="color:#ff9900">*</span>' : ""}<small>${esc(q.hint || "")}</small></div>
      <div class="fb-scale" role="radiogroup" aria-label="${esc(q.label)}">${opts}${na}</div>
    </div>`;
}

function recommendRow() {
  const opts = Array.from({ length: 11 }, (_, n) =>
    `<input type="radio" name="recommend" id="rec_${n}" value="${n}"><label for="rec_${n}">${n}</label>`
  ).join("");
  return `
    <div class="fb-scale" role="radiogroup" aria-label="Recommend GPSL">${opts}</div>
    <div class="fb-legend"><span>0 = not at all likely</span><span>10 = extremely likely</span></div>`;
}

function renderForm(root, state) {
  root.innerHTML = `
    <form id="fbForm" novalidate>
      <div class="fb-card">
        <h2>Rate each area</h2>
        <p class="fb-sub">1 = poor · 3 = okay · 5 = excellent. Use – to skip any you have no opinion on.</p>
        ${FEEDBACK_RATINGS.map(ratingRow).join("")}
      </div>
      <div class="fb-card">
        <h2>How likely are you to recommend GPSL to a friend?</h2>
        <p class="fb-sub">Optional.</p>
        ${recommendRow()}
      </div>
      <div class="fb-card fb-text">
        <h2>In your own words</h2>
        <p class="fb-sub">All optional — but this is where the best ideas come from.</p>
        ${FEEDBACK_TEXTS.map(
          (t) => `
            <label for="t_${t.key}">${esc(t.label)} <small>${esc(t.hint || "")}</small></label>
            <textarea id="t_${t.key}" maxlength="4000" class="${t.big ? "big" : ""}"></textarea>`
        ).join("")}
      </div>
      <div class="fb-card">
        <label class="fb-anon">
          <input type="checkbox" id="fbAnon">
          <span>Submit anonymously
            <small>Your answers are saved without your name or club, so the admins can't see who sent them.
            We only record that you've taken part, so you aren't sent a reminder.</small>
          </span>
        </label>
      </div>
      <div class="fb-actions">
        <button type="submit" class="button" id="fbSubmit">Submit feedback</button>
        <span id="fbMsg" class="fb-msg" aria-live="polite"></span>
      </div>
    </form>`;

  const form = document.getElementById("fbForm");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const msg = document.getElementById("fbMsg");
    const btn = document.getElementById("fbSubmit");
    const ratings = {};
    for (const q of FEEDBACK_RATINGS) {
      const v = form.querySelector(`input[name="r_${q.key}"]:checked`)?.value;
      if (v) ratings[q.key] = Number(v);
    }
    if (!ratings.overall) {
      msg.textContent = "Please give an overall rating (top row).";
      msg.className = "fb-msg bad";
      document.getElementById("r_overall_1")?.focus();
      return;
    }
    const rec = form.querySelector('input[name="recommend"]:checked')?.value;
    const text = (k) => document.getElementById(`t_${k}`)?.value.trim() || null;

    btn.disabled = true;
    msg.textContent = "Sending…";
    msg.className = "fb-msg";
    const { error } = await supabase.rpc("owner_feedback_submit", {
      p_survey_id: state.survey_id,
      p_ratings: ratings,
      p_recommend_score: rec === undefined ? null : Number(rec),
      p_liked: text("liked"),
      p_frustrations: text("frustrations"),
      p_recommendation: text("recommendation"),
      p_anonymous: !!document.getElementById("fbAnon")?.checked,
    });
    if (error) {
      btn.disabled = false;
      msg.textContent = error.message || "Could not send your feedback.";
      msg.className = "fb-msg bad";
      return;
    }
    renderThanks(root);
  });
}

function renderThanks(root) {
  document.getElementById("fbIntro").textContent = "";
  root.innerHTML = `
    <div class="fb-card fb-done">
      <h2>Thank you! 🙌</h2>
      <p>Your feedback has been sent to the GPSL admins. Every response is read.</p>
      <p><a class="button-link" href="dashboard.html">Back to dashboard</a></p>
    </div>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const intro = document.getElementById("fbIntro");
  const root = document.getElementById("fbRoot");

  const { data, error } = await supabase.rpc("owner_feedback_current");
  if (error) {
    intro.textContent = /owner_feedback/.test(error.message || "")
      ? "The feedback survey isn't available yet."
      : error.message || "Could not load the survey.";
    return;
  }
  if (!data?.open) {
    intro.textContent =
      "There's no feedback survey open right now. You'll get an inbox invite when the next one opens.";
    return;
  }
  if (data.completed) {
    intro.textContent = "";
    root.innerHTML = `
      <div class="fb-card fb-done">
        <h2>You've already taken part — thank you!</h2>
        <p>Completed ${esc(fmtWhen(data.completed_at))}. The survey closes ${esc(fmtWhen(data.closes_at))}.</p>
      </div>`;
    return;
  }
  if (!data.club_short_name) {
    intro.textContent = "The feedback survey is for club owners.";
    return;
  }
  intro.innerHTML = `Help shape GPSL. It takes about 3 minutes — only the overall rating is required.
    Open until <b>${esc(fmtWhen(data.closes_at))}</b>.`;
  renderForm(root, data);
});
