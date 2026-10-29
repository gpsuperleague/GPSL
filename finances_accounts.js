import { initFinanceAccountsPage } from "./finance_page_common.js?v=20261029-infra-synth";
import { renderFinancesAccountsGuide } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesAccountsGuide();
  initFinanceAccountsPage();
});
