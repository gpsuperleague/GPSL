import { initFinanceSubPage } from "./finance_page_common.js?v=20261002-commercial";
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
