import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import { loadFinanceSeasonContext } from "./finance_page_common.js";
import { MIN_HOME_GROWN, MIN_SQUAD_SIZE, MIN_UNDER_21, SQUAD_SIZE } from "./squad_rules.js";

primeAdminPageChrome();

const MIN_U21 = MIN_UNDER_21;
/** Super League star registration cap (matches club_squad_star_cap). */
const STAR_CAP_SUPERLEAGUE = 3;
/** Championship / unassigned star registration cap. */
const STAR_CAP_CHAMPIONSHIP = 2;

/** @type {Array<Record<string, unknown>>} */
let allRows = [];
let sortKey = "club_name";
let sortDir = "asc";

/** @param {unknown} division */
function starCapForDivision(division) {
  const d = String(division || "").toLowerCase();
  if (d === "superleague" || d.includes("super")) return STAR_CAP_SUPERLEAGUE;
  return STAR_CAP_CHAMPIONSHIP;
}

/** Prefer RPC star_cap; fall back to division (SL 3 / Champ 2). */
function rowStarCap(row) {
  const fromRpc = Number(row?.star_cap);
  if (Number.isFinite(fromRpc) && fromRpc > 0) return fromRpc;
  return starCapForDivision(row?.division);
}

function rowStarCount(row) {
  const n = Number(row?.star_count ?? 0);
  return Number.isFinite(n) ? n : 0;
}

const ISSUE_META = {
  owner: { label: "Owner", level: "bad", tip: "No owner assigned" },
  manager: {
    label: "No manager",
    level: "bad",
    tip: "Owned club has no signed manager — hire from Manager Market / FA window",
  },
  nation: { label: "Nation", level: "bad", tip: "Owned club has no nation" },
  squad_low: {
    label: `Squad <${MIN_SQUAD_SIZE}`,
    level: "bad",
    tip: `Squad below minimum (${MIN_SQUAD_SIZE})`,
  },
  squad_high: {
    label: `Squad >${SQUAD_SIZE}`,
    level: "bad",
    tip: `Squad above maximum (${SQUAD_SIZE})`,
  },
  stars: {
    label: "Stars",
    level: "bad",
    tip: "Star players over registration limit (SL 3 / Champ 2; One of Our Own excluded)",
  },
  u21: { label: `U21 <${MIN_U21}`, level: "bad", tip: `Fewer than ${MIN_U21} U21 players` },
  hg: {
    label: `HG <${MIN_HOME_GROWN}`,
    level: "bad",
    tip: `Fewer than ${MIN_HOME_GROWN} home-grown players (nation must match club)`,
  },
  balance: { label: "Balance", level: "bad", tip: "Current balance is negative" },
  proj: { label: "Proj EOS", level: "warn", tip: "Projected end-of-season balance is negative" },
  fines: { label: "Fines", level: "warn", tip: "Outstanding fines on record" },
};

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("reloadBtn")?.addEventListener("click", () => loadTable());
  document.getElementById("notifyIssuesBtn")?.addEventListener("click", () => notifyOwnersOfIssues());
  document.getElementById("filterOwner")?.addEventListener("change", renderTable);
  document.getElementById("filterOwnerName")?.addEventListener("input", renderTable);
  document.getElementById("filterDivision")?.addEventListener("change", renderTable);
  document.getElementById("filterIssuesOnly")?.addEventListener("change", renderTable);

  await loadTable();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function rowHasOwner(row) {
  return Boolean(row.owner_tag || row.owner_email);
}

/** Signed manager present (RPC resolves via Managers.contracted_club). */
function rowHasManager(row) {
  return Boolean(String(row?.manager_name || "").trim());
}

/** @returns {Set<string>} */
function evaluateRowIssues(row) {
  const issues = new Set();
  const hasOwner = rowHasOwner(row);
  const squad = Number(row.squad_size ?? 0);
  const stars = rowStarCount(row);
  const starCap = rowStarCap(row);
  const u21 = Number(row.u21_count ?? 0);
  const hg = Number(row.hg_count ?? 0);

  if (!hasOwner) issues.add("owner");
  if (hasOwner && !rowHasManager(row)) issues.add("manager");
  if (hasOwner && !(row.nation_code || row.nation_name)) issues.add("nation");
  if (squad < MIN_SQUAD_SIZE) issues.add("squad_low");
  if (squad > SQUAD_SIZE) issues.add("squad_high");
  if (stars > starCap) issues.add("stars");
  if (hasOwner && u21 < MIN_U21) issues.add("u21");
  if (hasOwner && hg < MIN_HOME_GROWN) issues.add("hg");
  if (Number(row.current_balance) < 0) issues.add("balance");
  if (
    row.projected_eos_balance != null &&
    row.projected_eos_balance !== "" &&
    Number(row.projected_eos_balance) < 0
  ) {
    issues.add("proj");
  }
  if (Number(row.fines_count) > 0) issues.add("fines");

  return issues;
}

