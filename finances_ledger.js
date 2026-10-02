import { initFinanceSubPage } from "./finance_page_common.js?v=20261002-commercial";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_ledger",
    pageSuffix: "Activity ledger",
    filter: "all",
    summaryKind: "all",
  });
});
