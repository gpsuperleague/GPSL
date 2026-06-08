/**
 * Loan counter UI — used on central_bank_counter.html (service desk).
 */
import {
  formatMoney,
  takeClubLoan,
  repayClubLoan,
  clubLoanHeadroom,
  loadClubLoans,
  loadClubLoanInstallments,
} from "./competition.js";

export async function renderMyLoansAtCounter(
  supabase,
  loans,
  containerId = "counterLoanList"
) {
  const el = document.getElementById(containerId);
  if (!el) return;

  const active = loans.filter((l) => l.status === "active");
  if (!active.length) {
    el.innerHTML =
      '<p class="bank-empty">No active loans on your account. Use the counter to apply for credit.</p>';
    return;
  }

  const scheduleBlocks = await Promise.all(
    active.map(async (l) => {
      const inst = await loadClubLoanInstallments(supabase, l.id);
      const pending = inst.filter((i) => i.status === "pending");
      const next = pending[0];
      const scheduleRows = inst
        .map((i) => {
          const due = `${i.due_gpsl_month_label || i.due_gpsl_month} (${i.due_season_label || ""})`;
          const principal = formatMoney(i.principal_due);
          const interest = Number(i.interest_due || 0);
          const total = formatMoney(
            Number(i.total_due || i.principal_due) + (i.total_due ? 0 : interest)
          );
          const st =
            i.status === "paid"
              ? `<span class="status-paid">Paid ${formatMoney(
                  Number(i.paid_amount || 0) + Number(i.interest_paid || 0)
                )}</span>`
              : `<span class="status-pending">Due ${total}</span>`;
          const parts =
            interest > 0.005
              ? `${principal} + ${formatMoney(interest)} int.`
              : principal;
          return `<tr><td>${i.installment_no}/${l.repayment_months || 20}</td><td>${due}</td><td>${parts}</td><td>${st}</td></tr>`;
        })
        .join("");

      return `
        <div class="loan-schedule-block">
          <p class="loan-schedule-head">
            <b>Loan #${l.id}</b> — ${formatMoney(l.outstanding_principal)} principal
            · ${Number(l.interest_rate_pct || 5).toFixed(1)}% p.a. per GPSL season
            · ${l.repayment_months || 20} GPSL months
            ${
              next
                ? ` · Next: ${next.due_gpsl_month_label} ${formatMoney(
                    next.total_due ||
                      Number(next.principal_due || 0) + Number(next.interest_due || 0)
                  )}`
                : ""
            }
          </p>
          <table class="bank-table loan-schedule-table">
            <thead><tr><th>#</th><th>GPSL month</th><th>Breakdown</th><th>Due</th></tr></thead>
            <tbody>${scheduleRows}</tbody>
          </table>
        </div>`;
    })
  );

  el.innerHTML = scheduleBlocks.join("");
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
  void renderMyLoansAtCounter(supabase, loans);
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
  const months = 20;

  const limitsNote = document.getElementById("loanLimits");
  if (limitsNote && !limitsNote.dataset.monthsNote) {
    limitsNote.dataset.monthsNote = "1";
    limitsNote.textContent += ` · Repaid over ${months} GPSL months (equal principal + 5% season interest)`;
  }

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
      `Approved — loan #${res.loanId}, ${formatMoney(amt)} credited. Principal + bank interest over ${months} GPSL months.`,
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
