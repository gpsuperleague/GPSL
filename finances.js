import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
  loadClubBalance,
  loadFinanceLedger,
  loadClubSeasonArchive,
  loadGpslBankPublic,
  financeEntryLabel,
  isFinanceIncomeEntry,
} from "./competition.js";

function renderLedger(rows) {
  const el = document.getElementById("ledgerTable");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No ledger lines yet. Gates post on confirmed home results; transfers post when deals complete (after central bank SQL is applied).</p>';
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

function renderBreakdown(containerId, buckets, emptyText) {
  const el = document.getElementById(containerId);
  if (!el) return;

  const keys = Object.keys(buckets).sort(
    (a, b) => Math.abs(buckets[b]) - Math.abs(buckets[a])
  );

  if (!keys.length) {
    el.innerHTML = `<p class="empty">${emptyText}</p>`;
    return;
  }

  el.innerHTML = keys
    .map((k) => {
      const amt = buckets[k];
      return `
        <div class="summary-line">
          <span>${financeEntryLabel(k)}</span>
          <span class="amt">${formatMoney(amt)}</span>
        </div>
      `;
    })
    .join("");
}

function summariseLedger(rows) {
  const income = {};
  const costs = {};
  let incomeTotal = 0;
  let costTotal = 0;

  for (const r of rows) {
    const amt = Number(r.amount || 0);
    const type = r.entry_type || "other";
    if (isFinanceIncomeEntry(type, amt)) {
      income[type] = (income[type] || 0) + amt;
      incomeTotal += amt;
    } else {
      costs[type] = (costs[type] || 0) + Math.abs(amt);
      costTotal += Math.abs(amt);
    }
  }

  return { income, costs, incomeTotal, costTotal, net: incomeTotal - costTotal };
}

function renderBankPanel(bank) {
  const el = document.getElementById("bankPanel");
  if (!el) return;

  if (!bank) {
    el.textContent =
      "Central bank not configured yet. Run supabase/sql/central_bank_phase1.sql in Supabase.";
    return;
  }

  el.innerHTML = `
    <strong>${bank.display_name || "GPSL Central Bank"}</strong><br>
    Treasury reserves: <b>${formatMoney(bank.reserves)}</b><br>
    Loan book (outstanding): <b>${formatMoney(bank.loan_book_outstanding)}</b><br>
    Policy interest rate: <b>${Number(bank.policy_interest_rate_pct || 0).toFixed(1)}%</b> per season (when loans launch)
  `;
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
  document.getElementById("balanceAmount").textContent = formatMoney(
    balanceRow?.balance ?? 0
  );

  const ledger = await loadFinanceLedger(supabase, shortName, 200);
  const { income, costs, incomeTotal, costTotal, net } = summariseLedger(ledger);

  document.getElementById("incomeSeasonTotal").textContent =
    formatMoney(incomeTotal);
  document.getElementById("costSeasonTotal").textContent = formatMoney(costTotal);
  const netEl = document.getElementById("netSeasonTotal");
  netEl.textContent = formatMoney(net);
  netEl.className = `value ${net >= 0 ? "positive" : "negative"}`;

  renderBreakdown("incomeBreakdown", income, "No income logged yet.");
  renderBreakdown("costBreakdown", costs, "No costs logged yet.");
  renderLedger(ledger);
  renderBankPanel(await loadGpslBankPublic(supabase));
  renderArchive(await loadClubSeasonArchive(supabase, shortName));
});
