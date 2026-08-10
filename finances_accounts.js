import { initFinanceAccountsPage } from "./finance_page_common.js?v=20260810-staff-fin-preview";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
