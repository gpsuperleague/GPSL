import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261020-opening-650";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
