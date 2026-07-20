import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
  loadClubBalance,
  loadFinanceLedger,
  financeEntryLabel,
  isFinanceIncomeEntry,
} from "./competition.js";
import {
  aggregateLedgerByLine,
  renderFinanceSections,
  summariseLedgerTotals,
} from "./finance_ui.js?v=20260720-loan-20mo-season";
import { buildFinanceProjections } from "./finance_projections.js?v=20260720-loan-section";
import {
  appendAssignmentInfraPurchaseLedger,
  ledgerStartingBudget,
  clubHadPriorFinanceSeason,
} from "./finance_assignment_ledger.js?v=20260720-infra-strip2";
import {
  aggregateClubTransfersFromHistory,
  loadClubTransferHistoryForSeason,
  loadCurrentSeasonStart,
  mergeTransferHistoryIntoByLine,
  transferHistoryBalanceGap,
} from "./finance_transfers.js";

export const ADMIN_FINANCE_CLUB_KEY = "gpsl_admin_finance_club";

export const FINANCE_SUBNAV = [
  { id: "finances", href: "finances.html", label: "Overview" },
  { id: "finances_accounts", href: "finances_accounts.html", label: "Season accounts" },
  { id: "finances_ledger", href: "finances_ledger.html", label: "Activity ledger" },
  { id: "finances_incoming", href: "finances_incoming.html", label: "Incoming" },
  { id: "finances_outgoing", href: "finances_outgoing.html", label: "Outgoings" },
];

export function parseFinanceSeasonParam() {
  const raw = new URLSearchParams(window.location.search).get("season");
  if (!raw) return null;
  const trimmed = String(raw).trim();
  return trimmed ? trimmed : null;
}

/**
 * Resolve ?season= to a season id. Prefers human label (e.g. "1") over raw DB id.
 * Legacy links with numeric season_id still work as a fallback.
 */
export async function resolveSeasonIdFromParam(
  supabase,
  seasonParam,
  { archives = [], currentSeason = null } = {}
) {
  if (seasonParam == null || seasonParam === "") {
    return { seasonId: null, seasonLabel: null };
  }

  const param = String(seasonParam).trim();

  if (currentSeason?.label != null && String(currentSeason.label) === param) {
    return { seasonId: currentSeason.id ?? null, seasonLabel: currentSeason.label };
  }

  const archiveByLabel = archives.find((a) => String(a.season_label) === param);
  if (archiveByLabel) {
    return {
      seasonId: archiveByLabel.season_id,
      seasonLabel: archiveByLabel.season_label,
    };
  }

  // Label lookup before treating digits as DB id (Season "1" may be id 4)
  try {
    const { data } = await supabase
      .from("competition_season_public")
      .select("id, label")
      .eq("label", param)
      .maybeSingle();
    if (data?.id != null) {
      return { seasonId: data.id, seasonLabel: data.label };
    }
  } catch {
    /* ignore */
  }

  // Legacy: ?season=<database id> only when no label match
  const asId = Number(param);
  if (Number.isFinite(asId) && asId > 0 && Number.isInteger(asId)) {
    if (currentSeason?.id === asId) {
      return { seasonId: asId, seasonLabel: currentSeason.label ?? null };
    }
    const archiveById = archives.find((a) => Number(a.season_id) === asId);
    if (archiveById) {
      return {
        seasonId: archiveById.season_id,
        seasonLabel: archiveById.season_label,
      };
    }
    return { seasonId: asId, seasonLabel: null };
  }

  return { seasonId: null, seasonLabel: null };
}

