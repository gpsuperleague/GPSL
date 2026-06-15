import { supabase, initGlobal } from "./global.js";
import { formatMoney, loadClubSeasonArchive, processMyDueLoanInstallments } from "./competition.js";
import {
  applyFinanceClubHeader,
  loadFinanceSeasonContext,
  mountAdminFinancePicker,
  renderFinanceSubnav,
  resolveFinanceClubContext,
  wireFinanceStatLinks,
} from "./finance_page_common.js";

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

  const data = await loadFinanceSeasonContext(supabase, shortName);

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
  predictedEl.textContent = formatMoney(data.projectedBalance);
  predictedEl.className = `value ${data.projectedBalance >= 0 ? "positive" : "negative"}`;

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
