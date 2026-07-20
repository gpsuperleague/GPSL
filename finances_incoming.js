import { initFinanceSubPage } from "./finance_page_common.js?v=20260720-season-sep";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_incoming",
    pageSuffix: "Incoming",
    filter: "income",
    summaryKind: "income",
  });
});
