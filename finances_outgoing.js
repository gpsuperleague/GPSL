import { initFinanceSubPage } from "./finance_page_common.js?v=20260720-season-sep2";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_outgoing",
    pageSuffix: "Outgoings",
    filter: "cost",
    summaryKind: "cost",
  });
});
