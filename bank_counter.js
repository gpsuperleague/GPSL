/**
 * Loan counter UI — central_bank_counter.html (service desk).
 * Full loan terms, remaining interest, and early settlement live here.
 * Season accounts only lists payments already posted to the ledger.
 */
import {
  formatMoney,
  takeClubLoan,
  repayClubLoan,
  clubLoanHeadroom,
  loadClubLoans,
  loadClubLoanInstallments,
  checkClubLoanCredit,
} from "./competition.js";

function sumInterestDue(inst, pendingOnly = false) {
  return inst.reduce((s, i) => {
    if (pendingOnly && i.status !== "pending") return s;
    return s + Number(i.interest_due || 0);
  }, 0);
}

function sumInterestRemaining(inst) {
  return inst.reduce((s, i) => {
    if (i.status !== "pending") return s;
    return s + Math.max(0, Number(i.interest_due || 0) - Number(i.interest_paid || 0));
  }, 0);
}

function sumInterestPaid(inst) {
  return inst.reduce((s, i) => s + Number(i.interest_paid || 0), 0);
}

function dueLabel(i) {
  return `${i.due_gpsl_month_label || i.due_gpsl_month} (${i.due_season_label || ""})`;
}

function firstPending(inst) {
  return inst.find((i) => i.status === "pending") || null;
}

function lastPending(inst) {
  const pending = inst.filter((i) => i.status === "pending");
  return pending.length ? pending[pending.length - 1] : null;
}

function loanSummaryHtml(l, inst) {
  const drawn = Number(l.principal_drawn || 0);
  const outstanding = Number(l.outstanding_principal || 0);
  const rate = Number(l.interest_rate_pct || 5);
  const months = Number(l.repayment_months || 20);
  const fromMonth = l.drawdown_gpsl_month_label || l.drawdown_gpsl_month || "—";

  const interestFullTerm = sumInterestDue(inst);
  const interestPaid = sumInterestPaid(inst);
  const interestRemaining = sumInterestRemaining(inst);
  const fullTermLeft = outstanding + interestRemaining;
  const earlySettle = outstanding;

  const next = firstPending(inst);
  const last = lastPending(inst);
  const pendingCount = inst.filter((i) => i.status === "pending").length;
  const canEarly = outstanding > 0.005;

  return `
    <div class="loan-summary-card" data-loan-id="${l.id}">
      <div class="loan-summary-title">
        <b>Loan #${l.id}</b>
        <span class="loan-summary-badge">${rate.toFixed(1)}% p.a.</span>
      </div>
      <dl class="loan-summary-dl">
        <div><dt>Borrowed</dt><dd>${formatMoney(drawn)}</dd></div>
        <div><dt>Repayment period</dt><dd>${months} GPSL months from ${fromMonth} (two seasons when drawn in August)</dd></div>
        <div><dt>Interest over full term</dt><dd>${formatMoney(interestFullTerm)} on top of the loan</dd></div>
        <div><dt>Interest paid so far</dt><dd>${formatMoney(interestPaid)}</dd></div>
        <div><dt>Interest still due</dt><dd>${formatMoney(interestRemaining)}</dd></div>
        <div><dt>Principal left</dt><dd class="loan-owing">${formatMoney(outstanding)}</dd></div>
        <div><dt>Left if full term</dt><dd class="loan-owing">${formatMoney(fullTermLeft)} (principal + remaining interest)</dd></div>
        <div><dt>Early repayment</dt><dd><b>${formatMoney(earlySettle)}</b> — principal only; remaining interest is not charged</dd></div>
        <div><dt>Schedule left</dt><dd>${
          pendingCount
            ? `${pendingCount} installment${pendingCount === 1 ? "" : "s"} · next ${next ? dueLabel(next) : "—"} · last ${last ? dueLabel(last) : "—"}`
            : "None — cleared or fully scheduled"
        }</dd></div>
      </dl>
      <div class="loan-summary-actions">
        <button type="button" class="counter-btn secondary loan-early-btn"
          data-loan-id="${l.id}" data-amount="${earlySettle}" ${canEarly ? "" : "disabled"}>
          Early repay — ${formatMoney(earlySettle)}
        </button>
      </div>
    </div>`;
}

