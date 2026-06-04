/**
 * Loan counter UI — used on central_bank.html (service desk).
 */
import {
  formatMoney,
  takeClubLoan,
  repayClubLoan,
  clubLoanHeadroom,
  loadClubLoans,
} from "./competition.js";

export function renderMyLoansAtCounter(loans, containerId = "counterLoanList") {
  const el = document.getElementById(containerId);
  if (!el) return;

  const active = loans.filter((l) => l.status === "active");
  if (!active.length) {
    el.innerHTML =
      '<p class="bank-empty">No active loans on your account. Use the counter to apply for credit.</p>';
    return;
  }

  el.innerHTML = `
    <table class="bank-table">
      <thead>
        <tr><th>Loan</th><th>Drawn</th><th>Owing</th><th>Rate</th><th>Since</th></tr>
      </thead>
      <tbody>
        ${active
          .map(
            (l) => `
          <tr>
            <td>#${l.id}</td>
            <td>${formatMoney(l.principal_drawn)}</td>
            <td class="owing">${formatMoney(l.outstanding_principal)}</td>
            <td>${Number(l.interest_rate_pct).toFixed(1)}%</td>
            <td>${new Date(l.created_at).toLocaleDateString("en-GB")}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>
  `;
}

function fillRepaySelect(loans, selectId = "repayLoanId") {
  const sel = document.getElementById(selectId);
  if (!sel) return;
  const active = loans.filter((l) => l.status === "active");
  sel.innerHTML =
    '<option value="">Oldest active loan</option>' +
    active
      .map(
        (l) =>
          `<option value="${l.id}">#${l.id} — ${formatMoney(l.outstanding_principal)}</option>`
      )
      .join("");
}

function showCounterMsg(id, text, ok) {
  const m = document.getElementById(id);
  if (!m) return;
  m.textContent = text;
  m.className = `counter-msg ${ok ? "ok" : "err"}`;
}

/**
 * @param {import('@supabase/supabase-js').SupabaseClient} supabase
 * @param {object} bank
 * @param {Array} loans
 * @param {() => Promise<void>} onSuccess
 */
function refreshCounterState(bank, loans) {
  const outstanding = loans
    .filter((l) => l.status === "active")
    .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
  const headroom = clubLoanHeadroom(bank, outstanding);
  const min = Number(bank?.loan_min_drawdown || 1000000);
  const maxDraw = Number(bank?.loan_max_drawdown || 50000000);
  const effectiveMax = Math.min(maxDraw, headroom);

  const limitsEl = document.getElementById("loanLimits");
  if (limitsEl) {
    limitsEl.textContent = `Min ${formatMoney(min)} · Max ${formatMoney(
      maxDraw
    )} per visit · Your headroom ${formatMoney(headroom)}`;
  }

  const headroomEl = document.getElementById("counterHeadroom");
  if (headroomEl) headroomEl.textContent = formatMoney(headroom);

  const amountInput = document.getElementById("loanAmount");
  if (amountInput) {
    amountInput.min = String(min);
    amountInput.max = effectiveMax > 0 ? String(effectiveMax) : String(min);
  }

  const takeBtn = document.getElementById("loanTakeBtn");
  if (takeBtn) takeBtn.disabled = effectiveMax < min;

  const repayBtn = document.getElementById("loanRepayBtn");
  const repayAllBtn = document.getElementById("loanRepayAllBtn");
  if (repayBtn) repayBtn.disabled = outstanding <= 0;
  if (repayAllBtn) repayAllBtn.disabled = outstanding <= 0;

  fillRepaySelect(loans);
  renderMyLoansAtCounter(loans);
}

export function initBankCounter(supabase, bank, loans, onSuccess) {
  const takeForm = document.getElementById("loanTakeForm");
  const repayForm = document.getElementById("loanRepayForm");
  const repayAllBtn = document.getElementById("loanRepayAllBtn");
  const disabledNote = document.getElementById("counterDisabled");
  const counterDesk = document.getElementById("counterDesk");

  if (!bank?.loans_enabled) {
    counterDesk?.setAttribute("hidden", "");
    disabledNote?.removeAttribute("hidden");
    return;
  }

  disabledNote?.setAttribute("hidden", "");
  counterDesk?.removeAttribute("hidden");
  refreshCounterState(bank, loans);

  if (takeForm?.dataset.bound) return;
  takeForm.dataset.bound = "1";
  repayForm.dataset.bound = "1";

  const min = Number(bank.loan_min_drawdown || 1000000);
  const maxDraw = Number(bank.loan_max_drawdown || 50000000);

  takeForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const amountInput = document.getElementById("loanAmount");
    const takeBtn = document.getElementById("loanTakeBtn");
    const outstanding = loans
      .filter((l) => l.status === "active")
      .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
    const headroom = clubLoanHeadroom(bank, outstanding);
    const effectiveMax = Math.min(maxDraw, headroom);
    const amt = Number(amountInput?.value);
    if (!Number.isFinite(amt) || amt < min) {
      showCounterMsg("loanTakeMsg", `Minimum draw is ${formatMoney(min)}.`, false);
      return;
    }
    if (amt > effectiveMax) {
      showCounterMsg(
        "loanTakeMsg",
        `Maximum available: ${formatMoney(effectiveMax)}.`,
        false
      );
      return;
    }
    takeBtn.disabled = true;
    showCounterMsg("loanTakeMsg", "Processing at the counter…", true);
    const res = await takeClubLoan(supabase, amt);
    takeBtn.disabled = false;
    if (res.error) {
      showCounterMsg("loanTakeMsg", res.error, false);
      return;
    }
    showCounterMsg(
      "loanTakeMsg",
      `Approved — loan #${res.loanId}, ${formatMoney(amt)} credited to your club.`,
      true
    );
    await onSuccess();
  });

  repayForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const repayBtn = document.getElementById("loanRepayBtn");
    const amt = Number(document.getElementById("repayAmount")?.value);
    const loanIdRaw = document.getElementById("repayLoanId")?.value;
    const loanId = loanIdRaw ? Number(loanIdRaw) : null;
    if (!Number.isFinite(amt) || amt <= 0) {
      showCounterMsg("loanRepayMsg", "Enter a repayment amount.", false);
      return;
    }
    if (repayBtn) repayBtn.disabled = true;
    showCounterMsg("loanRepayMsg", "Processing…", true);
    const res = await repayClubLoan(supabase, amt, loanId);
    if (repayBtn) repayBtn.disabled = false;
    if (res.error) {
      showCounterMsg("loanRepayMsg", res.error, false);
      return;
    }
    showCounterMsg("loanRepayMsg", `Thank you — ${formatMoney(res.repaid)} received.`, true);
    await onSuccess();
  });

  repayAllBtn?.addEventListener("click", async () => {
    const btn = document.getElementById("loanRepayAllBtn");
    const myLoans = await loadClubLoans(supabase);
    const outstanding = myLoans
      .filter((l) => l.status === "active")
      .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
    if (outstanding <= 0) return;
    if (btn) btn.disabled = true;
    const res = await repayClubLoan(supabase, outstanding);
    if (btn) btn.disabled = false;
    if (res.error) {
      showCounterMsg("loanRepayMsg", res.error, false);
      return;
    }
    showCounterMsg("loanRepayMsg", `Loan cleared — ${formatMoney(res.repaid)}.`, true);
    await onSuccess();
  });
}
