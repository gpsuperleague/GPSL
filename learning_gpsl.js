/**
 * Learning GPSL  Ebound handbook renderer (content in learning_gpsl_content/).
 */
import { initGlobal, supabase } from "./global.js";
import {
  LEARNING_GPSL_META_HTML,
  LEARNING_GPSL_SECTIONS,
} from "./learning_gpsl_content.js?v=20261001-matchday-checklist2";

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

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function stripHtml(html) {
  const el = document.createElement("div");
  el.innerHTML = html || "";
  return (el.textContent || "").trim();
}

function slugify(text) {
  return stripHtml(text)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 60);
}

/** Split a chapter into topics at each h3 (blocks before the first h3 form an untitled intro). */
function splitTopics(section, usedIds) {
  const topics = [];
  let current = { id: null, title: null, blocks: [] };
  for (const block of section.blocks || []) {
    if (block.type === "h3") {
      if (current.title || current.blocks.length) topics.push(current);
      let id = `${section.id}--${slugify(block.html) || "topic"}`;
      while (usedIds.has(id)) id += "-x";
      usedIds.add(id);
      current = { id, title: block.html, blocks: [] };
    } else {
      current.blocks.push(block);
    }
  }
  if (current.title || current.blocks.length) topics.push(current);
  return topics;
}

function renderToc(sections, topicsBySection) {
  return `
    <nav class="learning-toc" aria-label="Contents">
      <h2>Contents</h2>
      <div class="learning-search">
        <input type="search" id="learningSearch" autocomplete="off"
          placeholder="Search the handbook  Ee.g. fines, video, loans, holiday"
          aria-label="Search the handbook">
        <span id="learningSearchCount" class="learning-search-count" aria-live="polite"></span>
      </div>
      <div id="learningSearchResults" class="learning-search-results" hidden></div>
      <ul class="learning-toc-chapters">
        ${sections
          .map((s) => {
            const subs = (topicsBySection.get(s.id) || []).filter((t) => t.title);
            const topicList = subs.length
              ? `<details class="learning-toc-topics">
                  <summary>${subs.length} topic${subs.length === 1 ? "" : "s"}</summary>
                  <ul>${subs
                    .map((t) => `<li><a href="#${escapeAttr(t.id)}">${t.title}</a></li>`)
                    .join("")}</ul>
                </details>`
              : "";
            return `<li data-toc-section="${escapeAttr(s.id)}"><a href="#${escapeAttr(s.id)}">${
              s.title
            }</a>${topicList}</li>`;
          })
          .join("")}
      </ul>
    </nav>`;
}

function chapterLabel(index) {
  const n = String(index + 1).padStart(2, "0");
  return `Chapter ${n}`;
}

function renderSection(section, index, topics) {
  return `
    <section class="learning-section" id="${escapeAttr(section.id)}">
      <span class="learning-chapter-label">${chapterLabel(index)}</span>
      <h2>${section.title}</h2>
      ${topics
        .map(
          (t) => `
        <div class="learning-topic"${t.id ? ` id="${escapeAttr(t.id)}"` : ""}
          data-topic-title="${escapeAttr(stripHtml(t.title || ""))}">
          ${t.title ? `<h3>${t.title}</h3>` : ""}
          ${t.blocks.map(renderBlock).join("")}
        </div>`
        )
        .join("")}
      <a class="learning-back-top" href="#learning-toc">Contents</a>
    </section>`;
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function clearHighlights(root) {
  root.querySelectorAll("mark.learning-hit").forEach((m) => {
    m.replaceWith(document.createTextNode(m.textContent));
  });
  root.querySelectorAll(".learning-section").forEach((s) => s.normalize());
}

function highlightTerms(container, terms) {
  const re = new RegExp(`(${terms.map(escapeRegExp).join("|")})`, "gi");
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      if (node.parentElement?.closest("mark, script, style, [hidden]")) {
        return NodeFilter.FILTER_REJECT;
      }
      re.lastIndex = 0;
      return re.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    },
  });
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    const frag = document.createDocumentFragment();
    node.nodeValue.split(re).forEach((part, i) => {
      if (!part) return;
      if (i % 2 === 1) {
        const mark = document.createElement("mark");
        mark.className = "learning-hit";
        mark.textContent = part;
        frag.appendChild(mark);
      } else {
        frag.appendChild(document.createTextNode(part));
      }
    });
    node.replaceWith(frag);
  }
}

