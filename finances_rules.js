/**
 * Club Finances — owner-facing notes / intros (modular copy).
 */

export function getFinancesOverviewNotes() {
  return {
    wageBill: `Seasonal wage commitments for the current squad and signed manager.
        Player wages are contract season amounts; manager salary is weekly wage × 52.
        These are charged at <b>Close Finances</b> / Post season wage bills (not weekly).`,
    balance: `<b>Season opening balance</b> is your GPSL starting budget for the season (before club or
        player auctions), or your archived closing balance carried over from the previous season.
        <b>Current balance</b> is your spendable cash: opening balance plus all income and costs
        posted to date. Click the balance box for the full <a href="finances_ledger.html" id="linkLedgerInline">activity ledger</a>.
        Used by <a href="transfer_center.html">Transfer Centre</a> and the market.`,
    predicted: `<b>Predicted end-of-season balance</b> uses your current balance plus <b>pending</b> forecasts
        in <a href="finances_accounts.html" id="linkAccountsInline">Season accounts</a> (upcoming home gates,
        stadium maintenance, player wages and manager salary where calculable, including unsettled winning bids).`,
    advisory: `<b>Advisory transfer budget</b> is spend guidance: current balance + predicted income − predicted
        expenditure (excluding transfer sales/purchases), then minus your live winning bids on players and
        managers. Shown as <b>₿0</b> minimum for spend; if projected runway is negative a warning appears.
        League prize pending follows your <b>current table position</b> (if that finish holds). Soft only — does not block bids.`,
    banking: `Loans, treasury, and repayments are handled at the
            <strong style="color:#e8c86a;">GPSL Central Bank</strong> — separate from your club accounts.`,
    seasonHistory: `Final finances for up to the last five completed seasons. Select a season to view its archived accounts and ledger.`,
  };
}

export function renderFinancesOverviewNotes() {
  const notes = getFinancesOverviewNotes();
  const map = [
    ["finWageBillNote", notes.wageBill],
    ["finBalanceNote", notes.balance],
    ["finPredictedNote", notes.predicted],
    ["advisoryTransferBudgetNote", notes.advisory],
    ["finBankingBlurb", notes.banking],
    ["finSeasonHistoryNote", notes.seasonHistory],
  ];
  for (const [id, html] of map) {
    const el = document.getElementById(id);
    if (el) el.innerHTML = html;
  }
}

export function getFinancesIncomingIntroHtml() {
  return `All <b>posted income</b> lines from your season ledger — gates, prizes, transfer sales, subsidies, etc.`;
}

export function getFinancesOutgoingIntroHtml() {
  return `All <b>posted costs</b> from your season ledger — purchases, wages, maintenance, fines, etc.`;
}

export function getFinancesAccountsGuideHtml() {
  return `Same structure as the classic Excel workbook.
        <b>Posted</b> = total already on your balance (ledger this season);
        <b>Breakdown</b> = individual posted amounts per type;
        <b>Running total</b> = season opening + posted lines so far;
        <b>Pending</b> = known future income/costs not yet posted (upcoming gates, wages, maintenance, etc.).
        Footer shows <b>projected balance</b>.`;
}

export function getFinancesAccountsLegendHtml() {
  return `Posted — = nothing on ledger yet &nbsp;|&nbsp; Pending — = no forecast for that line yet &nbsp;|&nbsp;
        green/red = income / cost`;
}

export function renderFinancesIncomingIntro() {
  const el = document.getElementById("finIncomingIntro");
  if (el) el.innerHTML = getFinancesIncomingIntroHtml();
}

export function renderFinancesOutgoingIntro() {
  const el = document.getElementById("finOutgoingIntro");
  if (el) el.innerHTML = getFinancesOutgoingIntroHtml();
}

export function renderFinancesAccountsGuide() {
  const guide = document.getElementById("finAccountsGuide");
  const legend = document.getElementById("finAccountsLegend");
  if (guide) guide.innerHTML = getFinancesAccountsGuideHtml();
  if (legend) legend.innerHTML = getFinancesAccountsLegendHtml();
}
