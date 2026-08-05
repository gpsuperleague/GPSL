/**
 * Shared renderer for owner-facing rules / help panels.
 *
 * Spec:
 * {
 *   title?: string,
 *   lead?: string,                         // HTML paragraph under title
 *   cards?: { heading: string, items: string[] }[],
 *   items?: string[],                      // simple bullet list (no cards)
 *   sections?: { heading: string, lead?: string, items?: string[] }[],
 * }
 */

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
  const body = spec.cards?.length
    ? cardsHtml(spec.cards)
    : spec.sections?.length
      ? sectionsHtml(spec.sections)
      : bulletsHtml(spec.items || []);

  rootEl.innerHTML = `${title}${lead}${body}`;
}

/** Convenience: resolve by id then render. */
export function renderRulesPanelById(elementId, spec, options) {
  renderRulesPanel(document.getElementById(elementId), spec, options);
}
