import { initGlobal, supabase } from "./global.js";
import { escapeHtml } from "./escape_html.js";

/**
 * @param {{
 *   title: string,
 *   intro: string,
 *   catalog: 'league'|'cup'|'fun',
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
  const metaEl = document.getElementById("recordsMeta");

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
  root.innerHTML = `<p class="rec-loading">Loading records…</p>`;

  /** @type {Map<string, object>} */
  const byId = new Map();
  let meta = null;
  try {
    const { data, error } = await supabase.rpc("gpsl_records_get", {
      p_catalog: opts.catalog,
    });
    if (error) throw error;
    meta = data?.meta || null;
    for (const row of data?.records || []) {
      if (row?.record_id) byId.set(String(row.record_id), row);
    }
  } catch (err) {
    console.warn("gpsl_records_get:", err);
  }

  if (metaEl) {
    const when = meta?.last_refresh_at
      ? new Date(meta.last_refresh_at).toLocaleString("en-GB", {
          dateStyle: "medium",
          timeStyle: "short",
        })
      : null;
    metaEl.textContent = when
      ? `Last refreshed ${when}${meta?.last_refresh_ok === false ? " (with errors)" : ""} · updates weekly`
      : "Holders fill in after the weekly refresh (run the SQL patch once).";
  }

  root.innerHTML = opts.groups
    .map((g) => {
      const rows = g.records
        .map((r) => {
          const live = byId.get(r.id);
          const holder = live?.holder_name
            ? escapeHtml(live.holder_name) +
              (live.holder_club && live.holder_club !== live.holder_key
                ? ` <span class="rec-club">(${escapeHtml(
                    live.holder_club
                  )})</span>`
                : "")
            : "—";
          const mark = live?.value_text
            ? escapeHtml(live.value_text)
            : live
              ? "—"
              : "Not yet recorded";
          const when = live?.context_label
            ? escapeHtml(live.context_label)
            : "—";
          const filled = live?.holder_name || live?.value_text ? " is-filled" : "";
          return `
        <tr id="rec-${escapeHtml(r.id)}" class="${filled}">
          <td class="rec-label">${escapeHtml(r.label)}</td>
          <td class="rec-holder">${holder}</td>
          <td class="rec-value">${mark}</td>
          <td class="rec-when">${when}</td>
        </tr>`;
        })
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
