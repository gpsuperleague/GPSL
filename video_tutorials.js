import { initGlobal } from "./global.js";
import { VIDEO_TUTORIAL_SECTIONS } from "./video_tutorials_content.js?v=20261005-vt-transfers";

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

function safeUrl(url) {
  const s = String(url || "").trim();
  return /^https?:\/\//i.test(s) ? s : null;
}

function videoCard(v) {
  const url = safeUrl(v.url);
  if (!url) return "";
  const id = youtubeId(url);
  const title = escapeHtml(v.title || "Watch video");
  const link = `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${title}</a>`;
  const frame = id
    ? `<div class="vt-frame">
      <iframe src="https://www.youtube-nocookie.com/embed/${id}" title="${title}"
        loading="lazy" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; fullscreen"
        allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
    </div>`
    : "";
  return `<article class="vt-card${id ? "" : " vt-card-link"}">
    ${frame}
    <h3>${link}${id ? "" : ` <span class="vt-ext">↗</span>`}</h3>
    ${v.description ? `<p>${escapeHtml(v.description)}</p>` : ""}
  </article>`;
}

function render() {
  const root = document.getElementById("videoTutorials");
  if (!root) return;
  const sections = VIDEO_TUTORIAL_SECTIONS.map((sec) => ({
    ...sec,
    cards: (sec.videos || []).map(videoCard).filter(Boolean),
  }));
  const filled = sections.filter((sec) => sec.cards.length);

  const hash = decodeURIComponent((window.location.hash || "").replace("#", ""));
  const focused = sections.find((s) => s.id === hash);

  const toc = filled
    .map(
      (s) =>
        `<a href="#${escapeHtml(s.id)}"${focused?.id === s.id ? ' class="active"' : ""}>${escapeHtml(s.title)}</a>`
    )
    .join("");
  const tocHtml = filled.length
    ? `<nav class="vt-toc" aria-label="Sections"><a href="#"${focused ? "" : ' class="active"'}>All</a>${toc}</nav>`
    : "";

  const sectionHtml = (s) => `<section class="vt-section" id="${escapeHtml(s.id)}">
      <h2>${escapeHtml(s.title)}</h2>
      ${
        s.cards.length
          ? `<div class="vt-grid">${s.cards.join("")}</div>`
          : `<p class="vt-empty">No ${escapeHtml(s.title)} videos yet — check back soon.</p>`
      }
    </section>`;

  if (focused) {
    root.innerHTML = tocHtml + sectionHtml(focused);
    return;
  }

  if (!filled.length) {
    root.innerHTML = `<p class="vt-empty">Video tutorials are coming soon. In the meantime, see
      <a href="learning_gpsl.html">Learning GPSL</a>.</p>`;
    return;
  }

  root.innerHTML = tocHtml + filled.map(sectionHtml).join("");
}

document.addEventListener("DOMContentLoaded", () => {
  initGlobal();
  render();
  window.addEventListener("hashchange", render);
});
