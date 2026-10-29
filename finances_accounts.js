import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261029-infra-merge";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
