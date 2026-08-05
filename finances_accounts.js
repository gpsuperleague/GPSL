import { initFinanceAccountsPage } from "./finance_page_common.js?v=20260804-loan-catchup";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
