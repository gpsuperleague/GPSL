import { initFinanceAccountsPage } from "./finance_page_common.js?v=20260914-video-72h";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
