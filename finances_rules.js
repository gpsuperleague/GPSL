/**
 * Club Finances — owner-facing notes / intros (modular copy).
 */

export function getFinancesOverviewNotes() {
  return {
    wageBill: `Seasonal wage commitments for the current squad and signed manager.
        Player wages are contract season amounts; manager salary is weekly wage × 52.
        These are charged at <b>Close Finances</b> / Post season wage bills (not weekly).`,
    balance: `
      <h3>Opening &amp; current balance</h3>
      <ul>
        <li><b>Season opening</b> — GPSL starting budget for the season (before club or player auctions), or the archived closing balance carried over from last season.</li>
        <li><b>Current balance</b> — spendable cash: opening plus all income and costs posted to date.</li>
        <li>Click the balance box for the full <a href="finances_ledger.html" id="linkLedgerInline">activity ledger</a>.</li>
      </ul>
      <p class="fin-help-foot">Used by <a href="transfer_center.html">Transfer Centre</a> and the market.</p>`,
    predicted: `
      <h3>Predicted end-of-season balance</h3>
      <ul>
        <li>Starts from your <b>current balance</b>.</li>
        <li>Adds <b>pending</b> forecasts from <a href="finances_accounts.html" id="linkAccountsInline">Season accounts</a>.</li>
        <li>Includes upcoming home gates, stadium maintenance, player wages, and manager salary where calculable.</li>
        <li>Also includes unsettled winning bids.</li>
      </ul>`,
    advisory: `
      <h3>Advisory transfer budget</h3>
      <ul>
        <li><b>Spend guidance</b> — current balance + predicted income − predicted expenditure (excluding transfer sales/purchases).</li>
        <li>Then minus your live winning bids on players and managers.</li>
        <li>Shown as <b>₿0</b> minimum for spend; a warning appears if projected runway is negative.</li>
        <li>League prize pending follows your <b>current table position</b> (if that finish holds).</li>
      </ul>
      <p class="fin-help-foot">Soft only — does not block bids.</p>`,
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
