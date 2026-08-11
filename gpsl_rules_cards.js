/**
 * Shared renderer for owner-facing rules / help panels.
 *
 * Spec:
 * {
 *   title?: string,
 *   lead?: string,                         // HTML paragraph under title
 *   notice?: {                             // highlighted callout
 *     title?: string,
 *     body: string,                        // HTML
 *     cta?: { href: string, label: string, className?: string },
 *   },
 *   steps?: { heading: string, body?: string, items?: string[] }[],
 *   cards?: { heading: string, items: string[] }[],
 *   items?: string[],                      // simple bullet list (no cards)
 *   sections?: { heading: string, lead?: string, items?: string[] }[],
 * }
 */

function noticeHtml(notice) {
  if (!notice?.body) return "";
  const title = notice.title
    ? `<strong class="rules-notice-title">${notice.title}</strong>`
    : "";
  const cta = notice.cta?.href
    ? `<p class="rules-notice-cta">
         <a href="${notice.cta.href}" class="${
           notice.cta.className || "button rules-notice-btn"
         }">${notice.cta.label || "Open"}</a>
       </p>`
    : "";
  return `
    <div class="rules-notice" role="note">
      ${title}
      <div class="rules-notice-body">${notice.body}</div>
      ${cta}
    </div>`;
}

function stepsHtml(steps) {
  if (!steps?.length) return "";
  return `
    <ol class="rules-steps">
      ${steps
        .map(
          (step, i) => `
        <li class="rules-step">
          <span class="rules-step-num" aria-hidden="true">${step.n ?? i + 1}</span>
          <div class="rules-step-body">
            <h3>${step.heading}</h3>
            ${step.body ? `<p>${step.body}</p>` : ""}
            ${
              step.items?.length
                ? `<ul>${step.items
                    .map((item) => `<li>${item}</li>`)
                    .join("")}</ul>`
                : ""
            }
          </div>
        </li>`
        )
        .join("")}
    </ol>`;
}

function cardsHtml(cards) {
  if (!cards?.length) return "";
  return `
    <div class="rules-grid">
      ${cards
        .map(
          (card) => `
        <section class="rules-card">
          <h3>${card.heading}</h3>
          <ul>
            ${(card.items || []).map((item) => `<li>${item}</li>`).join("")}
          </ul>
        </section>`
        )
        .join("")}
    </div>`;
}

function bulletsHtml(items) {
  if (!items?.length) return "";
  return `
    <ul class="rules-bullets">
      ${items.map((item) => `<li>${item}</li>`).join("")}
    </ul>`;
}

function sectionsHtml(sections) {
  if (!sections?.length) return "";
  return sections
    .map((sec) => {
      const lead = sec.lead ? `<p class="rules-lead">${sec.lead}</p>` : "";
      const list = sec.items?.length
        ? `<ul class="rules-bullets">${sec.items
            .map((item) => `<li>${item}</li>`)
            .join("")}</ul>`
        : "";
      return `
        <h2 class="rules-title">${sec.heading}</h2>
        ${lead}
        ${list}`;
    })
    .join("");
}

/**
 * @param {HTMLElement|null|undefined} rootEl
 * @param {{
 *   title?: string,
 *   lead?: string,
 *   notice?: { title?: string, body: string, cta?: { href: string, label: string, className?: string } },
 *   steps?: { heading: string, body?: string, items?: string[], n?: number }[],
 *   cards?: { heading: string, items: string[] }[],
 *   items?: string[],
 *   sections?: { heading: string, lead?: string, items?: string[] }[],
 * }} spec
 * @param {{ rootClass?: string }} [options]
 */
export function renderRulesPanel(rootEl, spec, options = {}) {
  if (!rootEl || !spec) return;

  if (options.rootClass) {
    rootEl.className = options.rootClass;
  }

  const title = spec.title
    ? `<h2 class="rules-title">${spec.title}</h2>`
    : "";
  const lead = spec.lead ? `<p class="rules-lead">${spec.lead}</p>` : "";
  const notice = noticeHtml(spec.notice);
  const steps = stepsHtml(spec.steps);
  const cards = cardsHtml(spec.cards);
  const sections = !cards && spec.sections?.length ? sectionsHtml(spec.sections) : "";
  const bullets =
    !cards && !sections && spec.items?.length ? bulletsHtml(spec.items) : "";

  rootEl.innerHTML = `${title}${lead}${notice}${steps}${cards}${sections}${bullets}`;
}

/** Convenience: resolve by id then render. */
export function renderRulesPanelById(elementId, spec, options) {
  renderRulesPanel(document.getElementById(elementId), spec, options);
}
