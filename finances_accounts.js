import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261002-commercial";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
