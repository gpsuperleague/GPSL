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
} from "./finance_ui.js";
import { buildFinanceProjections } from "./finance_projections.js";
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

export function financeClubQuery(shortName) {
  if (!shortName) return "";
  return `?club=${encodeURIComponent(shortName)}`;
}

export function financePageHref(pageFile, shortName, adminPreview) {
  const base = pageFile.endsWith(".html") ? pageFile : `${pageFile}.html`;
  if (adminPreview && shortName) return `${base}${financeClubQuery(shortName)}`;
  return base;
}

export function wireFinanceStatLinks(shortName, adminPreview) {
  const ledger = financePageHref("finances_ledger.html", shortName, adminPreview);
  const incoming = financePageHref("finances_incoming.html", shortName, adminPreview);
  const outgoing = financePageHref("finances_outgoing.html", shortName, adminPreview);
  const accounts = financePageHref("finances_accounts.html", shortName, adminPreview);

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

export function renderFinanceSubnav(activePageId, shortName, adminPreview) {
  const el = document.getElementById("financeSubnav");
  if (!el) return;

  el.innerHTML = FINANCE_SUBNAV.map((item) => {
    const href = financePageHref(item.href, shortName, adminPreview);
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

export async function loadFinanceSeasonContext(supabase, shortName) {
  const balanceRow = await loadClubBalance(supabase, shortName);
  const balanceNow = Number(balanceRow?.balance ?? 0);
  const ledger = await loadFinanceLedger(supabase, shortName, 300);
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

  const inferredOpeningAdjusted = balanceNow - net - transferGap;
  const { pendingByLine, totalPending } = await buildFinanceProjections(
    supabase,
    shortName,
    { byLine }
  );

  return {
    balanceRow,
    balanceNow,
    ledger,
    incomeTotal,
    costTotal,
    net,
    byLine,
    pendingByLine,
    totalPending,
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

  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix: "Season accounts",
  });

  const meta = document.getElementById("pageMeta");
  if (meta && adminPreview) {
    meta.textContent = `Admin preview — ${shortName}.`;
  }

  renderFinanceSubnav("finances_accounts", shortName, adminPreview);

  const overviewLink = document.getElementById("backToFinances");
  if (overviewLink) {
    overviewLink.href = financePageHref("finances.html", shortName, adminPreview);
  }

  const data = await loadFinanceSeasonContext(supabase, shortName);

  const summaryEl = document.getElementById("accountsSummary");
  if (summaryEl) {
    summaryEl.textContent =
      `Posted net ${formatMoney(data.net)} · projected end-of-season ${formatMoney(data.projectedBalance)}`;
    summaryEl.className = `ledger-summary ${data.net >= 0 ? "positive" : "negative"}`;
  }

  const sectionsEl = document.getElementById("financeSections");
  if (sectionsEl) {
    sectionsEl.innerHTML = renderFinanceSections(data.byLine, {
      pendingByLine: data.pendingByLine,
      runningStart: data.inferredOpeningAdjusted,
      currentBalance: data.balanceNow,
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

  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix,
  });

  const meta = document.getElementById("pageMeta");
  if (meta && adminPreview) {
    meta.textContent = `Admin preview — ${shortName}.`;
  }

  renderFinanceSubnav(pageId, shortName, adminPreview);

  const overviewLink = document.getElementById("backToFinances");
  if (overviewLink) {
    overviewLink.href = financePageHref("finances.html", shortName, adminPreview);
  }

  const ledger = await loadFinanceLedger(supabase, shortName, 500);
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
    emptyMessage:
      filter === "income"
        ? "No posted income yet — gates, prizes, and transfer sales appear here when they post."
        : filter === "cost"
          ? "No posted costs yet — purchases, wages, and maintenance appear here when they post."
          : "No ledger lines yet. Gates post on confirmed results; transfers post when deals complete.",
  });
}

export { formatMoney, summariseLedgerTotals };