/** @param {Set<string>} issues @param {Record<string, unknown>} [row] */
function issueTagsHtml(issues, row = null) {
  if (!issues.size) return '<span class="muted">—</span>';
  return [...issues]
    .map((key) => {
      const meta = ISSUE_META[key] || { label: key, level: "bad" };
      let label = meta.label;
      if (key === "stars" && row) {
        label = `Stars ${rowStarCount(row)}/${rowStarCap(row)}`;
      }
      const cls = meta.level === "warn" ? "chk-issue-tag warn" : "chk-issue-tag";
      return `<span class="${cls}" title="${escapeHtml(meta.tip || meta.label)}">${escapeHtml(
        label
      )}</span>`;
    })
    .join("");
}

/** @param {Record<string, unknown>} row @param {Set<string>} issues */
function buildChecklistIssueBody(row, issues) {
  const club = row.club_name || row.club_short_name || "your club";
  const lines = [...issues].map((key) => {
    const meta = ISSUE_META[key] || { label: key, tip: key };
    return `• ${meta.label} — ${meta.tip}`;
  });

  const extras = [];
  if (issues.has("hg")) {
    extras.push(`Home-grown count: ${Number(row.hg_count ?? 0)} (minimum ${MIN_HOME_GROWN})`);
  }
  if (issues.has("u21")) {
    extras.push(`U21 count: ${Number(row.u21_count ?? 0)} (minimum ${MIN_U21})`);
  }
  if (issues.has("squad_low") || issues.has("squad_high")) {
    extras.push(`Squad size: ${Number(row.squad_size ?? 0)} (range ${MIN_SQUAD_SIZE}–${SQUAD_SIZE})`);
  }
  if (issues.has("stars")) {
    const cap = rowStarCap(row);
    extras.push(
      `Star players: ${rowStarCount(row)} / ${cap} (over registration limit; One of Our Own excluded)`
    );
  }
  if (issues.has("manager")) {
    extras.push(
      "No signed manager on contract — use Manager Market / FA window listings to hire one."
    );
  }
  if (issues.has("balance")) {
    extras.push(`Current balance: ${formatMoney(row.current_balance)}`);
  }
  if (issues.has("proj") && row.projected_eos_balance != null) {
    extras.push(`Projected EOS balance: ${formatMoney(row.projected_eos_balance)}`);
  }

  return [
    `Club checklist for ${club}`,
    "",
    "The league admin has flagged the following deficiencies on your club:",
    "",
    ...lines,
    ...(extras.length ? ["", ...extras] : []),
    "",
    "Please review Squad / Finances and resolve these as soon as possible.",
  ].join("\n");
}

async function notifyOwnersOfIssues() {
  if (!allRows.length) {
    setStatus("pageStatus", "Load the checklist first.", false);
    return;
  }

  const useFiltered = document.getElementById("notifyFilteredOnly")?.checked;
  const source = useFiltered ? filteredRows() : allRows;

  const targets = source
    .map((row) => {
      const issues = evaluateRowIssues(row);
      return { row, issues };
    })
    .filter(({ row, issues }) => rowHasOwner(row) && issues.size > 0);

  if (!targets.length) {
    setStatus(
      "pageStatus",
      useFiltered
        ? "No owned clubs with issues in the current filter."
        : "No owned clubs currently have checklist issues.",
      false
    );
    return;
  }

  const sample = targets
    .slice(0, 8)
    .map(({ row }) => row.club_name || row.club_short_name)
    .join(", ");
  const more = targets.length > 8 ? "…" : "";

  if (
    !window.confirm(
      `Send inbox notifications to ${targets.length} owner(s) with checklist issues?\n\n` +
        `${sample}${more}\n\n` +
        (useFiltered ? "(Using current filters.)\n\n" : "") +
        "Each owner gets a list of their deficiencies."
    )
  ) {
    return;
  }

  const items = targets.map(({ row, issues }) => ({
    club_short_name: row.club_short_name,
    title: "Club checklist — issues to fix",
    body: buildChecklistIssueBody(row, issues),
  }));

  setStatus("pageStatus", `Notifying ${items.length} owner(s)…`);
  const { data, error } = await supabase.rpc("admin_notify_club_checklist_issues", {
    p_items: items,
  });

  if (error) {
    setStatus(
      "pageStatus",
      "❌ " + error.message + " — run patches/admin_club_checklist_notify_issues.sql",
      false
    );
    return;
  }

  setStatus(
    "pageStatus",
    `✅ Notified ${data?.sent ?? 0} owner(s)` +
      (data?.skipped ? ` (${data.skipped} skipped)` : "") +
      ".",
    true
  );
}

