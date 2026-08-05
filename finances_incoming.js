import { initFinanceSubPage } from "./finance_page_common.js?v=20260720-season-label";
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
