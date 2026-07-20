import { initFinanceSubPage } from "./finance_page_common.js?v=20260720-season-label";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_incoming",
    pageSuffix: "Incoming",
    filter: "income",
    summaryKind: "income",
  });
});
