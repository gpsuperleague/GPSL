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
import { initBankCounter } from "./bank_counter.js?v=20260721-loan-due-fix";

async function refreshCounter(shortName) {
  if (shortName) {
    // Due collections only (server uses Aug–May loan calendar; June/July
    // will not pull Season 2 Aug+ instalments). Requires
    // loan_force_june_s2_reconcile.sql if balances were drained.
    try {
      await processMyDueLoanInstallments(supabase);
    } catch (e) {
      console.warn("processMyDueLoanInstallments:", e);
    }
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
