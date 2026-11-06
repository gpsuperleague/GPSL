import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261106-owner-view";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
