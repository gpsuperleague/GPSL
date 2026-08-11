import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { formatMoney } from "./competition.js";
import { loadClubWageBillSummary } from "./club_wage_bill.js";
import {
  advisoryBudgetTitle,
  computeAdvisoryTransferBudget,
} from "./finance_advisory_budget.js";
import {
  applyFinanceClubHeader,
  applyHistoricalFinanceBanner,
  ensureStaffFinancePicker,
  loadFinanceSeasonContext,
  renderFinanceSeasonHistoryNav,
  renderFinanceSubnav,
  resolveFinanceClubContext,
  resolveFinanceSeasonView,
  wireFinanceStatLinks,
} from "./finance_page_common.js?v=20260810-staff-fin-preview";
import { renderFinancesOverviewNotes } from "./finances_rules.js?v=20260806-help-blocks";

function setAdvisoryBudgetDisplay(advisory, { historical = false } = {}) {
  const el = document.getElementById("advisoryTransferBudget");
  const hint = document.getElementById("advisoryTransferBudgetHint");
  const note = document.getElementById("advisoryTransferBudgetNote");
  const box = document.getElementById("linkAdvisoryBudget");
  if (!el) return;

  if (historical || !advisory) {
    el.textContent = "—";
    el.className = "value muted";
    if (hint) hint.textContent = "Current season only →";
    if (box) box.removeAttribute("title");
    if (note) note.hidden = historical;
    return;
  }

  el.textContent = formatMoney(advisory.spendable);
  el.className = `value ${advisory.spendable > 0.5 ? "positive" : "negative"}`;
  if (box) box.title = advisoryBudgetTitle(advisory);

  if (hint) {
    if (advisory.runwayNegative) {
      hint.textContent = `Runway ${formatMoney(advisory.raw)} — spend shown as ₿0 →`;
    } else if (advisory.bidExposure > 0.5) {
      hint.textContent = `${advisory.bidCount} winning bid${advisory.bidCount === 1 ? "" : "s"} (−${formatMoney(advisory.bidExposure)}) →`;
    } else {
      hint.textContent = "Ops forecast excl. transfers →";
    }
  }
  if (note) note.hidden = false;
}

function setWageBillDisplay(bill) {
  const playersEl = document.getElementById("wageBillPlayers");
  const managerEl = document.getElementById("wageBillManager");
  const totalEl = document.getElementById("wageBillTotal");
  if (!playersEl || !managerEl || !totalEl) return;

  if (!bill) {
    playersEl.textContent = "—";
    managerEl.textContent = "—";
    totalEl.textContent = "—";
    return;
  }

  playersEl.textContent = formatMoney(bill.players);
  managerEl.textContent = formatMoney(bill.manager);
  totalEl.textContent = formatMoney(bill.total);
}

async function loadFinancesForClub(shortName, clubLabel, { adminPreview = false } = {}) {
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

  const pageMeta = document.getElementById("pageMeta");
  if (pageMeta && adminPreview) {
    pageMeta.textContent = `Staff preview — viewing ${shortName}. You do not own this club.`;
  }
  applyHistoricalFinanceBanner(seasonView);
  renderFinanceSeasonHistoryNav(document.getElementById("financeSeasonHistory"), {
    ...seasonView,
    shortName,
    adminPreview,
  });

  renderFinanceSubnav("finances", shortName, adminPreview, seasonRef);
  wireFinanceStatLinks(shortName, adminPreview, seasonRef);

  // Loan dues: month lock is primary; Service Counter also auto-collects on visit.
  // Finances stays read-only here so opening accounts does not surprise-debit.

  const data = await loadFinanceSeasonContext(supabase, shortName, { seasonView });

  if (data.missingArchive) {
    document.getElementById("balanceAmount").textContent = "—";
    document.getElementById("incomeSeasonTotal").textContent = "—";
    document.getElementById("costSeasonTotal").textContent = "—";
    document.getElementById("netSeasonTotal").textContent = "—";
    document.getElementById("openingBalance").textContent = "—";
    document.getElementById("predictedBalance").textContent = "—";
    setAdvisoryBudgetDisplay(null, { historical: true });
    setWageBillDisplay(null);
    return;
  }

  if (seasonView.isHistorical) {
    setWageBillDisplay(null);
  } else {
    try {
      setWageBillDisplay(await loadClubWageBillSummary(supabase, shortName));
    } catch (err) {
      console.warn("wage bill summary:", err);
      setWageBillDisplay(null);
    }
  }

  document.getElementById("balanceAmount").textContent = formatMoney(data.balanceNow);
  document.getElementById("incomeSeasonTotal").textContent = formatMoney(data.incomeTotal);
  document.getElementById("costSeasonTotal").textContent = formatMoney(data.costTotal);

  const netEl = document.getElementById("netSeasonTotal");
  netEl.textContent = formatMoney(data.net);
  netEl.className = `value ${data.net >= 0 ? "positive" : "negative"}`;

  document.getElementById("openingBalance").textContent = formatMoney(
    data.inferredOpeningAdjusted
  );

  const predictedEl = document.getElementById("predictedBalance");
  const balanceLabel = document
    .getElementById("balanceAmount")
    ?.closest(".stat-box")
    ?.querySelector(".label");
  const predictedLabel = predictedEl?.closest(".stat-box")?.querySelector(".label");

  if (seasonView.isHistorical) {
    if (balanceLabel) balanceLabel.textContent = "Closing balance (archived)";
    if (predictedLabel) predictedLabel.textContent = "Projections (archived seasons)";
    predictedEl.textContent = "—";
    predictedEl.className = "value muted";
    setAdvisoryBudgetDisplay(null, { historical: true });
  } else {
    if (balanceLabel) balanceLabel.textContent = "Current balance";
    if (predictedLabel) predictedLabel.textContent = "Predicted end-of-season balance";
    predictedEl.textContent = formatMoney(data.projectedBalance);
    predictedEl.className = `value ${data.projectedBalance >= 0 ? "positive" : "negative"}`;

    try {
      const advisory = await computeAdvisoryTransferBudget(supabase, shortName, {
        balanceNow: data.balanceNow,
        byLine: data.byLine,
        pendingByLine: data.pendingByLine,
        bidExposure: data.bidExposure,
      });
      setAdvisoryBudgetDisplay(advisory);
    } catch (err) {
      console.warn("advisory transfer budget:", err);
      setAdvisoryBudgetDisplay(null);
    }
  }

}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  renderFinancesOverviewNotes();
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
    await ensureStaffFinancePicker(ctx);
    return;
  }

  await ensureStaffFinancePicker(ctx);
  await loadFinancesForClub(ctx.shortName, ctx.clubLabel, {
    adminPreview: ctx.adminPreview,
  });
});
