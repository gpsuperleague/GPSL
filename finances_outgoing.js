import { initFinanceSubPage } from "./finance_page_common.js?v=20260810-staff-fin-preview";
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
