import { initFinanceSubPage } from "./finance_page_common.js?v=20261012-monthly-interest";
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