function scheduleRowsHtml(l, inst) {
  return inst
    .map((i) => {
      const principal = formatMoney(i.principal_due);
      const interest = Number(i.interest_due || 0);
      const parts =
        interest > 0.005
          ? `${principal} + ${formatMoney(interest)} int.`
          : principal;
      const paidTotal =
        Number(i.paid_amount || 0) + Number(i.interest_paid || 0);
      const st =
        i.status === "paid"
          ? `<span class="status-paid">Paid ${formatMoney(paidTotal)}</span>`
          : i.status === "skipped"
            ? `<span class="status-pending">Skipped</span>`
            : `<span class="status-pending">Due</span>`;
      return `<tr>
        <td>${i.installment_no}/${l.repayment_months || 20}</td>
        <td>${dueLabel(i)}</td>
        <td>${parts}</td>
        <td>${st}</td>
      </tr>`;
    })
    .join("");
}

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
      '<p class="bank-empty">No active loans. Apply for credit at the forms on the right.</p>';
    return;
  }

  const blocks = await Promise.all(
    active.map(async (l) => {
      const inst = await loadClubLoanInstallments(supabase, l.id);
      return `
        <div class="loan-schedule-block">
          ${loanSummaryHtml(l, inst)}
          <details class="loan-schedule-details">
            <summary>Month-by-month schedule</summary>
            <table class="bank-table loan-schedule-table">
              <thead><tr><th>#</th><th>GPSL month</th><th>Breakdown</th><th>Status</th></tr></thead>
              <tbody>${scheduleRowsHtml(l, inst)}</tbody>
            </table>
          </details>
        </div>`;
    })
  );

  el.innerHTML = blocks.join("");
}

function fillRepaySelect(loans) {
  const sel = document.getElementById("repayLoanId");
  if (!sel) return;
  const active = loans.filter((l) => l.status === "active");
  sel.innerHTML =
    '<option value="">Oldest active loan</option>' +
    active
      .map(
        (l) =>
          `<option value="${l.id}">#${l.id} — early settle ${formatMoney(
            l.outstanding_principal
          )} (principal)</option>`
      )
      .join("");
}

function showCounterMsg(id, text, ok) {
  const m = document.getElementById(id);
  if (!m) return;
  m.textContent = text;
  m.className = `counter-msg ${ok ? "ok" : "err"}`;
}

function outstandingTotal(loans) {
  return loans
    .filter((l) => l.status === "active")
    .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
}