function snippetHtml(text, terms) {
  const clean = text.replace(/\s+/g, " ").trim();
  const lower = clean.toLowerCase();
  let at = -1;
  for (const w of terms) {
    const i = lower.indexOf(w);
    if (i >= 0 && (at < 0 || i < at)) at = i;
  }
  const start = Math.max(0, at - 50);
  const end = Math.min(clean.length, (at < 0 ? 0 : at) + 110);
  let snip = escapeHtml(clean.slice(start, end));
  const re = new RegExp(`(${terms.map((w) => escapeRegExp(escapeHtml(w))).join("|")})`, "gi");
  snip = snip.replace(re, "<mark>$1</mark>");
  return `${start > 0 ? "…" : ""}${snip}${end < clean.length ? "…" : ""}`;
}

function wireSearch(root) {
  const input = root.querySelector("#learningSearch");
  const countEl = root.querySelector("#learningSearchCount");
  const resultsEl = root.querySelector("#learningSearchResults");
  if (!input || !resultsEl) return;
  const sections = [...root.querySelectorAll(".learning-section")];

  const run = (raw) => {
    const query = String(raw || "").trim();
    clearHighlights(root);
    const terms = query
      .toLowerCase()
      .split(/\s+/)
      .filter((w) => w.length >= 2);

    const url = new URL(window.location.href);
    if (query) url.searchParams.set("q", query);
    else url.searchParams.delete("q");
    window.history.replaceState(null, "", url);

    if (!terms.length) {
      sections.forEach((s) => {
        s.hidden = false;
        s.querySelectorAll(".learning-topic").forEach((t) => (t.hidden = false));
      });
      root.querySelectorAll("[data-toc-section]").forEach((li) => (li.hidden = false));
      resultsEl.hidden = true;
      resultsEl.innerHTML = "";
      if (countEl) countEl.textContent = "";
      return;
    }

    const hits = [];
    const pages = new Map();
    let chapterCount = 0;

    for (const sec of sections) {
      const chapterTitle = sec.querySelector("h2")?.textContent.trim() || "";
      const chapterLower = chapterTitle.toLowerCase();
      let any = false;
      for (const topic of sec.querySelectorAll(".learning-topic")) {
        const text = topic.textContent.toLowerCase();
        const match = terms.every((w) => text.includes(w) || chapterLower.includes(w));
        topic.hidden = !match;
        if (!match) continue;
        any = true;
        hits.push({ sec, topic, chapterTitle });
        topic.querySelectorAll("a[href]").forEach((a) => {
          const href = a.getAttribute("href") || "";
          if (href && !href.startsWith("#") && !pages.has(href)) {
            pages.set(href, a.textContent.trim() || href);
          }
        });
      }
      sec.hidden = !any;
      if (any) chapterCount += 1;
      const li = root.querySelector(`[data-toc-section="${CSS.escape(sec.id)}"]`);
      if (li) li.hidden = !any;
      if (any) highlightTerms(sec, terms);
    }

    if (countEl) {
      countEl.textContent = hits.length
        ? `${hits.length} topic${hits.length === 1 ? "" : "s"} in ${chapterCount} chapter${
            chapterCount === 1 ? "" : "s"
          }`
        : "No matches";
    }

    if (!hits.length) {
      resultsEl.innerHTML = `<p class="learning-search-empty">Nothing found for  E{escapeHtml(
        query
      )} E Try a shorter word, e.g. “fine Einstead of “fined E</p>`;
      resultsEl.hidden = false;
      return;
    }

    const topicLinks = hits
      .slice(0, 12)
      .map(({ sec, topic, chapterTitle }) => {
        const topicTitle = topic.dataset.topicTitle || "";
        const body = topic.textContent.slice(topicTitle.length);
        return `<li>
          <a href="#${escapeAttr(topic.id || sec.id)}">${escapeHtml(chapterTitle)}${
            topicTitle ? ` › <b>${escapeHtml(topicTitle)}</b>` : ""
          }</a>
          <span class="learning-search-snippet">${snippetHtml(body, terms)}</span>
        </li>`;
      })
      .join("");

    const rankedPages = [...pages.entries()]
      .map(([href, label]) => ({
        href,
        label,
        score: terms.some((w) => label.toLowerCase().includes(w)) ? 0 : 1,
      }))
      .sort((a, b) => a.score - b.score)
      .slice(0, 8);

    const pageChips = rankedPages.length
      ? `<div class="learning-search-pages"><span>Related pages:</span>${rankedPages
          .map((p) => `<a href="${escapeAttr(p.href)}">${escapeHtml(p.label)}</a>`)
          .join("")}</div>`
      : "";

    resultsEl.innerHTML = `<ul class="learning-search-list">${topicLinks}</ul>${
      hits.length > 12 ? `<p class="learning-search-more">+${hits.length - 12} more below</p>` : ""
    }${pageChips}`;
    resultsEl.hidden = false;
  };

  let timer = null;
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(() => run(input.value), 120);
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      input.value = "";
      run("");
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "/" || e.target.closest?.("input, textarea, select, [contenteditable]")) return;
    e.preventDefault();
    input.focus();
  });

  const toc = root.querySelector(".learning-toc");
  toc?.addEventListener("click", (e) => {
    const link = e.target.closest?.('a[href^="#"]');
    if (!link) return;
    const target = document.getElementById(decodeURIComponent(link.getAttribute("href").slice(1)));
    if (!target) return;
    e.preventDefault();
    const stuck = getComputedStyle(toc).position === "sticky";
    const offset = stuck ? toc.getBoundingClientRect().height + 16 : 12;
    window.scrollTo({
      top: target.getBoundingClientRect().top + window.scrollY - offset,
      behavior: "smooth",
    });
    window.history.replaceState(null, "", `${window.location.search}#${target.id}`);
  });

  const initial = new URLSearchParams(window.location.search).get("q");
  if (initial) {
    input.value = initial;
    run(initial);
  }
}

