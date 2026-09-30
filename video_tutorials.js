import { initGlobal } from "./global.js";
import { VIDEO_TUTORIAL_SECTIONS } from "./video_tutorials_content.js?v=20260930-video-tutorials";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function youtubeId(url) {
  const s = String(url || "").trim();
  const m =
    s.match(/youtu\.be\/([\w-]{11})/) ||
    s.match(/[?&]v=([\w-]{11})/) ||
    s.match(/youtube\.com\/(?:embed|shorts|live)\/([\w-]{11})/);
  return m ? m[1] : null;
}

function videoCard(v) {
  const id = youtubeId(v.url);
  if (!id) return "";
  return `<article class="vt-card">
    <div class="vt-frame">
      <iframe src="https://www.youtube-nocookie.com/embed/${id}" title="${escapeHtml(v.title)}"
        loading="lazy" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; fullscreen"
        allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
    </div>
    <h3>${escapeHtml(v.title)}</h3>
    ${v.description ? `<p>${escapeHtml(v.description)}</p>` : ""}
  </article>`;
}

function render() {
  const root = document.getElementById("videoTutorials");
  if (!root) return;
  const sections = VIDEO_TUTORIAL_SECTIONS.map((sec) => ({
    ...sec,
    cards: (sec.videos || []).map(videoCard).filter(Boolean),
  })).filter((sec) => sec.cards.length);

  if (!sections.length) {
    root.innerHTML = `<p class="vt-empty">Video tutorials are coming soon. In the meantime, see
      <a href="learning_gpsl.html">Learning GPSL</a>.</p>`;
    return;
  }

  const toc = sections
    .map((s) => `<a href="#${escapeHtml(s.id)}">${escapeHtml(s.title)}</a>`)
    .join("");
  root.innerHTML =
    `<nav class="vt-toc" aria-label="Sections">${toc}</nav>` +
    sections
      .map(
        (s) => `<section class="vt-section" id="${escapeHtml(s.id)}">
          <h2>${escapeHtml(s.title)}</h2>
          <div class="vt-grid">${s.cards.join("")}</div>
        </section>`
      )
      .join("");
}

document.addEventListener("DOMContentLoaded", () => {
  initGlobal();
  render();
});