function paintLimits(bank, loans) {
  const outstanding = outstandingTotal(loans);
  const headroom = clubLoanHeadroom(bank, outstanding);
  const min = Number(bank?.loan_min_drawdown || 1000000);
  const maxDraw = Number(bank?.loan_max_drawdown || 50000000);
  const effectiveMax = Math.min(maxDraw, headroom);

  const limitsEl = document.getElementById("loanLimits");
  if (limitsEl) {
    limitsEl.textContent = `Min ${formatMoney(min)} · Max ${formatMoney(
      maxDraw
    )} per visit · Your headroom ${formatMoney(
      headroom
    )} · Term 20 GPSL months + season interest`;
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
  if (repayAllBtn) {
    repayAllBtn.disabled = outstanding <= 0;
    repayAllBtn.textContent =
      outstanding > 0
        ? `Early settle all — ${formatMoney(outstanding)} (no remaining interest)`
        : "Early settle all outstanding";
  }

  const earlyHint = document.getElementById("loanEarlyHint");
  if (earlyHint) {
    earlyHint.textContent =
      outstanding > 0
        ? `Early repayment clears principal only (${formatMoney(
            outstanding
          )} total). Interest on future installments is waived.`
        : "No active principal to settle early.";
  }

  fillRepaySelect(loans);
  return { outstanding, min, maxDraw, headroom, effectiveMax };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function hideLoanCreditPanels() {
  document.getElementById("loanCreditCheck")?.setAttribute("hidden", "");
  document.getElementById("loanCreditReject")?.setAttribute("hidden", "");
  const flash = document.getElementById("loanCreditCheckFlash");
  if (flash) flash.textContent = "Running credit check…";
}

function showLoanCreditCheckFlash(message = "Running credit check…") {
  hideLoanCreditPanels();
  const panel = document.getElementById("loanCreditCheck");
  const flash = document.getElementById("loanCreditCheckFlash");
  if (flash) flash.textContent = message;
  panel?.removeAttribute("hidden");
}

function showLoanCreditRejection(message) {
  document.getElementById("loanCreditCheck")?.setAttribute("hidden", "");
  const panel = document.getElementById("loanCreditReject");
  const text = document.getElementById("loanCreditRejectText");
  if (text) {
    text.textContent =
      message ||
      "Application declined. The bank manager checked the club's creditworthiness and an unfavourable report was received.";
  }
  panel?.removeAttribute("hidden");
}

function wireEarlyButtons(supabase, onSuccess) {
  document.querySelectorAll(".loan-early-btn").forEach((btn) => {
    if (btn.dataset.bound === "1") return;
    btn.dataset.bound = "1";
    btn.addEventListener("click", async () => {
      const loanId = Number(btn.dataset.loanId);
      const amount = Number(btn.dataset.amount);
      if (!loanId || !(amount > 0)) return;
      if (
        !confirm(
          `Early repay loan #${loanId} for ${formatMoney(
            amount
          )}?\n\nPrincipal only — remaining scheduled interest is waived.`
        )
      ) {
        return;
      }
      btn.disabled = true;
      showCounterMsg("loanRepayMsg", "Processing early repayment…", true);
      const res = await repayClubLoan(supabase, amount, loanId);
      if (res.error) {
        showCounterMsg("loanRepayMsg", res.error, false);
        btn.disabled = false;
        return;
      }
      showCounterMsg(
        "loanRepayMsg",
        `Early repayment received — ${formatMoney(
          res.repaid
        )} principal (remaining interest waived).`,
        true
      );
      await onSuccess();
    });
  });
}

/**
 * @param {import('@supabase/supabase-js').SupabaseClient} supabase
 * @param {object} bank
 * @param {Array} loans
 * @param {() => Promise<void>} onSuccess
 */
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

  paintLimits(bank, loans);
  hideLoanCreditPanels();
  void renderMyLoansAtCounter(supabase, loans).then(() => {
    wireEarlyButtons(supabase, onSuccess);
  });

  // Forms bind once; each refresh still re-paints above
  if (takeForm?.dataset.bound === "1") return;
  if (takeForm) takeForm.dataset.bound = "1";
  if (repayForm) repayForm.dataset.bound = "1";

  const months = 20;

  takeForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const amountInput = document.getElementById("loanAmount");
    const takeBtn = document.getElementById("loanTakeBtn");
    const latest = await loadClubLoans(supabase);
    const bankNow = bank;
    const outstanding = outstandingTotal(latest);
    const headroom = clubLoanHeadroom(bankNow, outstanding);
    const min = Number(bankNow?.loan_min_drawdown || 1000000);
    const maxDraw = Number(bankNow?.loan_max_drawdown || 50000000);
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

    if (takeBtn) takeBtn.disabled = true;
    hideLoanCreditPanels();
    showCounterMsg("loanTakeMsg", "", true);
    showLoanCreditCheckFlash("Running credit check…");
    await sleep(900);
    showLoanCreditCheckFlash("Reviewing club creditworthiness…");

    const credit = await checkClubLoanCredit(supabase);
    if (!credit.ok) {
      await sleep(700);
      if (takeBtn) takeBtn.disabled = false;
      showLoanCreditRejection(credit.message);
      showCounterMsg("loanTakeMsg", "Application declined.", false);
      return;
    }

    showLoanCreditCheckFlash("Credit check clear — processing drawdown…");
    const res = await takeClubLoan(supabase, amt);
    hideLoanCreditPanels();
    if (takeBtn) takeBtn.disabled = false;
    if (res.error) {
      if (/creditworthiness|unfavourable|overdrawn for two seasons/i.test(res.error)) {
        showLoanCreditRejection(res.error);
        showCounterMsg("loanTakeMsg", "Application declined.", false);
        return;
      }
      showCounterMsg("loanTakeMsg", res.error, false);
      return;
    }
    showCounterMsg(
      "loanTakeMsg",
      `Approved — loan #${res.loanId}, ${formatMoney(
        amt
      )} credited. Repay over ${months} GPSL months (interest on top of principal).`,
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
    showCounterMsg(
      "loanRepayMsg",
      `Thank you — ${formatMoney(res.repaid)} principal received.`,
      true
    );
    await onSuccess();
  });

  repayAllBtn?.addEventListener("click", async () => {
    const btn = document.getElementById("loanRepayAllBtn");
    const myLoans = await loadClubLoans(supabase);
    const outstanding = outstandingTotal(myLoans);
    if (outstanding <= 0) return;
    if (
      !confirm(
        `Early settle all loans for ${formatMoney(
          outstanding
        )}?\n\nPrincipal only — remaining scheduled interest is waived.`
      )
    ) {
      return;
    }
    if (btn) btn.disabled = true;
    showCounterMsg("loanRepayMsg", "Processing early settlement…", true);
    const res = await repayClubLoan(supabase, outstanding);
    if (btn) btn.disabled = false;
    if (res.error) {
      showCounterMsg("loanRepayMsg", res.error, false);
      return;
    }
    showCounterMsg(
      "loanRepayMsg",
      `Early settlement complete — ${formatMoney(
        res.repaid
      )} principal (interest waived).`,
      true
    );
    await onSuccess();
  });
}