export function financePageQuery(shortName, adminPreview, seasonRef = null) {
  const params = new URLSearchParams();
  if (adminPreview && shortName) params.set("club", shortName);
  // Prefer human season label in the URL (e.g. season=1), not DB id
  if (seasonRef != null && seasonRef !== "") {
    params.set("season", String(seasonRef));
  }
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

/** @deprecated use financePageQuery */
export function financeClubQuery(shortName) {
  return financePageQuery(shortName, true);
}

export function financePageHref(pageFile, shortName, adminPreview, seasonRef = null) {
  const base = pageFile.endsWith(".html") ? pageFile : `${pageFile}.html`;
  return `${base}${financePageQuery(shortName, adminPreview, seasonRef)}`;
}

export async function loadCurrentSeasonId(supabase) {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("id, label")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("loadCurrentSeasonId:", error);
    return { id: null, label: null };
  }

  return { id: data?.id ?? null, label: data?.label ?? null };
}

export async function loadClubFinanceSeasonArchives(supabase, clubShortName, limit = 5) {
  const { data, error } = await supabase
    .from("competition_club_finance_season_archive_public")
    .select(
      "season_id, season_label, club_short_name, opening_balance, closing_balance, income_total, cost_total, net_total, archived_at"
    )
    .eq("club_short_name", clubShortName)
    .order("season_id", { ascending: false })
    .limit(limit);

  if (error) {
    console.error("loadClubFinanceSeasonArchives:", error);
    return [];
  }

  return data || [];
}

