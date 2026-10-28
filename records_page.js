import { initGlobal } from "./global.js";
import { escapeHtml } from "./escape_html.js";

/**
 * @param {{
 *   title: string,
 *   intro: string,
 *   groups: import("./records_catalog.js").RecordGroup[],
 *   siblingLinks?: { href: string, label: string }[],
 * }} opts
 */
export async function mountRecordsPage(opts) {
  await initGlobal();

  const titleEl = document.getElementById("recordsTitle");
  const introEl = document.getElementById("recordsIntro");
  const tocEl = document.getElementById("recordsToc");
  const root = document.getElementById("recordsRoot");
  const sibEl = document.getElementById("recordsSiblings");

  if (titleEl) titleEl.textContent = opts.title;
  if (introEl) introEl.textContent = opts.intro;

  if (sibEl && opts.siblingLinks?.length) {
    sibEl.innerHTML = opts.siblingLinks
      .map(
        (l) =>
          `<a class="rec-sib" href="${escapeHtml(l.href)}">${escapeHtml(l.label)}</a>`
      )
      .join('<span class="rec-sib-sep">·</span>');
  }

  if (tocEl) {
    tocEl.innerHTML = opts.groups
      .map(
        (g) =>
          `<a href="#${escapeHtml(g.id)}">${escapeHtml(g.title)} <span>(${g.records.length})</span></a>`
      )
      .join("");
  }

  if (!root) return;

  root.innerHTML = opts.groups
    .map((g) => {
      const rows = g.records
        .map(
          (r) => `
        <tr id="rec-${escapeHtml(r.id)}">
          <td class="rec-label">${escapeHtml(r.label)}</td>
          <td class="rec-holder">—</td>
          <td class="rec-value">Not yet recorded</td>
          <td class="rec-when">—</td>
        </tr>`
        )
        .join("");
      return `
      <section class="rec-section" id="${escapeHtml(g.id)}">
        <h2>${escapeHtml(g.title)}</h2>
        <div class="rec-panel">
          <table class="rec-table">
            <thead>
              <tr>
                <th>Record</th>
                <th>Holder</th>
                <th>Mark</th>
                <th>When</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </section>`;
    })
    .join("");
}
