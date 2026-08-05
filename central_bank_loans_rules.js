/**
 * Central Bank league loans — intro copy.
 */

export function getCentralBankLoansIntroHtml() {
  return `All club loans with the GPSL Central Bank. Every loan runs <b>20 GPSL months</b>
        (August–May × two seasons when drawn in August; mid-season draws start the next GPSL month).
        Interest is fixed when the loan is taken and falls as installments are paid —
        early settlement at the <a href="central_bank_counter.html">Service counter</a> clears
        remaining principal and waives leftover interest. Season accounts only list payments
        posted for that season.`;
}

export function renderCentralBankLoansIntro(rootEl) {
  const root =
    rootEl ||
    document.getElementById("bankLoansIntro") ||
    document.querySelector(".bank-intro");
  if (!root) return;
  root.innerHTML = getCentralBankLoansIntroHtml();
}