export async function loadClubFinanceSeasonArchive(supabase, clubShortName, seasonId) {
  const { data, error } = await supabase
    .from("competition_club_finance_season_archive_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .eq("season_id", seasonId)
    .maybeSingle();

  if (error) {
    console.error("loadClubFinanceSeasonArchive:", error);
    return null;
  }

  return data;
}

export async function resolveFinanceSeasonView(supabase, shortName) {
  const seasonParam = parseFinanceSeasonParam();
  const currentSeason = await loadCurrentSeasonId(supabase);
  const archives = await loadClubFinanceSeasonArchives(supabase, shortName, 5);

  const resolved = await resolveSeasonIdFromParam(supabase, seasonParam, {
    archives,
    currentSeason,
  });
  const requestedSeasonId = resolved.seasonId;
  const requestedSeasonLabel = resolved.seasonLabel;

  const activeSeasonId = requestedSeasonId ?? currentSeason.id;
  const isHistorical =
    requestedSeasonId != null &&
    currentSeason.id != null &&
    requestedSeasonId !== currentSeason.id;

  let archiveRow = null;
  if (isHistorical) {
    archiveRow = await loadClubFinanceSeasonArchive(
      supabase,
      shortName,
      requestedSeasonId
    );
  }

  return {
    requestedSeasonId,
    requestedSeasonLabel:
      requestedSeasonLabel ??
      archiveRow?.season_label ??
      (isHistorical ? null : currentSeason.label),
    currentSeasonId: currentSeason.id,
    currentSeasonLabel: currentSeason.label,
    activeSeasonId,
    isHistorical,
    archiveRow,
    archives,
  };
}

export function renderFinanceSeasonHistoryNav(
  container,
  { archives, currentSeasonId, currentSeasonLabel, shortName, adminPreview, activeSeasonId }
) {
  if (!container) return;

  const pageFile =
    window.location.pathname.split("/").pop() || "finances.html";

  const currentLinks = [];
  const pastLinks = [];

  if (currentSeasonId) {
    const active = activeSeasonId === currentSeasonId ? " active" : "";
    const href = financePageHref(pageFile, shortName, adminPreview);
    const label = currentSeasonLabel
      ? `Current (${currentSeasonLabel})`
      : "Current season";
    currentLinks.push(
      `<a href="${href}" class="fin-season-link fin-season-current${active}">${label}</a>`
    );
  }

  for (const row of archives) {
    if (row.season_id === currentSeasonId) continue;
    const active = activeSeasonId === row.season_id ? " active" : "";
    const seasonTag = row.season_label || String(row.season_id);
    const href = financePageHref(
      pageFile,
      shortName,
      adminPreview,
      seasonTag
    );
    pastLinks.push(
      `<a href="${href}" class="fin-season-link fin-season-past${active}" title="${seasonTag} closing balance">
        ${formatMoney(row.closing_balance)} (${seasonTag})
      </a>`
    );
  }

  if (!currentLinks.length && !pastLinks.length) {
    container.innerHTML =
      '<p class="empty">No archived finance seasons yet — snapshots are created when admins archive a completed season.</p>';
    return;
  }

  const parts = [];
  if (currentLinks.length) {
    parts.push(
      `<div class="fin-season-group fin-season-group-current">
        <span class="fin-season-group-label">Live</span>
        <div class="fin-season-group-links">${currentLinks.join("")}</div>
      </div>`
    );
  }
  if (pastLinks.length) {
    parts.push(
      `<div class="fin-season-group fin-season-group-past">
        <span class="fin-season-group-label">Past seasons</span>
        <div class="fin-season-group-links">${pastLinks.join("")}</div>
      </div>`
    );
  }

  container.innerHTML = `<nav class="fin-season-nav" aria-label="Finance season history">${parts.join('<div class="fin-season-divider" role="separator" aria-hidden="true"></div>')}</nav>`;
}

export function applyHistoricalFinanceBanner(seasonView) {
  if (!seasonView?.isHistorical) return;

  const existing = document.getElementById("financeArchiveBanner");
  if (existing) existing.remove();

  const label = seasonView.archiveRow?.season_label || "selected season";
  const note = document.createElement("p");
  note.id = "financeArchiveBanner";
  note.className = "finance-archive-banner";
  note.style.cssText =
    "margin:8px 0 0;padding:8px 12px;background:#2a2418;border:1px solid #664400;border-radius:6px;color:#e8c070;font-size:13px;";
  note.textContent = `Viewing archived finances for ${label} — read-only snapshot from season end.`;

  const meta = document.getElementById("pageMeta");
  if (meta) {
    meta.insertAdjacentElement("afterend", note);
  }
}

export function wireFinanceStatLinks(shortName, adminPreview, seasonId = null) {
  const ledger = financePageHref("finances_ledger.html", shortName, adminPreview, seasonId);
  const incoming = financePageHref("finances_incoming.html", shortName, adminPreview, seasonId);
  const outgoing = financePageHref("finances_outgoing.html", shortName, adminPreview, seasonId);
  const accounts = financePageHref("finances_accounts.html", shortName, adminPreview, seasonId);

  for (const [id, href] of [
    ["linkLedger", ledger],
    ["linkIncoming", incoming],
    ["linkOutgoing", outgoing],
    ["linkAccounts", accounts],
    ["linkLedgerInline", ledger],
    ["linkAccountsInline", accounts],
  ]) {
    const el = document.getElementById(id);
    if (el) el.href = href;
  }
}

export function renderFinanceSubnav(activePageId, shortName, adminPreview, seasonId = null) {
  const el = document.getElementById("financeSubnav");
  if (!el) return;

  el.innerHTML = FINANCE_SUBNAV.map((item) => {
    const href = financePageHref(item.href, shortName, adminPreview, seasonId);
    const active = item.id === activePageId ? " active" : "";
    return `<a href="${href}" class="fin-subnav-link${active}">${item.label}</a>`;
  }).join("");
}

export async function resolveFinanceClubContext(user) {
  const params = new URLSearchParams(window.location.search);
  const clubParam = params.get("club")?.trim();

  const { data: owned } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (owned?.ShortName) {
    return {
      shortName: owned.ShortName,
      clubLabel: owned.Club,
      adminPreview: false,
    };
  }

  if (isGpslAdminUser(user)) {
    const shortName =
      clubParam || sessionStorage.getItem(ADMIN_FINANCE_CLUB_KEY) || null;

    if (!shortName) {
      return {
        shortName: null,
        clubLabel: null,
        adminPreview: true,
        needsAdminPicker: true,
      };
    }

    sessionStorage.setItem(ADMIN_FINANCE_CLUB_KEY, shortName);

    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("Club")
      .eq("ShortName", shortName)
      .maybeSingle();

    return {
      shortName,
      clubLabel: clubRow?.Club || shortName,
      adminPreview: true,
    };
  }

  return { shortName: null, clubLabel: null, adminPreview: false, noClub: true };
}

export async function applyFinanceClubHeader(
  shortName,
  clubLabel,
  { adminPreview = false, pageSuffix = "Finances" } = {}
) {
  await loadClubsMap();
  const fullName = fullClubName(shortName) || clubLabel || shortName;
  const titleEl = document.getElementById("pageTitle");
  if (titleEl) {
    titleEl.textContent = adminPreview
      ? `${fullName} — ${pageSuffix} (admin preview)`
      : `${fullName} — ${pageSuffix}`;
  }
  const badge = document.getElementById("clubBadgeHeader");
  if (badge) badge.src = `images/club_badges/${shortName}.png`;
}

export async function mountAdminFinancePicker(onSelect) {
  const anchor = document.getElementById("pageMeta");
  if (!anchor) return null;

  const { data: clubs, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error || !clubs?.length) {
    anchor.textContent = "Admin preview — could not load club list.";
    return null;
  }

  const wrap = document.createElement("div");
  wrap.className = "admin-finance-picker";
  wrap.style.cssText =
    "margin-top:8px;padding:10px 12px;background:#222;border:1px solid #444;border-radius:6px;font-size:13px;";

  const label = document.createElement("label");
  label.textContent = "Preview club: ";
  label.style.marginRight = "8px";

  const select = document.createElement("select");
  select.style.cssText =
    "padding:6px 8px;background:#111;border:1px solid #555;color:#ddd;border-radius:4px;min-width:220px;";

  for (const c of clubs) {
    const opt = document.createElement("option");
    opt.value = c.ShortName;
    opt.textContent = `${c.Club || c.ShortName} (${c.ShortName})`;
    select.appendChild(opt);
  }

  const saved = sessionStorage.getItem(ADMIN_FINANCE_CLUB_KEY);
  if (saved && [...select.options].some((o) => o.value === saved)) {
    select.value = saved;
  }

  wrap.appendChild(label);
  wrap.appendChild(select);
  anchor.replaceWith(wrap);

  select.addEventListener("change", () => {
    sessionStorage.setItem(ADMIN_FINANCE_CLUB_KEY, select.value);
    const url = new URL(window.location.href);
    url.searchParams.set("club", select.value);
    window.location.href = url.toString();
  });

  if (typeof onSelect === "function") onSelect(select.value);
  return select;
}

/** @param {"all"|"income"|"cost"} filter */
export function filterLedgerRows(rows, filter) {
  if (filter === "all") return rows;
  return rows.filter((r) => {
    const income = isFinanceIncomeEntry(r.entry_type, r.amount);
    return filter === "income" ? income : !income;
  });
}

export function renderLedgerTable(container, rows, { emptyMessage } = {}) {
  if (!container) return;

  if (!rows.length) {
    container.innerHTML = `<p class="empty">${emptyMessage || "No ledger lines yet for this view."}</p>`;
    return;
  }

  const body = rows
    .map((r) => {
      const md = r.matchday ? `MD${r.matchday}` : "—";
      const fixture =
        r.home_club_short_name && r.away_club_short_name
          ? `${r.home_club_short_name} vs ${r.away_club_short_name}`
          : "—";
      const income = isFinanceIncomeEntry(r.entry_type, r.amount);
      const rowClass = income ? "income" : "cost";
      const sign = Number(r.amount) >= 0 ? "+" : "";

      return `
        <tr class="${rowClass}">
          <td class="col-when">${new Date(r.created_at).toLocaleString("en-GB")}</td>
          <td class="col-type">${financeEntryLabel(r.entry_type)}</td>
          <td class="col-md">${md}</td>
          <td class="col-fixture">${fixture}</td>
          <td class="col-amount money">${sign}${formatMoney(Math.abs(r.amount))}</td>
          <td class="col-detail">${r.description || ""}</td>
        </tr>
      `;
    })
    .join("");

  container.innerHTML = `
    <div class="ledger-scroll">
      <table class="fin-table">
        <thead>
          <tr>
            <th class="col-when">When</th>
            <th class="col-type">Type</th>
            <th class="col-md">MD</th>
            <th class="col-fixture">Fixture</th>
            <th class="col-amount">Amount</th>
            <th class="col-detail">Detail</th>
          </tr>
        </thead>
        <tbody>${body}</tbody>
      </table>
    </div>
  `;
}

async function loadPreviousSeasonClosingBalance(supabase, clubShortName, currentSeasonId) {
  if (!currentSeasonId) return null;

  const { data, error } = await supabase
    .from("competition_club_finance_season_archive_public")
    .select("closing_balance, season_id")
    .eq("club_short_name", clubShortName)
    .lt("season_id", currentSeasonId)
    .order("season_id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.warn("loadPreviousSeasonClosingBalance:", error);
    return null;
  }

  if (data?.closing_balance == null) return null;
  const value = Number(data.closing_balance);
  return Number.isFinite(value) ? value : null;
}

/**
 * Season opening = GPSL starting budget (before auctions) for new assignments,
 * or prior season closing for continuing clubs. Falls back to ledger inference.
 */
async function resolveSeasonOpeningBalance(
  supabase,
  shortName,
  { ledger, balanceNow, net, transferGap, seasonId }
) {
  // Continuing clubs: prior season closing beats any (wrong) stadium starting_budget
  const prevClosing = await loadPreviousSeasonClosingBalance(supabase, shortName, seasonId);
  if (prevClosing != null) return prevClosing;

  const fromLedger = ledgerStartingBudget(ledger);
  if (fromLedger != null) return fromLedger;

  const { data: assign, error } = await supabase.rpc("club_assignment_finance_display", {
    p_club_short_name: shortName,
  });

  if (error) {
    console.warn("club_assignment_finance_display:", error);
  } else if (assign?.show_in_accounts) {
    const starting = Number(assign.starting_budget);
    if (Number.isFinite(starting) && starting > 0) return starting;
  }

  return balanceNow - net - transferGap;
}

export async function loadFinanceSeasonContext(supabase, shortName, options = {}) {
  const { seasonView = null } = options;

  if (seasonView?.isHistorical) {
    const archiveRow = seasonView.archiveRow;
    if (!archiveRow) {
      return {
        isHistorical: true,
        missingArchive: true,
        balanceNow: 0,
        ledger: [],
        incomeTotal: 0,
        costTotal: 0,
        net: 0,
        byLine: new Map(),
        pendingByLine: new Map(),
        totalPending: 0,
        inferredOpeningAdjusted: 0,
        projectedBalance: 0,
      };
    }

    const ledger = Array.isArray(archiveRow.ledger_lines)
      ? archiveRow.ledger_lines
      : [];
    const { incomeTotal, costTotal, net } = summariseLedgerTotals(ledger);
    const byLine = aggregateLedgerByLine(ledger);
    const balanceNow = Number(archiveRow.closing_balance ?? 0);

    // Use the archived opening — do not look up prior-season archives by id
    // (test seasons with lower ids can poison Season "1" opening balance).
    let inferredOpeningAdjusted = Number(archiveRow.opening_balance);
    if (!Number.isFinite(inferredOpeningAdjusted)) {
      inferredOpeningAdjusted =
        balanceNow - Number(archiveRow.net_total ?? net);
    }

    return {
      isHistorical: true,
      seasonId: archiveRow.season_id,
      seasonLabel: archiveRow.season_label,
      balanceRow: { balance: balanceNow, club_name: shortName },
      balanceNow,
      ledger,
      incomeTotal: Number(archiveRow.income_total ?? incomeTotal),
      costTotal: Number(archiveRow.cost_total ?? costTotal),
      net: Number(archiveRow.net_total ?? net),
      byLine,
      pendingByLine: new Map(),
      totalPending: 0,
      subsidyPreview: null,
      inferredOpeningAdjusted,
      projectedBalance: balanceNow,
    };
  }

  const balanceRow = await loadClubBalance(supabase, shortName);
  const balanceNow = Number(balanceRow?.balance ?? 0);
  let ledger = await loadFinanceLedger(supabase, shortName, 1000);
  const currentSeason = await loadCurrentSeasonId(supabase);
  const continuingClub = await clubHadPriorFinanceSeason(
    supabase,
    shortName,
    currentSeason?.id ?? null
  );
  ledger = await appendAssignmentInfraPurchaseLedger(supabase, shortName, ledger, {
    continuingClub,
    currentSeasonId: currentSeason?.id ?? null,
  });
  const { incomeTotal, costTotal, net } = summariseLedgerTotals(ledger);
  const byLine = aggregateLedgerByLine(ledger);

  const seasonStart = await loadCurrentSeasonStart(supabase);
  const transferRows = await loadClubTransferHistoryForSeason(
    supabase,
    seasonStart
  );
  const transferAgg = aggregateClubTransfersFromHistory(
    transferRows,
    shortName
  );
  const transferGap = transferHistoryBalanceGap(transferAgg, byLine);
  mergeTransferHistoryIntoByLine(byLine, transferAgg);

  const inferredOpeningAdjusted = await resolveSeasonOpeningBalance(
    supabase,
    shortName,
    {
      ledger,
      balanceNow,
      net,
      transferGap,
      seasonId: currentSeason?.id ?? null,
    }
  );
  const { pendingByLine, totalPending, subsidyPreview } = await buildFinanceProjections(
    supabase,
    shortName,
    { byLine }
  );

  return {
    isHistorical: false,
    balanceRow,
    balanceNow,
    ledger,
    incomeTotal,
    costTotal,
    net,
    byLine,
    pendingByLine,
    totalPending,
    subsidyPreview,
    inferredOpeningAdjusted,
    projectedBalance: balanceNow + totalPending,
  };
}

export async function initFinanceAccountsPage() {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const emailEl = document.getElementById("userEmail");
  if (emailEl) emailEl.textContent = user.email;

  const ctx = await resolveFinanceClubContext(user);

  if (ctx.noClub) {
    const meta = document.getElementById("pageMeta");
    if (meta) meta.textContent = "No club linked — assign owner in GPSL Admin.";
    return;
  }

  if (ctx.needsAdminPicker) {
    await mountAdminFinancePicker();
    return;
  }

  const { shortName, clubLabel, adminPreview } = ctx;
  const seasonView = await resolveFinanceSeasonView(supabase, shortName);
  const seasonRef = seasonView.isHistorical
    ? seasonView.requestedSeasonLabel ||
      seasonView.archiveRow?.season_label ||
      seasonView.requestedSeasonId
    : null;

  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix: seasonView.isHistorical ? "Finances (archive)" : "Finances",
  });

  const meta = document.getElementById("pageMeta");
  if (meta && adminPreview) {
    meta.textContent = `Admin preview — ${shortName}.`;
  }
  applyHistoricalFinanceBanner(seasonView);
  renderFinanceSeasonHistoryNav(document.getElementById("financeSeasonHistory"), {
    ...seasonView,
    shortName,
    adminPreview,
  });

  renderFinanceSubnav("finances_accounts", shortName, adminPreview, seasonRef);

  const overviewLink = document.getElementById("backToFinances");
  if (overviewLink) {
    overviewLink.href = financePageHref("finances.html", shortName, adminPreview, seasonRef);
  }

  const data = await loadFinanceSeasonContext(supabase, shortName, { seasonView });

  const sectionsEl = document.getElementById("financeSections");
  if (sectionsEl) {
    if (data.missingArchive) {
      sectionsEl.innerHTML =
        '<p class="empty">No finance archive found for this season. Ask an admin to run the finance archive backfill for that season.</p>';
      return;
    }

    sectionsEl.innerHTML = renderFinanceSections(data.byLine, {
      pendingByLine: data.pendingByLine,
      runningStart: data.inferredOpeningAdjusted,
      currentBalance: data.balanceNow,
      subsidyPreview: data.subsidyPreview,
    });
  }
}

