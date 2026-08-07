/**
 * Learning GPSL — handbook renderer (content in learning_gpsl_content/).
 */
import { initGlobal } from "./global.js";
import {
  LEARNING_GPSL_META_HTML,
  LEARNING_GPSL_SECTIONS,
} from "./learning_gpsl_content.js";

function escapeAttr(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

function renderListItems(items) {
  return (items || [])
    .map((item) => {
      if (item && typeof item === "object") {
        const nested = item.children?.length
          ? `<ul>${renderListItems(item.children)}</ul>`
          : "";
        return `<li>${item.html || ""}${nested}</li>`;
      }
      return `<li>${item}</li>`;
    })
    .join("");
}

function renderBlock(block) {
  switch (block.type) {
    case "p":
      return `<p>${block.html || ""}</p>`;
    case "h3":
      return `<h3>${block.html || ""}</h3>`;
    case "ul":
      return `<ul>${renderListItems(block.items)}</ul>`;
    case "tip":
      return `<p class="learning-tip">${block.html || ""}</p>`;
    case "warn":
      return `<p class="learning-warn">${block.html || ""}</p>`;
    case "links":
      return `
        <div class="learning-links">
          ${(block.items || [])
            .map(
              (link) =>
                `<a href="${escapeAttr(link.href)}">${link.label}</a>`
            )
            .join("")}
        </div>`;
    default:
      return "";
  }
}

function renderToc(sections) {
  return `
    <nav class="learning-toc" aria-label="Contents">
      <h2>Contents</h2>
      <ul>
        ${sections
          .map(
            (s) =>
              `<li><a href="#${escapeAttr(s.id)}">${s.title}</a></li>`
          )
          .join("")}
      </ul>
    </nav>`;
}

function renderSection(section) {
  return `
    <section class="learning-section" id="${escapeAttr(section.id)}">
      <h2>${section.title}</h2>
      ${(section.blocks || []).map(renderBlock).join("")}
      <a class="learning-back-top" href="#learning-toc">↑ Contents</a>
    </section>`;
}

export function renderLearningGpslGuide(rootEl) {
  const root = rootEl || document.getElementById("learningGuide");
  if (!root) return;

  root.innerHTML = `
    <h1>Learning GPSL</h1>
    <p class="learning-meta">${LEARNING_GPSL_META_HTML}</p>
    <div id="learning-toc">${renderToc(LEARNING_GPSL_SECTIONS)}</div>
    ${LEARNING_GPSL_SECTIONS.map(renderSection).join("")}
  `;
}

document.addEventListener("DOMContentLoaded", () => {
  document.body.classList.add("learning-gpsl-page");
  renderLearningGpslGuide();
  initGlobal();
});
