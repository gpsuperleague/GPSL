import {
  supabase,
  initBankPage,
  renderBankSubnav,
  renderHeroStats,
  renderLeagueLoans,
} from "./central_bank_common.js?v=20260720-loan-20mo";
import { loadGpslBankPublic, loadLeagueLoans } from "./competition.js";

document.addEventListener("DOMContentLoaded", async () => {
  const ctx = await initBankPage();
  if (!ctx) return;

  renderBankSubnav("central_bank_loans");

  const [bank, leagueLoans] = await Promise.all([
    loadGpslBankPublic(supabase),
    loadLeagueLoans(supabase),
  ]);

  renderHeroStats(bank);
  renderLeagueLoans(leagueLoans, ctx.shortName);
});
