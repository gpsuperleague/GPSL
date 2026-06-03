import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
  loadClubBalance,
  loadFinanceLedger,
  loadClubSeasonArchive,
  loadGpslBankPublic,
  loadClubLoans,
  takeClubLoan,
  repayClubLoan,
  clubLoanHeadroom,
  financeEntryLabel,
  isFinanceIncomeEntry,
} from "./competition.js";
import {
  aggregateLedgerByLine,
  renderFinanceSections,
  summariseLedgerTotals,
} from "./finance_ui.js";

function renderLedger(rows) {
  const el = document.getElementById("ledgerTable");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No ledger lines yet for this club. Gates post on confirmed results; transfers post when deals complete.</p>';
    return;
  }

  const body = rows
    .map((r) => {
      const md = r.matchday ? `MD${r.matchday}` : "—";
      const fixture =
        r.home_club_short_name && r.away_club_short_name
          ? `${r.home_club_short_name} vs ${r.away_club_short_name}`
          : "—";
      const income = isFinanceIncomeEntry(r.entry_type, r.amount);
      const rowClass = income ? "income" : "cost";
      const sign = Number(r.amount) >= 0 ? "+" : "";

      return `
        <tr class="${rowClass}">
          <td>${new Date(r.created_at).toLocaleString("en-GB")}</td>
          <td>${financeEntryLabel(r.entry_type)}</td>
          <td>${md}</td>
          <td>${fixture}</td>
          <td class="money">${sign}${formatMoney(Math.abs(r.amount))}</td>
          <td>${r.description || ""}</td>
        </tr>
      `;
    })
    .join("");

  el.innerHTML = `
    <table class="fin-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Type</th>
          <th>MD</th>
          <th>Fixture</th>
          <th>Amount</th>
          <th>Detail</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

function renderBankPanel(bank, loanState) {
  const el = document.getElementById("bankPanel");
  if (!el) return;

  if (!bank) {
    el.textContent =
      "Central bank not configured yet. Run supabase/sql/central_bank_phase1.sql in Supabase.";
    return;
  }

  const { outstanding, headroom } = loanState;
  const loansOn = bank.loans_enabled !== false;

  el.innerHTML = `
    <strong>${bank.display_name || "GPSL Central Bank"}</strong><br>
    Treasury reserves: <b>${formatMoney(bank.reserves)}</b><br>
    League loan book: <b>${formatMoney(bank.loan_book_outstanding)}</b><br>
    Policy interest: <b>${Number(bank.policy_interest_rate_pct || 0).toFixed(1)}%</b> per season on outstanding principal (EOS charge — coming)<br>
    ${
      loansOn
        ? `Your outstanding loans: <b>${formatMoney(outstanding)}</b> · Available to borrow: <b>${formatMoney(headroom)}</b>`
        : "<em>Loans are currently disabled.</em>"
    }
  `;
}

function renderLoanList(loans) {
  const el = document.getElementById("loanList");
  if (!el) return;

  const active = loans.filter((l) => l.status === "active");
  if (!active.length) {
    el.innerHTML = '<p class="empty">No active loans.</p>';
    return;
  }

  el.innerHTML = `
    <table class="loan-table">
      <thead>
        <tr>
          <th>Loan</th>
          <th>Drawn</th>
          <th>Owing</th>
          <th>Rate</th>
          <th>Since</th>
        </tr>
      </thead>
      <tbody>
        ${active
          .map(
            (l) => `
          <tr>
            <td>#${l.id}</td>
            <td>${formatMoney(l.principal_drawn)}</td>
            <td>${formatMoney(l.outstanding_principal)}</td>
            <td>${Number(l.interest_rate_pct).toFixed(1)}%</td>
            <td>${new Date(l.created_at).toLocaleDateString("en-GB")}</td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>
  `;
}

function fillRepayLoanSelect(loans) {
  const sel = document.getElementById("repayLoanId");
  if (!sel) return;

  const active = loans.filter((l) => l.status === "active");
  sel.innerHTML =
    '<option value="">Oldest active loan</option>' +
    active
      .map(
        (l) =>
          `<option value="${l.id}">#${l.id} — owe ${formatMoney(l.outstanding_principal)}</option>`
      )
      .join("");
}

function setupLoanForms(bank, loans, shortName, reload) {
  const panel = document.getElementById("loanPanel");
  const disabledNote = document.getElementById("loanDisabledNote");
  const limitsEl = document.getElementById("loanLimits");
  const takeForm = document.getElementById("loanTakeForm");
  const repayForm = document.getElementById("loanRepayForm");
  const repayAllBtn = document.getElementById("loanRepayAllBtn");

  if (!bank?.loans_enabled) {
    panel?.setAttribute("hidden", "");
    disabledNote?.removeAttribute("hidden");
    return;
  }

  disabledNote?.setAttribute("hidden", "");
  panel?.removeAttribute("hidden");

  const outstanding = loans
    .filter((l) => l.status === "active")
    .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
  const headroom = clubLoanHeadroom(bank, outstanding);

  const min = Number(bank.loan_min_drawdown || 1000000);
  const maxDraw = Number(bank.loan_max_drawdown || 50000000);
  const effectiveMax = Math.min(maxDraw, headroom);

  if (limitsEl) {
    limitsEl.textContent = `Min ${formatMoney(min)} per draw · Max ${formatMoney(
      maxDraw
    )} per draw · Club cap ${formatMoney(bank.loan_max_outstanding_per_club)}`;
  }

  const amountInput = document.getElementById("loanAmount");
  if (amountInput) {
    amountInput.min = String(min);
    amountInput.max = effectiveMax > 0 ? String(effectiveMax) : String(min);
    if (!amountInput.value) amountInput.value = String(min);
  }

  const takeBtn = document.getElementById("loanTakeBtn");
  if (takeBtn) takeBtn.disabled = effectiveMax < min;

  const repayBtn = document.getElementById("loanRepayBtn");
  const repayAll = document.getElementById("loanRepayAllBtn");
  const canRepay = outstanding > 0;
  if (repayBtn) repayBtn.disabled = !canRepay;
  if (repayAll) repayAll.disabled = !canRepay;

  const showMsg = (id, text, ok) => {
    const m = document.getElementById(id);
    if (!m) return;
    m.textContent = text;
    m.className = `loan-msg ${ok ? "ok" : "err"}`;
  };

  takeForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const amt = Number(amountInput?.value);
    if (!Number.isFinite(amt) || amt < min) {
      showMsg("loanTakeMsg", `Enter at least ${formatMoney(min)}.`, false);
      return;
    }
    if (amt > effectiveMax) {
      showMsg(
        "loanTakeMsg",
        `Maximum available is ${formatMoney(effectiveMax)}.`,
        false
      );
      return;
    }

    takeBtn.disabled = true;
    showMsg("loanTakeMsg", "Processing…", true);
    const res = await takeClubLoan(supabase, amt);
    takeBtn.disabled = false;

    if (res.error) {
      showMsg("loanTakeMsg", res.error, false);
      return;
    }
    showMsg(
      "loanTakeMsg",
      `Loan #${res.loanId} approved — ${formatMoney(amt)} credited.`,
      true
    );
    await reload(shortName);
  });

  repayForm?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const amt = Number(document.getElementById("repayAmount")?.value);
    const loanIdRaw = document.getElementById("repayLoanId")?.value;
    const loanId = loanIdRaw ? Number(loanIdRaw) : null;

    if (!Number.isFinite(amt) || amt <= 0) {
      showMsg("loanRepayMsg", "Enter a repayment amount.", false);
      return;
    }

    const btn = document.getElementById("loanRepayBtn");
    btn.disabled = true;
    showMsg("loanRepayMsg", "Processing…", true);
    const res = await repayClubLoan(supabase, amt, loanId);
    btn.disabled = false;

    if (res.error) {
      showMsg("loanRepayMsg", res.error, false);
      return;
    }
    showMsg("loanRepayMsg", `Repaid ${formatMoney(res.repaid)}.`, true);
    await reload(shortName);
  });

  repayAllBtn?.addEventListener("click", async () => {
    if (outstanding <= 0) {
      showMsg("loanRepayMsg", "No outstanding loan.", false);
      return;
    }
    repayAllBtn.disabled = true;
    const res = await repayClubLoan(supabase, outstanding);
    repayAllBtn.disabled = false;
    if (res.error) {
      showMsg("loanRepayMsg", res.error, false);
      return;
    }
    showMsg("loanRepayMsg", `Repaid ${formatMoney(res.repaid)} in full.`, true);
    await reload(shortName);
  });
}

