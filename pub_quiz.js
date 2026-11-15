import { supabase, initGlobal } from "./global.js?v=20261111-pubquiz";

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
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
  ].filter(Boolean).join(" ");
  if (!rows.length) {
    board.innerHTML = `<div class="empty">No scores yet.</div>`;
    return;
  }
  board.innerHTML = `<table>
    <thead><tr><th class="num">Place</th><th>Owner</th><th class="num">Points</th></tr></thead>
    <tbody>
      ${rows.map((r) => `<tr>
        <td class="num">${r.place}</td>
        <td>${escapeHtml(r.owner_tag || "Owner")}</td>
        <td class="num">${r.points ?? 0}</td>
      </tr>`).join("")}
    </tbody>
  </table>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadBoard();
  setInterval(loadBoard, 15000);
});
