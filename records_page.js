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
  /** @type {Map<string, string>} short → club display name */
  const clubsByShort = new Map();
  let meta = null;

  const [{ data, error }, clubsRes] = await Promise.all([
    supabase.rpc("gpsl_records_get", { p_catalog: opts.catalog }),
    supabase.from("Clubs").select("ShortName, Club").neq("ShortName", "FOREIGN"),
  ]);

  if (error) console.warn("gpsl_records_get:", error);
  meta = data?.meta || null;
  for (const row of data?.records || []) {
    if (row?.record_id) byId.set(String(row.record_id), row);
  }
  for (const c of clubsRes.data || []) {
    clubsByShort.set(String(c.ShortName).toUpperCase(), c.Club || c.ShortName);
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

  function resolveClubShort(live) {
    const club = String(live?.holder_club || "").trim();
    const key = String(live?.holder_key || "").trim();
    if (club && clubsByShort.has(club.toUpperCase())) return club;
    if (key && clubsByShort.has(key.toUpperCase())) return key;
    return club || key || "";
  }

  function holderHtml(live) {
    if (!live?.holder_name && !live?.value_text) return "—";
    if (!live?.holder_name) return "—";

    const short = resolveClubShort(live);
    const clubName = short ? clubsByShort.get(short.toUpperCase()) || short : "";
    // Historical only — set at refresh from season ranking, never current owner
    const ownerTag = String(live.owner_tag || "").trim();

    const nameIsClub =
      short &&
      (String(live.holder_name).toUpperCase() === short.toUpperCase() ||
        String(live.holder_name).toUpperCase() === String(clubName).toUpperCase() ||
        String(live.holder_key || "").toUpperCase() === short.toUpperCase());

    const clubLine = nameIsClub
      ? escapeHtml(live.holder_name)
      : short
        ? escapeHtml(clubName)
        : "";

    const primary = nameIsClub
      ? ""
      : `<div class="rec-holder-name">${escapeHtml(live.holder_name)}</div>`;

    const clubBlock = clubLine
      ? `<div class="rec-holder-club">${clubLine}</div>`
      : "";

    const ownerBlock = ownerTag
      ? `<div class="rec-holder-owner">${escapeHtml(ownerTag)}</div>`
      : "";

    if (nameIsClub) {
      return `${clubBlock}${ownerBlock}` || escapeHtml(live.holder_name);
    }
    return `${primary}${clubBlock}${ownerBlock}`;
  }

  root.innerHTML = opts.groups
    .map((g) => {
      const rows = g.records
        .map((r) => {
          const live = byId.get(r.id);
          const holder = live ? holderHtml(live) : "—";
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