function renderArchive(rows) {
  const el = document.getElementById("archiveList");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No archived seasons — gate history uses a neutral mid-table boost until rows are added.</p>';
    return;
  }

  el.innerHTML = `
    <ul class="archive-ul">
      ${rows
        .map(
          (r) =>
            `<li><b>${r.season_label}</b> — ${r.division}, finished <b>${r.final_position}</b></li>`
        )
        .join("")}
    </ul>
  `;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent =
      "No club linked — assign owner in GPSL Admin.";
    return;
  }

  await loadClubsMap();
  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club;

  document.getElementById("pageTitle").textContent = `${fullName} — Finances`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  const balanceRow = await loadClubBalance(supabase, shortName);
  const balance = balanceRow?.balance ?? 0;
  document.getElementById("balanceAmount").textContent = formatMoney(balance);

  document.getElementById("openingBalance").textContent = "Soon";
  document.getElementById("openingBalance").title =
    "Season opening balance will be stored when season rollover is wired.";
  document.getElementById("predictedBalance").textContent = "Soon";
  document.getElementById("predictedBalance").title =
    "Forecast of all remaining income and costs through season end.";

  const ledger = await loadFinanceLedger(supabase, shortName, 300);
  const { incomeTotal, costTotal, net } = summariseLedgerTotals(ledger);

  document.getElementById("incomeSeasonTotal").textContent =
    formatMoney(incomeTotal);
  document.getElementById("costSeasonTotal").textContent = formatMoney(costTotal);
  const netEl = document.getElementById("netSeasonTotal");
  netEl.textContent = formatMoney(net);
  netEl.className = `value ${net >= 0 ? "positive" : "negative"}`;

  const sectionsEl = document.getElementById("financeSections");
  if (sectionsEl) {
    sectionsEl.innerHTML = renderFinanceSections(aggregateLedgerByLine(ledger));
  }

  renderLedger(ledger);

  const reload = async (club) => {
    const balanceRow = await loadClubBalance(supabase, club);
    document.getElementById("balanceAmount").textContent = formatMoney(
      balanceRow?.balance ?? 0
    );
    const ledgerFresh = await loadFinanceLedger(supabase, club, 300);
    const totals = summariseLedgerTotals(ledgerFresh);
    document.getElementById("incomeSeasonTotal").textContent = formatMoney(
      totals.incomeTotal
    );
    document.getElementById("costSeasonTotal").textContent = formatMoney(
      totals.costTotal
    );
    const netEl = document.getElementById("netSeasonTotal");
    netEl.textContent = formatMoney(totals.net);
    netEl.className = `value ${totals.net >= 0 ? "positive" : "negative"}`;
    const sectionsEl = document.getElementById("financeSections");
    if (sectionsEl) {
      sectionsEl.innerHTML = renderFinanceSections(
        aggregateLedgerByLine(ledgerFresh)
      );
    }
    renderLedger(ledgerFresh);

    const bank = await loadGpslBankPublic(supabase);
    const loans = await loadClubLoans(supabase);
    const outstanding = loans
      .filter((l) => l.status === "active")
      .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);
    renderBankPanel(bank, {
      outstanding,
      headroom: clubLoanHeadroom(bank, outstanding),
    });
    renderLoanList(loans);
    fillRepayLoanSelect(loans);
  };

  const bank = await loadGpslBankPublic(supabase);
  const loans = await loadClubLoans(supabase);
  const outstanding = loans
    .filter((l) => l.status === "active")
    .reduce((s, l) => s + Number(l.outstanding_principal || 0), 0);

  renderBankPanel(bank, {
    outstanding,
    headroom: clubLoanHeadroom(bank, outstanding),
  });
  renderLoanList(loans);
  fillRepayLoanSelect(loans);
  setupLoanForms(bank, loans, shortName, reload);

  renderArchive(await loadClubSeasonArchive(supabase, shortName));
});
