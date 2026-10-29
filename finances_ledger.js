import { initFinanceSubPage } from "./finance_page_common.js?v=20261029-infra-synth";

document.addEventListener("DOMContentLoaded", () => {
  initFinanceSubPage({
    pageId: "finances_ledger",
    pageSuffix: "Activity ledger",
    filter: "all",
    summaryKind: "all",
  });
});
