import { initFinanceSubPage } from "./finance_page_common.js?v=20260810-staff-fin-preview";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_ledger",
    pageSuffix: "Activity ledger",
    filter: "all",
    summaryKind: "all",
  });
});