function compareValues(a, b, key) {
  if (key === "_issues") {
    return evaluateRowIssues(a).size - evaluateRowIssues(b).size;
  }

  const va = a?.[key];
  const vb = b?.[key];

  if (key === "current_balance" || key === "projected_eos_balance" || key === "total_wages") {
    const na = Number(va);
    const nb = Number(vb);
    if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb;
  }

  if (
    key === "squad_size" ||
    key === "star_count" ||
    key === "contract_releases_remaining" ||
    key === "foreign_sales_remaining" ||
    key === "fines_count" ||
    key === "u21_count" ||
    key === "hg_count" ||
    key === "manager_rating"
  ) {
    const na = Number(va);
    const nb = Number(vb);
    if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb;
  }

  return String(va ?? "").localeCompare(String(vb ?? ""), undefined, { sensitivity: "base" });
}

function filteredRows() {
  const ownerFilter = document.getElementById("filterOwner")?.value || "";
  const ownerNameQ = String(document.getElementById("filterOwnerName")?.value || "")
    .trim()
    .toLowerCase();
  const divisionFilter = document.getElementById("filterDivision")?.value || "";
  const issuesOnly = document.getElementById("filterIssuesOnly")?.checked;

  return allRows.filter((row) => {
    const hasOwner = rowHasOwner(row);
    if (ownerFilter === "owned" && !hasOwner) return false;
    if (ownerFilter === "vacant" && hasOwner) return false;

    if (ownerNameQ) {
      const hay = [row.owner_tag, row.owner_email]
        .map((x) => String(x || "").toLowerCase())
        .join(" ");
      if (!hay.includes(ownerNameQ)) return false;
    }

    const div = row.division || "unassigned";
    if (divisionFilter && div !== divisionFilter) return false;

    if (issuesOnly && evaluateRowIssues(row).size === 0) return false;

    return true;
  });
}

function sortedRows(rows) {
  const sorted = [...rows];
  sorted.sort((a, b) => {
    const cmp = compareValues(a, b, sortKey);
    return sortDir === "asc" ? cmp : -cmp;
  });
  return sorted;
}

function renderSummary(rows) {
  const el = document.getElementById("summaryStrip");
  if (!el) return;

  let owned = 0;
  let vacant = 0;
  let underMin = 0;
  let starsOver = 0;
  let noManager = 0;
  let hgShort = 0;
  let negative = 0;
  let flagged = 0;

  for (const row of allRows) {
    if (rowHasOwner(row)) owned += 1;
    else vacant += 1;
    if (Number(row.squad_size) < MIN_SQUAD_SIZE) underMin += 1;
    if (rowStarCount(row) > rowStarCap(row)) starsOver += 1;
    if (rowHasOwner(row) && !rowHasManager(row)) noManager += 1;
    if (rowHasOwner(row) && Number(row.hg_count ?? 0) < MIN_HOME_GROWN) hgShort += 1;
    if (Number(row.current_balance) < 0) negative += 1;
    if (evaluateRowIssues(row).size > 0) flagged += 1;
  }

  el.innerHTML = `
    <span><b>${rows.length}</b> clubs shown</span>
    <span>${owned} owned · ${vacant} vacant</span>
    <span>${flagged} with issues</span>
    <span>${noManager} without manager</span>
    <span>${underMin} below ${MIN_SQUAD_SIZE} squad</span>
    <span>${starsOver} over star cap</span>
    <span>${hgShort} below ${MIN_HOME_GROWN} HG</span>
    <span>${negative} negative balance</span>
  `;
}

function cellClass(level) {
  if (level === "bad") return "chk-cell-bad";
  if (level === "warn") return "chk-cell-warn";
  return "chk-cell-ok";
}

function moneyCell(value, level = "ok", title = "") {
  const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
  if (value === undefined) {
    return `<td class="money chk-cell-ok proj-loading"${titleAttr}>…</td>`;
  }
  if (value == null || value === "" || Number.isNaN(Number(value))) {
    return `<td class="money ${cellClass("bad")}"${titleAttr || ' title="Missing value"'}>—</td>`;
  }
  return `<td class="money ${cellClass(level)}"${titleAttr}>${formatMoney(Number(value))}</td>`;
}

