import { initFinanceSubPage } from "./finance_page_common.js?v=20261012-monthly-interest";
import { renderFinancesOutgoingIntro } from "./finances_rules.js";

document.addEventListener("DOMContentLoaded", () => {
  renderFinancesOutgoingIntro();
  initFinanceSubPage({
    pageId: "finances_outgoing",
    pageSuffix: "Outgoings",
    filter: "cost",
    summaryKind: "cost",
  });
});
