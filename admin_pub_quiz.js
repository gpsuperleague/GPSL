import { initAdminPage, supabase } from "./admin_common.js";

const MEDIA_BASE = "https://omyyogfumrjoaweuawjn.supabase.co/storage/v1/object/public/pub-quiz/";

let bundle = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function say(text, isError = false) {
  const el = document.getElementById("status");
  if (!el) return;
  el.className = isError ? "status err" : "status";
  el.textContent = text || "";
}

function pad(n) {
  return String(n).padStart(2, "0");
}

function toLocalInput(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

async function refreshList(selectId) {
  const { data, error } = await supabase.rpc("gpsl_pub_quiz_admin_list");
  if (error) throw error;
  const rows = Array.isArray(data) ? data : [];
  const sel = document.getElementById("quizPick");
  sel.innerHTML = rows
    .map((q) => `<option value="${q.id}">#${q.id} · ${escapeHtml(q.status)} · ${escapeHtml(q.title)}</option>`)
    .join("");
  if (selectId) sel.value = String(selectId);
  if (!sel.value && rows[0]) sel.value = String(rows[0].id);
  return rows;
}

async function loadQuiz(id) {
  if (!id) {
    bundle = null;
    document.getElementById("rounds").innerHTML = "";
    document.getElementById("scheduleRow").hidden = true;
    return;
  }
  const { data, error } = await supabase.rpc("gpsl_pub_quiz_admin_get", { p_id: Number(id) });
  if (error) throw error;
  bundle = data;
  const quiz = data?.quiz || {};
  document.getElementById("scheduleRow").hidden = false;
  document.getElementById("startsAt").value = toLocalInput(quiz.starts_at);
  const locked = quiz.status && !["draft", "scheduled"].includes(quiz.status);
  document.getElementById("scheduleBtn").disabled = locked;
  document.getElementById("startNow").disabled = locked;
  const { data: missing, error: missErr } = await supabase.rpc("gpsl_pub_quiz_missing", { p_id: Number(id) });
  if (missErr) throw missErr;
  document.getElementById("missingNote").textContent = missing
    ? `${missing} still to fill`
    : "All 50 questions are filled";
  renderRounds(data.rounds || [], locked);
}

function renderRounds(rounds, locked) {
  const host = document.getElementById("rounds");
  host.innerHTML = rounds
    .map((round) => {
      const questions = (round.questions || [])
        .map((q) => questionCard(round, q, locked))
        .join("");
      return `<details open>
        <summary>Round ${round.round_no} · ${escapeHtml(round.title)} · ${round.answer_seconds}s · ${escapeHtml(round.kind)}</summary>
        ${questions}
      </details>`;
    })
    .join("");
  host.querySelectorAll("[data-save]").forEach((btn) => {
    btn.addEventListener("click", () => saveQuestion(btn.dataset.save));
  });
  host.querySelectorAll("[data-file]").forEach((input) => {
    input.addEventListener("change", () => uploadFile(input));
  });
}

function questionCard(round, q, locked) {
  const dis = locked ? "disabled" : "";
  const file = round.kind === "text"
    ? ""
    : `<label>${round.kind === "song" ? "Audio file" : "Picture"}
        <input data-file="${q.id}" type="file" accept="${round.kind === "song" ? "audio/*" : "image/*"}" ${dis}>
      </label>
      <div class="preview">${previewHtml(round.kind, q.media_path)}</div>`;
  return `<div class="q" data-qid="${q.id}">
    <div class="note">Question ${q.q_no}</div>
    <textarea data-prompt ${dis}>${escapeHtml(q.prompt)}</textarea>
    <div class="q-grid">
      <label>A <input data-a value="${escapeHtml(q.option_a)}" ${dis}></label>
      <label>B <input data-b value="${escapeHtml(q.option_b)}" ${dis}></label>
      <label>C <input data-c value="${escapeHtml(q.option_c)}" ${dis}></label>
      <label>Correct
        <select data-correct ${dis}>
          <option value="a" ${q.correct === "a" ? "selected" : ""}>A</option>
          <option value="b" ${q.correct === "b" ? "selected" : ""}>B</option>
          <option value="c" ${q.correct === "c" ? "selected" : ""}>C</option>
        </select>
      </label>
    </div>
    ${file}
    <div class="row"><button type="button" class="button" data-save="${q.id}" ${dis}>Save question</button></div>
  </div>`;
}

function previewHtml(kind, path) {
  if (!path) return "";
  const url = MEDIA_BASE + path.split("/").map(encodeURIComponent).join("/");
  if (kind === "song") return `<audio controls src="${escapeHtml(url)}"></audio>`;
  return `<img alt="" src="${escapeHtml(url)}">`;
}

function card(id) {
  return document.querySelector(`.q[data-qid="${id}"]`);
}

async function saveQuestion(id) {
  const el = card(id);
  if (!el) return;
  say("Saving…");
  const { error } = await supabase.rpc("gpsl_pub_quiz_save_question", {
    p_question_id: Number(id),
    p_prompt: el.querySelector("[data-prompt]").value,
    p_a: el.querySelector("[data-a]").value,
    p_b: el.querySelector("[data-b]").value,
    p_c: el.querySelector("[data-c]").value,
    p_correct: el.querySelector("[data-correct]").value,
  });
  if (error) {
    say(error.message, true);
    return;
  }
  say("Saved.");
  await loadQuiz(document.getElementById("quizPick").value);
}

async function uploadFile(input) {
  const id = input.dataset.file;
  const file = input.files?.[0];
  const quizId = document.getElementById("quizPick").value;
  if (!file || !quizId) return;
  const ext = (file.name.split(".").pop() || "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
  const path = `${quizId}/${id}.${ext}`;
  say("Uploading…");
  const { error } = await supabase.storage.from("pub-quiz").upload(path, file, {
    upsert: true,
    contentType: file.type || undefined,
  });
  if (error) {
    say(error.message, true);
    return;
  }
  const saved = await supabase.rpc("gpsl_pub_quiz_set_media", {
    p_question_id: Number(id),
    p_path: path,
  });
  if (saved.error) {
    say(saved.error.message, true);
    return;
  }
  say("File saved.");
  await loadQuiz(quizId);
}

async function schedule(startNow) {
  const id = Number(document.getElementById("quizPick").value);
  if (!id) return;
  const raw = document.getElementById("startsAt").value;
  const when = startNow ? new Date() : new Date(raw);
  if (Number.isNaN(when.getTime())) {
    say("Pick a start time.", true);
    return;
  }
  say("Scheduling…");
  const { error } = await supabase.rpc("gpsl_pub_quiz_schedule", {
    p_id: id,
    p_starts_at: when.toISOString(),
  });
  if (error) {
    say(error.message, true);
    return;
  }
  const kick = await supabase.rpc("gpsl_pub_quiz_admin_kick");
  if (kick.error) {
    say(`Scheduled, but the quiz runner did not start: ${kick.error.message}`, true);
    return;
  }
  say(startNow ? "Started. The first question posts in #pub quiz." : "Scheduled. A countdown posts in #pub quiz five minutes before the start.");
  await refreshList(id);
  await loadQuiz(id);
}

document.getElementById("newQuiz").addEventListener("click", async () => {
  say("Creating…");
  const { data, error } = await supabase.rpc("gpsl_pub_quiz_create");
  if (error) {
    say(error.message, true);
    return;
  }
  await refreshList(data?.id);
  await loadQuiz(data?.id);
  say("Quiz created. Fill all 50 questions, then schedule it.");
});

document.getElementById("quizPick").addEventListener("change", async (ev) => {
  try {
    await loadQuiz(ev.target.value);
  } catch (err) {
    say(err.message || String(err), true);
  }
});

document.getElementById("scheduleBtn").addEventListener("click", () => schedule(false));
document.getElementById("startNow").addEventListener("click", () => schedule(true));
document.getElementById("testQuiz").addEventListener("click", async () => {
  const id = Number(document.getElementById("quizPick").value);
  if (!id) return;
  say("Starting a 3-question test…");
  const { data, error } = await supabase.rpc("gpsl_pub_quiz_start_test", { p_source_id: id });
  if (error) {
    say(error.message, true);
    return;
  }
  const kick = await supabase.rpc("gpsl_pub_quiz_admin_kick");
  if (kick.error) {
    say(`Test was created, but the runner did not start: ${kick.error.message}`, true);
    return;
  }
  say("Test posted to #pub quiz. The new quiz in the list has the three questions. No prizes. Save question on the main quiz stores your own.");
  await refreshList(data?.id);
  await loadQuiz(document.getElementById("quizPick").value);
});

initAdminPage().then(async (user) => {
  if (!user) return;
  try {
    const rows = await refreshList();
    if (rows[0]) await loadQuiz(rows[0].id);
  } catch (err) {
    say(err.message || String(err), true);
  }
});