function wireTocSticky(root) {
  const toc = root.querySelector(".learning-toc");
  if (!toc || typeof IntersectionObserver !== "function") return;

  const sentinel = document.createElement("div");
  sentinel.className = "learning-toc-sentinel";
  sentinel.setAttribute("aria-hidden", "true");
  sentinel.style.cssText = "height:1px;margin:0;padding:0;pointer-events:none;";
  toc.parentNode.insertBefore(sentinel, toc);

  const observer = new IntersectionObserver(
    ([entry]) => {
      toc.classList.toggle("is-stuck", Boolean(entry && !entry.isIntersecting));
    },
    { threshold: [0], rootMargin: "-8px 0px 0px 0px" }
  );
  observer.observe(sentinel);
}

export function renderLearningGpslGuide(rootEl) {
  const root = rootEl || document.getElementById("learningGuide");
  if (!root) return;

  const usedIds = new Set(LEARNING_GPSL_SECTIONS.map((s) => s.id));
  const topicsBySection = new Map(
    LEARNING_GPSL_SECTIONS.map((s) => [s.id, splitTopics(s, usedIds)])
  );

  root.innerHTML = `
    <div class="learning-book">
      <header class="learning-cover">
        <p class="learning-cover-brand">GPSL</p>
        <h1 class="learning-cover-title">Owner&rsquo;s Handbook</h1>
        <span class="learning-cover-rule" aria-hidden="true"></span>
        <p class="learning-cover-dek">${LEARNING_GPSL_META_HTML}</p>
      </header>
      <div id="learning-toc">${renderToc(LEARNING_GPSL_SECTIONS, topicsBySection)}</div>
      ${LEARNING_GPSL_SECTIONS.map((s, i) =>
        renderSection(s, i, topicsBySection.get(s.id) || [])
      ).join("")}
    </div>
  `;

  wireTocSticky(root);
  wireSearch(root);
}

function formatSettingValue(value, fmt) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  if (fmt === "money") return `₿${Math.round(n).toLocaleString("en-GB")}`;
  return String(Math.round(n));
}

/** Fill <span data-gs="column"> placeholders from live league settings (defaults stay on failure). */
async function fillLiveSettings(root) {
  const spans = [...(root || document).querySelectorAll("[data-gs]")];
  if (!spans.length) return;
  const columns = [...new Set(spans.map((el) => el.dataset.gs))];
  const { data, error } = await supabase
    .from("global_settings_public")
    .select(columns.join(","))
    .limit(1)
    .maybeSingle();
  if (error || !data) return;
  for (const el of spans) {
    const text = formatSettingValue(data[el.dataset.gs], el.dataset.gsFmt);
    if (text != null) el.textContent = text;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.body.classList.add("learning-gpsl-page");
  renderLearningGpslGuide();
  initGlobal();
  fillLiveSettings(document.getElementById("learningGuide")).catch(() => {});
});
