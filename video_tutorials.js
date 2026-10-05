import { initGlobal } from "./global.js";
import { supabase } from "./supabase_client.js";
import { VIDEO_TUTORIAL_SECTIONS } from "./video_tutorials_content.js?v=20261005-vt-admin";
import { loadVideoTutorials, sortVt, youtubeId } from "./video_tutorials_data.js?v=20261005-vt-admin";

let folders = [];
let links = [];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function safeUrl(url) {
  const s = String(url || "").trim();
  return /^https?:\/\//i.test(s) ? s : null;
}

function fallbackFromContentFile() {
  const f = [];
  const l = [];
  VIDEO_TUTORIAL_SECTIONS.forEach((sec, i) => {
    f.push({ id: i + 1, parent_id: null, title: sec.title, slug: sec.id, sort_order: i });
    (sec.videos || []).forEach((v, j) => l.push({ id: j, folder_id: i + 1, sort_order: j, ...v }));
  });
  return { folders: f, links: l };
}

const childrenOf = (id) => sortVt(folders.filter((f) => (f.parent_id ?? null) === id));
const linksOf = (id) => sortVt(links.filter((l) => l.folder_id === id));

function hasContent(folder) {
  return linksOf(folder.id).length > 0 || childrenOf(folder.id).some(hasContent);
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

function folderBlock(folder, depth, showEmpty) {
  const cards = linksOf(folder.id).map(videoCard).filter(Boolean);
  const subs = childrenOf(folder.id).filter(hasContent);
  if (!cards.length && !subs.length && !showEmpty) return "";
  const tag = depth === 0 ? "h2" : "h3";
  return `<section class="vt-section${depth ? " vt-sub" : ""}" id="${escapeHtml(folder.slug)}">
    <${tag}><a class="vt-folder-link" href="#${escapeHtml(folder.slug)}">${escapeHtml(folder.title)}</a></${tag}>
    ${folder.description ? `<p class="vt-folder-desc">${escapeHtml(folder.description)}</p>` : ""}
    ${cards.length ? `<div class="vt-grid">${cards.join("")}</div>` : ""}
    ${!cards.length && !subs.length ? `<p class="vt-empty">No videos here yet — check back soon.</p>` : ""}
    ${subs.map((s) => folderBlock(s, depth + 1, false)).join("")}
  </section>`;
}

function breadcrumb(folder) {
  const trail = [];
  let cur = folder;
  while (cur) {
    trail.unshift(cur);
    cur = folders.find((f) => f.id === cur.parent_id);
  }
  return `<nav class="vt-crumbs"><a href="#">All videos</a>${trail
    .map((f, i) =>
      i === trail.length - 1
        ? ` › <span>${escapeHtml(f.title)}</span>`
        : ` › <a href="#${escapeHtml(f.slug)}">${escapeHtml(f.title)}</a>`
    )
    .join("")}</nav>`;
}

function render() {
  const root = document.getElementById("videoTutorials");
  if (!root) return;

  const hash = decodeURIComponent((window.location.hash || "").replace("#", ""));
  const focused = folders.find((f) => f.slug === hash);
  const tops = childrenOf(null).filter(hasContent);

  const toc = tops.length
    ? `<nav class="vt-toc" aria-label="Sections"><a href="#"${focused ? "" : ' class="active"'}>All</a>${tops
        .map(
          (s) =>
            `<a href="#${escapeHtml(s.slug)}"${focused?.id === s.id ? ' class="active"' : ""}>${escapeHtml(s.title)}</a>`
        )
        .join("")}</nav>`
    : "";

  if (focused) {
    const subChips = childrenOf(focused.id).filter(hasContent);
    root.innerHTML =
      toc +
      breadcrumb(focused) +
      (subChips.length
        ? `<div class="vt-subfolders">${subChips
            .map((s) => `<a href="#${escapeHtml(s.slug)}">📁 ${escapeHtml(s.title)}</a>`)
            .join("")}</div>`
        : "") +
      folderBlock(focused, 0, true);
    window.scrollTo({ top: 0 });
    return;
  }

  if (!tops.length) {
    root.innerHTML = `<p class="vt-empty">Video tutorials are coming soon. In the meantime, see
      <a href="learning_gpsl.html">Learning GPSL</a>.</p>`;
    return;
  }

  root.innerHTML = toc + tops.map((f) => folderBlock(f, 0, false)).join("");
}

document.addEventListener("DOMContentLoaded", async () => {
  initGlobal();
  const root = document.getElementById("videoTutorials");
  if (root) root.innerHTML = `<p class="vt-empty">Loading…</p>`;
  const res = await loadVideoTutorials(supabase);
  if (res.error) {
    console.warn("Video tutorials DB load failed, using content file:", res.error);
    ({ folders, links } = fallbackFromContentFile());
  } else {
    folders = res.folders;
    links = res.links;
  }
  render();
  window.addEventListener("hashchange", render);
});
