import {
  supabase,
  initBankPage,
  renderBankSubnav,
  renderHeroStats,
  renderTreasurySummary,
  renderBankLedger,
} from "./central_bank_common.js";
import {
  loadGpslBankPublic,
  loadBankLedger,
  financeEntryLabel,
} from "./competition.js";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initBankPage())) return;

  renderBankSubnav("central_bank");

  const [bank, ledger] = await Promise.all([
    loadGpslBankPublic(supabase),
    loadBankLedger(supabase, 150),
  ]);

  renderHeroStats(bank);
  renderTreasurySummary(bank);
  renderBankLedger(ledger, financeEntryLabel);
});