function numCell(value, level = "ok", title = "") {
  const n = Number(value ?? 0);
  const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
  return `<td class="num ${cellClass(level)}"${titleAttr}>${n}</td>`;
}

/** Stars column: always show count/cap so over-limit is obvious in the value cell. */
function starsCell(row, level, title) {
  const stars = rowStarCount(row);
  const cap = rowStarCap(row);
  const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
  return `<td class="num ${cellClass(level)}"${titleAttr}><strong>${stars}</strong>/${cap}</td>`;
}

function textCell(content, level = "ok", title = "") {
  const titleAttr = title ? ` title="${escapeHtml(title)}"` : "";
  return `<td class="${cellClass(level)}"${titleAttr}>${content}</td>`;
}

function renderTable() {
  const wrap = document.getElementById("tableWrap");
  const countEl = document.getElementById("rowCount");
  if (!wrap) return;

  const rows = sortedRows(filteredRows());
  renderSummary(rows);

  if (countEl) {
    countEl.textContent =
      rows.length === allRows.length
        ? `Showing all ${rows.length}`
        : `Showing ${rows.length} of ${allRows.length}`;
  }

  if (!rows.length) {
    wrap.innerHTML = '<p class="note">No clubs match this filter.</p>';
    return;
  }

  const headers = [
    ["owner_tag", "Owner"],
    ["club_name", "Club"],
    ["_issues", "Issues"],
    ["manager_name", "Manager"],
    ["nation_name", "Nation"],
    ["ooo_player_name", "OooO"],
    ["squad_size", "Squad"],
    ["star_count", "Stars"],
    ["current_balance", "Balance"],
    ["projected_eos_balance", "Proj. EOS"],
    ["total_wages", "Wages"],
    ["contract_releases_remaining", "Releases"],
    ["foreign_sales_remaining", "Foreign"],
    ["fines_count", "Fines"],
    ["hg_count", "HG"],
    ["u21_count", "U21"],
  ];

  wrap.innerHTML = `
    <table class="chk-table">
      <thead>
        <tr>
          ${headers
            .map(([key, label]) => {
              const sorted =
                sortKey === key ? ` sorted-${sortDir === "asc" ? "asc" : "desc"}` : "";
              return `<th data-sort="${key}" class="${sorted.trim()}">${label}</th>`;
            })
            .join("")}
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const issues = evaluateRowIssues(row);
            const hasOwner = rowHasOwner(row);
            const squad = Number(row.squad_size ?? 0);
            const stars = rowStarCount(row);
            const starCap = rowStarCap(row);
            const u21 = Number(row.u21_count ?? 0);
            const hg = Number(row.hg_count ?? 0);
            const rowFlagged = issues.size > 0 ? " chk-row-flagged" : "";

            const owner = row.owner_tag || row.owner_email;
            const ownerHtml = owner
              ? escapeHtml(owner)
              : '<span class="vacant">Vacant</span>';

            const manager = rowHasManager(row)
              ? `${escapeHtml(row.manager_name)}${
                  row.manager_rating != null ? ` (${row.manager_rating})` : ""
                }`
              : issues.has("manager")
                ? "<strong>None</strong>"
                : "—";

            const nation = row.nation_name || row.nation_code
              ? escapeHtml(row.nation_name || row.nation_code)
              : "—";

            const ooo = row.ooo_player_name ? escapeHtml(row.ooo_player_name) : "—";

            let squadLevel = "ok";
            let squadTip = "";
            if (squad < MIN_SQUAD_SIZE) {
              squadLevel = "bad";
              squadTip = ISSUE_META.squad_low.tip;
            } else if (squad > SQUAD_SIZE) {
              squadLevel = "bad";
              squadTip = ISSUE_META.squad_high.tip;
            }

            const starsOver = stars > starCap;
            const starLevel = starsOver ? "bad" : "ok";
            const starTip = starsOver
              ? `Over star limit: ${stars} / ${starCap}`
              : `${stars} / ${starCap} (cap for this division)`;

            let u21Level = "ok";
            let u21Tip = "";
            if (hasOwner && u21 < MIN_U21) {
              u21Level = "bad";
              u21Tip = ISSUE_META.u21.tip;
            }

            let hgLevel = "ok";
            let hgTip = "";
            if (hasOwner && hg < MIN_HOME_GROWN) {
              hgLevel = "bad";
              hgTip = ISSUE_META.hg.tip;
            }

            let balanceLevel = "ok";
            let balanceTip = "";
            if (Number(row.current_balance) < 0) {
              balanceLevel = "bad";
              balanceTip = ISSUE_META.balance.tip;
            }

            let projLevel = "ok";
            let projTip = "";
            if (
              row.projected_eos_balance != null &&
              row.projected_eos_balance !== "" &&
              Number(row.projected_eos_balance) < 0
            ) {
              projLevel = "warn";
              projTip = ISSUE_META.proj.tip;
            }

            const finesLevel = Number(row.fines_count) > 0 ? "warn" : "ok";
            const finesTip = finesLevel === "warn" ? ISSUE_META.fines.tip : "";

            return `
          <tr class="${rowFlagged.trim()}" data-club="${escapeHtml(row.club_short_name)}">
            ${textCell(
              ownerHtml,
              issues.has("owner") ? "bad" : "ok",
              issues.has("owner") ? ISSUE_META.owner.tip : ""
            )}
            <td class="club-cell ${cellClass("ok")}">
              <div class="club-name">${escapeHtml(row.club_name || row.club_short_name)}</div>
              <div class="club-short">${escapeHtml(row.club_short_name)}${
                row.division ? ` · ${escapeHtml(row.division)}` : ""
              }</div>
            </td>
            <td class="chk-issues-cell ${issues.size ? cellClass("bad") : cellClass("ok")}">${issueTagsHtml(
              issues,
              row
            )}</td>
            ${textCell(
              manager,
              issues.has("manager") ? "bad" : "ok",
              issues.has("manager") ? ISSUE_META.manager.tip : ""
            )}
            ${textCell(
              nation,
              issues.has("nation") ? "bad" : "ok",
              issues.has("nation") ? ISSUE_META.nation.tip : ""
            )}
            ${textCell(
              ooo,
              "ok",
              row.ooo_player_name ? "" : "One of Our Own not set (optional)"
            )}
            ${numCell(row.squad_size, squadLevel, squadTip)}
            ${starsCell(row, starLevel, starTip)}
            ${moneyCell(row.current_balance, balanceLevel, balanceTip)}
            ${moneyCell(row.projected_eos_balance, projLevel, projTip)}
            ${moneyCell(row.total_wages)}
            ${numCell(row.contract_releases_remaining)}
            ${numCell(row.foreign_sales_remaining)}
            ${numCell(row.fines_count, finesLevel, finesTip)}
            ${numCell(row.hg_count, hgLevel, hgTip)}
            ${numCell(row.u21_count, u21Level, u21Tip)}
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  wrap.querySelectorAll("th[data-sort]").forEach((th) => {
    th.onclick = () => {
      const key = th.getAttribute("data-sort");
      if (!key) return;
      if (sortKey === key) {
        sortDir = sortDir === "asc" ? "desc" : "asc";
      } else {
        sortKey = key;
        sortDir = "asc";
      }
      renderTable();
    };
  });
}