export async function initFinanceSubPage({
  pageId,
  pageSuffix,
  filter = "all",
  summaryKind = "none",
}) {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const emailEl = document.getElementById("userEmail");
  if (emailEl) emailEl.textContent = user.email;

  const ctx = await resolveFinanceClubContext(user);

  if (ctx.noClub) {
    const meta = document.getElementById("pageMeta");
    if (meta) meta.textContent = "No club linked — assign owner in GPSL Admin.";
    return;
  }

  if (ctx.needsAdminPicker) {
    await mountAdminFinancePicker();
    return;
  }

  const { shortName, clubLabel, adminPreview } = ctx;
  const seasonView = await resolveFinanceSeasonView(supabase, shortName);
  const seasonRef = seasonView.isHistorical
    ? seasonView.requestedSeasonLabel ||
      seasonView.archiveRow?.season_label ||
      seasonView.requestedSeasonId
    : null;

  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix: seasonView.isHistorical ? `${pageSuffix} (archive)` : pageSuffix,
  });

  const meta = document.getElementById("pageMeta");
  if (meta && adminPreview) {
    meta.textContent = `Admin preview — ${shortName}.`;
  }
  applyHistoricalFinanceBanner(seasonView);
  renderFinanceSeasonHistoryNav(document.getElementById("financeSeasonHistory"), {
    ...seasonView,
    shortName,
    adminPreview,
  });

  renderFinanceSubnav(pageId, shortName, adminPreview, seasonRef);

  const overviewLink = document.getElementById("backToFinances");
  if (overviewLink) {
    overviewLink.href = financePageHref("finances.html", shortName, adminPreview, seasonRef);
  }

  let ledger = [];
  if (seasonView.isHistorical && seasonView.archiveRow?.ledger_lines) {
    ledger = seasonView.archiveRow.ledger_lines;
  } else if (seasonView.isHistorical) {
    ledger = [];
  } else {
    ledger = await loadFinanceLedger(supabase, shortName, 500);
    const currentSeason = await loadCurrentSeasonId(supabase);
    ledger = await appendAssignmentInfraPurchaseLedger(supabase, shortName, ledger, {
      currentSeasonId: currentSeason?.id ?? null,
    });
  }

  const filtered = filterLedgerRows(ledger, filter);
  const { incomeTotal, costTotal } = summariseLedgerTotals(ledger);

  const summaryEl = document.getElementById("ledgerSummary");
  if (summaryEl && summaryKind !== "none") {
    if (summaryKind === "income") {
      summaryEl.textContent = `Posted income this season: ${formatMoney(incomeTotal)} · ${filtered.length} line${filtered.length === 1 ? "" : "s"}`;
      summaryEl.className = "ledger-summary positive";
    } else if (summaryKind === "cost") {
      summaryEl.textContent = `Posted costs this season: ${formatMoney(costTotal)} · ${filtered.length} line${filtered.length === 1 ? "" : "s"}`;
      summaryEl.className = "ledger-summary negative";
    } else {
      summaryEl.textContent = `${filtered.length} ledger line${filtered.length === 1 ? "" : "s"} · income ${formatMoney(incomeTotal)} · costs ${formatMoney(costTotal)}`;
      summaryEl.className = "ledger-summary";
    }
  }

  renderLedgerTable(document.getElementById("ledgerTable"), filtered, {
    emptyMessage: seasonView.isHistorical
      ? "No ledger lines were archived for this season."
      : filter === "income"
        ? "No posted income yet — gates, prizes, and transfer sales appear here when they post."
        : filter === "cost"
          ? "No posted costs yet — purchases, wages, and maintenance appear here when they post."
          : "No ledger lines yet. Gates post on confirmed results; transfers post when deals complete.",
  });
}

export { formatMoney, summariseLedgerTotals };
