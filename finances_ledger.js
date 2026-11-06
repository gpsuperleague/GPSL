import { initFinanceSubPage } from "./finance_page_common.js?v=20261106-owner-view";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_ledger",
    pageSuffix: "Activity ledger",
    filter: "all",
    summaryKind: "all",
  });
});