async function enrichProjectedBalances(rows) {
  const concurrency = 6;
  let index = 0;
  let renderTimer = null;

  function scheduleRender() {
    if (renderTimer) return;
    renderTimer = setTimeout(() => {
      renderTimer = null;
      renderTable();
    }, 250);
  }

  async function worker() {
    while (index < rows.length) {
      const i = index++;
      const row = rows[i];
      const club = row.club_short_name;
      if (!club) continue;

      try {
        const ctx = await loadFinanceSeasonContext(supabase, club);
        row.projected_eos_balance = ctx.projectedBalance;
      } catch (err) {
        console.warn("projected balance", club, err);
        row.projected_eos_balance = null;
      }

      scheduleRender();
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  if (renderTimer) clearTimeout(renderTimer);
  renderTable();
}

async function loadTable() {
  setStatus("pageStatus", "Loading checklist…");
  const wrap = document.getElementById("tableWrap");
  if (wrap) wrap.innerHTML = '<p class="note">Loading…</p>';

  const { data, error } = await supabase.rpc("admin_club_season_checklist");

  if (error) {
    const msg = [error.message, error.hint].filter(Boolean).join(" — ");
    setStatus(
      "pageStatus",
      `❌ ${msg}. Run supabase/sql/patches/admin_club_season_checklist_star_cap.sql in Supabase.`,
      false
    );
    if (wrap) wrap.innerHTML = `<p class="note">${escapeHtml(msg)}</p>`;
    return;
  }

  allRows = (data || []).map((row) => ({
    ...row,
    projected_eos_balance: undefined,
  }));

  renderTable();
  setStatus("pageStatus", `Loaded ${allRows.length} clubs — projecting balances…`);

  await enrichProjectedBalances(allRows);
  setStatus("pageStatus", `✅ ${allRows.length} clubs loaded.`);
}
