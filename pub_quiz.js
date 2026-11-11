import { supabase, initGlobal } from "./global.js?v=20261111-pubquiz";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function money(n) {
  return `₿${Math.round(Number(n) || 0).toLocaleString("en-GB")}`;
}

function prize(place, quiz) {
  if (place === 1) return Number(quiz.prize_1) || 0;
  if (place === 2) return Number(quiz.prize_2) || 0;
  if (place === 3) return Number(quiz.prize_3) || 0;
  return Number(quiz.prize_rest) || 0;
}

async function loadBoard() {
  const note = document.getElementById("quizNote");
  const board = document.getElementById("board");
  const { data, error } = await supabase.rpc("gpsl_pub_quiz_public_board", { p_quiz_id: null });
  if (error) {
    note.textContent = "";
    board.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
    return;
  }
  const quiz = data?.quiz;
  const rows = Array.isArray(data?.rows) ? data.rows : [];
  if (!quiz) {
    note.textContent = "No pub quiz has been scheduled yet.";
    board.innerHTML = "";
    return;
  }
  const when = quiz.starts_at ? new Date(quiz.starts_at).toLocaleString("en-GB", { timeZone: "Europe/London" }) : "";
  note.textContent = [
    quiz.status === "live" ? "Live now." : quiz.status === "scheduled" ? `Scheduled for ${when} UK.` : "Finished.",
    quiz.last_reveal ? `Last answer: ${quiz.last_reveal}.` : "",
    "1st ₿5,000 · 2nd ₿3,500 · 3rd ₿2,000 · everyone else who answered ₿1,000.",
  ].filter(Boolean).join(" ");
  if (!rows.length) {
    board.innerHTML = `<div class="empty">No scores yet.</div>`;
    return;
  }
  const showPrize = quiz.status === "finished";
  board.innerHTML = `<table>
    <thead><tr><th class="num">Place</th><th>Owner</th><th class="num">Points</th>${showPrize ? `<th class="num">Prize</th>` : ""}</tr></thead>
    <tbody>
      ${rows.map((r) => `<tr>
        <td class="num">${r.place}</td>
        <td>${escapeHtml(r.owner_tag || "Owner")}</td>
        <td class="num">${r.points ?? 0}</td>
        ${showPrize ? `<td class="num">${money(prize(Number(r.place), quiz))}</td>` : ""}
      </tr>`).join("")}
    </tbody>
  </table>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadBoard();
  setInterval(loadBoard, 15000);
});
