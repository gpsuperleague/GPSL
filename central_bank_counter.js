import {
  supabase,
  initBankPage,
  renderBankSubnav,
  renderHeroStats,
} from "./central_bank_common.js";
import {
  loadGpslBankPublic,
  loadClubLoans,
  processMyDueLoanInstallments,
} from "./competition.js";
import { initBankCounter } from "./bank_counter.js?v=20260714-loan-terms";

async function refreshCounter(shortName) {
  if (shortName) {
    await processMyDueLoanInstallments(supabase);
  }

  const [bank, myLoans] = await Promise.all([
    loadGpslBankPublic(supabase),
    loadClubLoans(supabase),
  ]);

  renderHeroStats(bank);
  initBankCounter(supabase, bank, myLoans, () => refreshCounter(shortName));
}

function setupCounterForClub(fullName, shortName) {
  const line = document.getElementById("counterClubLine");
  if (fullName && line) {
    line.textContent = `You are banking as ${fullName}. Apply for credit or repay below.`;
    return;
  }

  if (line) {
    line.textContent =
      "No club linked to your account — assign an owner in admin before using the counter.";
  }
  document.getElementById("counterDesk")?.setAttribute("hidden", "");
  document.getElementById("counterDisabled")?.removeAttribute("hidden");
  const disabled = document.getElementById("counterDisabled");
  if (disabled) {
    disabled.textContent =
      "Service counter closed until your account is linked to a club.";
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const ctx = await initBankPage();
  if (!ctx) return;

  renderBankSubnav("central_bank_counter");
  setupCounterForClub(ctx.fullName, ctx.shortName);

  if (ctx.shortName) {
    await refreshCounter(ctx.shortName);
  } else {
    const bank = await loadGpslBankPublic(supabase);
    renderHeroStats(bank);
  }
});
