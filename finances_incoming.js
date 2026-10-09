import { initFinanceSubPage } from "./finance_page_common.js?v=20261010-cup-pending";
import { renderFinancesIncomingIntro } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesIncomingIntro();
  initFinanceSubPage({
    pageId: "finances_incoming",
    pageSuffix: "Incoming",
    filter: "income",
    summaryKind: "income",
  });
});
