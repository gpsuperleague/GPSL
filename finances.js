import { supabase, initGlobal } from "./global.js";
import { formatMoney, loadClubSeasonArchive, processMyDueLoanInstallments } from "./competition.js";
import {
  applyFinanceClubHeader,
  applyHistoricalFinanceBanner,
  loadFinanceSeasonContext,
  mountAdminFinancePicker,
  renderFinanceSeasonHistoryNav,
  renderFinanceSubnav,
  resolveFinanceClubContext,
  resolveFinanceSeasonView,
  wireFinanceStatLinks,
} from "./finance_page_common.js?v=20260720-season-sep";

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
  const seasonView = await resolveFinanceSeasonView(supabase, shortName);
  const seasonId = seasonView.isHistorical ? seasonView.requestedSeasonId : null;

  await applyFinanceClubHeader(shortName, clubLabel, {
    adminPreview,
    pageSuffix: seasonView.isHistorical ? "Finances (archive)" : "Finances",
  });

  const pageMeta = document.getElementById("pageMeta");
  if (pageMeta && adminPreview) {
    pageMeta.textContent = `Admin preview — viewing ${shortName}. You do not own this club.`;
  }
  applyHistoricalFinanceBanner(seasonView);
  renderFinanceSeasonHistoryNav(document.getElementById("financeSeasonHistory"), {
    ...seasonView,
    shortName,
    adminPreview,
  });

  renderFinanceSubnav("finances", shortName, adminPreview, seasonId);
  wireFinanceStatLinks(shortName, adminPreview, seasonId);

  if (!adminPreview && !seasonView.isHistorical) {
    await processMyDueLoanInstallments(supabase);
  }

  const data = await loadFinanceSeasonContext(supabase, shortName, { seasonView });

  if (data.missingArchive) {
    document.getElementById("balanceAmount").textContent = "—";
    document.getElementById("incomeSeasonTotal").textContent = "—";
    document.getElementById("costSeasonTotal").textContent = "—";
    document.getElementById("netSeasonTotal").textContent = "—";
    document.getElementById("openingBalance").textContent = "—";
    document.getElementById("predictedBalance").textContent = "—";
    return;
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
  } else {
    if (balanceLabel) balanceLabel.textContent = "Current balance";
    if (predictedLabel) predictedLabel.textContent = "Predicted end-of-season balance";
    predictedEl.textContent = formatMoney(data.projectedBalance);
    predictedEl.className = `value ${data.projectedBalance >= 0 ? "positive" : "negative"}`;
  }

  renderArchive(await loadClubSeasonArchive(supabase, shortName));
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
