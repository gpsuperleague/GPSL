import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
  loadClubBalance,
  loadFinanceLedger,
  loadClubSeasonArchive,
  processMyDueLoanInstallments,
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

function renderLedger(rows) {
  const el = document.getElementById("ledgerTable");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No ledger lines yet for this club. Gates post on confirmed results; transfers post when deals complete.</p>';
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
          <td>${new Date(r.created_at).toLocaleString("en-GB")}</td>
          <td>${financeEntryLabel(r.entry_type)}</td>
          <td>${md}</td>
          <td>${fixture}</td>
          <td class="money">${sign}${formatMoney(Math.abs(r.amount))}</td>
          <td>${r.description || ""}</td>
        </tr>
      `;
    })
    .join("");

  el.innerHTML = `
    <table class="fin-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Type</th>
          <th>MD</th>
          <th>Fixture</th>
          <th>Amount</th>
          <th>Detail</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

function renderArchive(rows) {
  const el = document.getElementById("archiveList");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No archived seasons — gate history uses a neutral mid-table boost until rows are added.</p>';
    return;
  }

  el.innerHTML = `
    <ul class="archive-ul">
      ${rows
        .map(
          (r) =>
            `<li><b>${r.season_label}</b> — ${r.division}, finished <b>${r.final_position}</b></li>`
        )
        .join("")}
    </ul>
  `;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent =
      "No club linked — assign owner in GPSL Admin.";
    return;
  }

  await loadClubsMap();
  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club;

  document.getElementById("pageTitle").textContent = `${fullName} — Finances`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  await processMyDueLoanInstallments(supabase);

  const balanceRow = await loadClubBalance(supabase, shortName);
  document.getElementById("balanceAmount").textContent = formatMoney(
    balanceRow?.balance ?? 0
  );

  const ledger = await loadFinanceLedger(supabase, shortName, 300);
  const { incomeTotal, costTotal, net } = summariseLedgerTotals(ledger);
  const balanceNow = Number(balanceRow?.balance ?? 0);

  document.getElementById("incomeSeasonTotal").textContent =
    formatMoney(incomeTotal);
  document.getElementById("costSeasonTotal").textContent = formatMoney(costTotal);
  const netEl = document.getElementById("netSeasonTotal");
  netEl.textContent = formatMoney(net);
  netEl.className = `value ${net >= 0 ? "positive" : "negative"}`;

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

  document.getElementById("openingBalance").textContent = formatMoney(
    inferredOpeningAdjusted
  );

  const { pendingByLine, totalPending } = await buildFinanceProjections(
    supabase,
    shortName,
    { byLine }
  );
  const projectedBalance = balanceNow + totalPending;

  const predictedEl = document.getElementById("predictedBalance");
  predictedEl.textContent = formatMoney(projectedBalance);
  predictedEl.className = `value ${projectedBalance >= 0 ? "positive" : "negative"}`;

  const sectionsEl = document.getElementById("financeSections");
  if (sectionsEl) {
    sectionsEl.innerHTML = renderFinanceSections(byLine, {
      pendingByLine,
      runningStart: inferredOpeningAdjusted,
      currentBalance: balanceNow,
    });
  }

  renderLedger(ledger);
  renderArchive(await loadClubSeasonArchive(supabase, shortName));
});
