import { initFinanceAccountsPage } from "./finance_page_common.js?v=20260914-fine-trim";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
