import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

export { supabase, formatMoney };

export const BANK_SUBNAV = [
  { href: "central_bank.html", label: "Bank balance", page: "central_bank" },
  { href: "central_bank_loans.html", label: "League loans", page: "central_bank_loans" },
  { href: "central_bank_counter.html", label: "Service counter", page: "central_bank_counter" },
];

export function renderBankSubnav(activePage) {
  const el = document.getElementById("bankSubnav");
  if (!el) return;

  el.innerHTML = BANK_SUBNAV.map(
    (item) =>
      `<a href="${item.href}" class="${item.page === activePage ? "active" : ""}">${item.label}</a>`
  ).join("") + `<a href="finances.html">Your club finances</a>`;
}

export function renderHeroStats(bank) {
  const el = document.getElementById("heroStats");
  if (!el || !bank) {
    if (el) el.innerHTML = "<p class='bank-empty'>Bank not configured — run central bank SQL in Supabase.</p>";
    return;
  }

  el.innerHTML = `
    <div class="bank-stat">
      <div class="label">Treasury reserves</div>
      <div class="value">${formatMoney(bank.reserves)}</div>
    </div>
    <div class="bank-stat">
      <div class="label">Loan book</div>
      <div class="value">${formatMoney(bank.loan_book_outstanding)}</div>
    </div>
    <div class="bank-stat">
      <div class="label">Interest rate</div>
      <div class="value">${Number(bank.policy_interest_rate_pct || 0).toFixed(1)}%</div>
    </div>
  `;
}

export function renderTreasurySummary(bank) {
  const el = document.getElementById("treasurySummary");
  if (!el || !bank) return;

  el.innerHTML = `
    <div class="bank-stat">
      <div class="label">Reserves</div>
      <div class="value">${formatMoney(bank.reserves)}</div>
    </div>
    <div class="bank-stat">
      <div class="label">Outstanding loans</div>
      <div class="value">${formatMoney(bank.loan_book_outstanding)}</div>
    </div>
    <div class="bank-stat">
      <div class="label">Loans</div>
      <div class="value">${bank.loans_enabled === false ? "Closed" : "Open"}</div>
    </div>
    <div class="bank-stat">
      <div class="label">Per-club cap</div>
      <div class="value">${formatMoney(bank.loan_max_outstanding_per_club)}</div>
    </div>
  `;
}

export function summariseBankLedger(rows) {
  let income = 0;
  let expenditure = 0;
  for (const r of rows) {
    const amt = Number(r.amount || 0);
    if (amt > 0) income += amt;
    else expenditure += Math.abs(amt);
  }
  return { income, expenditure };
}

export function renderBankLedger(rows, financeEntryLabel) {
  const incomeEl = document.getElementById("bankIncomeTotal");
  const costEl = document.getElementById("bankCostTotal");
  const tableEl = document.getElementById("bankLedgerTable");

  const { income, expenditure } = summariseBankLedger(rows);
  if (incomeEl) incomeEl.textContent = formatMoney(income);
  if (costEl) costEl.textContent = formatMoney(expenditure);

  if (!tableEl) return;

  if (!rows.length) {
    tableEl.innerHTML =
      "<p class='bank-empty'>No bank ledger entries yet. Loan drawdowns and repayments appear here.</p>";
    return;
  }

  const body = rows
    .map((r) => {
      const amt = Number(r.amount || 0);
      const isIn = amt > 0;
      const club = r.club_name || r.club_short_name || "—";
      return `
        <tr>
          <td>${new Date(r.created_at).toLocaleString("en-GB")}</td>
          <td>${financeEntryLabel(r.entry_type)}</td>
          <td>${club}</td>
          <td class="${isIn ? "money-in" : "money-out"}">${isIn ? "+" : "−"}${formatMoney(Math.abs(amt))}</td>
          <td>${r.description || ""}</td>
        </tr>`;
    })
    .join("");

  tableEl.innerHTML = `
    <table class="bank-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Type</th>
          <th>Club</th>
          <th>Amount</th>
          <th>Detail</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

export function renderLeagueLoans(rows, myShortName) {
  const el = document.getElementById("leagueLoansTable");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML = "<p class='bank-empty'>No loans on record.</p>";
    return;
  }

  const sorted = [...rows].sort((a, b) => {
    const sa = a.status === "active" ? 0 : 1;
    const sb = b.status === "active" ? 0 : 1;
    if (sa !== sb) return sa - sb;
    return Number(b.outstanding_principal) - Number(a.outstanding_principal);
  });

  el.innerHTML = `
    <table class="bank-table">
      <thead>
        <tr>
          <th>Club</th>
          <th>Loan</th>
          <th>Status</th>
          <th>Drawn</th>
          <th>Principal left</th>
          <th>Interest (full term)</th>
          <th>Interest left</th>
          <th>Term</th>
          <th>Rate</th>
          <th>From</th>
        </tr>
      </thead>
      <tbody>
        ${sorted
          .map((l) => {
            const mine = l.club_short_name === myShortName;
            const statusCls =
              l.status === "active" ? "status-active" : "status-paid";
            const interestTotal = Number(
              l.interest_total_scheduled ?? l.interest_total ?? 0
            );
            const interestLeft = Number(l.interest_remaining ?? 0);
            const fromLabel =
              l.drawdown_gpsl_month_label ||
              l.drawdown_gpsl_month ||
              new Date(l.created_at).toLocaleDateString("en-GB");
            return `
          <tr class="${mine ? "row-mine" : ""}">
            <td>${l.club_name || l.club_short_name}${mine ? " <em>(you)</em>" : ""}</td>
            <td>#${l.id}</td>
            <td class="${statusCls}">${l.status}</td>
            <td>${formatMoney(l.principal_drawn)}</td>
            <td class="owing">${
              l.status === "active"
                ? formatMoney(l.outstanding_principal)
                : "—"
            }</td>
            <td>${formatMoney(interestTotal)}</td>
            <td>${
              l.status === "active" ? formatMoney(interestLeft) : "—"
            }</td>
            <td>${l.repayment_months || 20} mo</td>
            <td>${Number(l.interest_rate_pct || 0).toFixed(1)}%</td>
            <td>${fromLabel}</td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;
}

export function setBankTagline(club) {
  const shortName = club?.ShortName || null;
  const fullName = shortName ? fullClubName(shortName) || club.Club : null;
  const tagline = document.getElementById("bankTagline");
  if (tagline) {
    tagline.textContent = fullName
      ? `Serving ${fullName} and the league`
      : "League treasury · Loans · Settlement";
  }
  return { shortName, fullName };
}

export async function initBankPage() {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return null;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  await loadClubsMap();
  const { shortName, fullName } = setBankTagline(club);
  return { user, club, shortName, fullName };
}
