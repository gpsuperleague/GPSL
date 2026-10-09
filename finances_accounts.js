import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261010-cup-pending";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
