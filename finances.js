import { supabase, initGlobal } from "./global.js";
import {
  formatMoney,
  loadClubBalance,
  loadFinanceLedger,
  loadClubSeasonArchive,
  processMyDueLoanInstallments,
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
import {
  applyFinanceClubHeader,
  mountAdminFinancePicker,
  renderFinanceSubnav,
  resolveFinanceClubContext,
  wireFinanceStatLinks,
} from "./finance_page_common.js";

function renderSubsidyGrid(preview, loadError) {
  const grid = document.getElementById("subsidyGrid");
  if (!grid) return;

  if (loadError) {
    grid.innerHTML = `<p class="subsidy-meta">${loadError}</p>`;
    return;
  }

  if (!preview) {
    grid.innerHTML = '<p class="subsidy-meta">Subsidy preview unavailable.</p>';
    return;
  }

  const hg = preview.homegrown || {};
  const youth = preview.youth || {};
  const bnb = preview.bnb || {};
  const statusOrDash = (s) => (s && s !== "—" ? s : "No tier");

  grid.innerHTML = `
    <div class="subsidy-card">
      <h3>Homegrown (HG)</h3>
      <p class="subsidy-status">${statusOrDash(hg.status)}</p>
      <p class="subsidy-meta">${hg.count ?? 0} homegrown player${hg.count === 1 ? "" : "s"} in squad</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(hg.amount || 0))}</p>
    </div>
    <div class="subsidy-card">
      <h3>Youth</h3>
      <p class="subsidy-status">${statusOrDash(youth.status)}</p>
      <p class="subsidy-meta">${youth.count ?? 0} under-21 player${youth.count === 1 ? "" : "s"} in squad</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(youth.amount || 0))}</p>
    </div>
    <div class="subsidy-card">
      <h3>Built not bought</h3>
      <p class="subsidy-status">${statusOrDash(bnb.status)}</p>
      <p class="subsidy-meta">${bnb.count ?? 0} at rating ≤${bnb.max_rating ?? "—"} (need ${bnb.min_required ?? "—"}+)</p>
      <p class="subsidy-amount">Est. payout ${formatMoney(Number(bnb.amount || 0))}</p>
    </div>
  `;
}

async function loadSubsidyStatus(clubShortName) {
  const { data, error } = await supabase.rpc("gov_subsidy_club_preview", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("gov_subsidy_club_preview") || msg.includes("function")) {
      renderSubsidyGrid(
        null,
        "Run supabase/sql/government_subsidies.sql in Supabase to enable subsidy status."
      );
      return;
    }
    renderSubsidyGrid(null, msg || "Could not load subsidy status.");
    return;
  }

  renderSubsidyGrid(data, null);
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

async function loadFinancesForClub(shortName, clubLabel, { adminPreview = false } = {}) {
  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix: "Finances",
  });

  const pageMeta = document.getElementById("pageMeta");
  if (pageMeta && adminPreview) {
    pageMeta.textContent = `Admin preview — viewing ${shortName}. You do not own this club.`;
  }

  renderFinanceSubnav("finances", shortName, adminPreview);
  wireFinanceStatLinks(shortName, adminPreview);

  if (!adminPreview) {
    await processMyDueLoanInstallments(supabase);
  }

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

  renderArchive(await loadClubSeasonArchive(supabase, shortName));
  await loadSubsidyStatus(shortName);
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

  const ctx = await resolveFinanceClubContext(user);

  if (ctx.noClub) {
    document.getElementById("pageMeta").textContent =
      "No club linked — assign owner in GPSL Admin.";
    return;
  }

  if (ctx.needsAdminPicker) {
    await mountAdminFinancePicker();
    return;
  }

  await loadFinancesForClub(ctx.shortName, ctx.clubLabel, {
    adminPreview: ctx.adminPreview,
  });
});
