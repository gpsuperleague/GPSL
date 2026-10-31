import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261031-handpick-exp";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
