/**
 * Finances page — Excel-style sections and ledger aggregation.
 * Formulas for many lines are not live yet; amounts come from the season ledger where posted.
 */

import { formatMoney, financeEntryLabel, isFinanceIncomeEntry } from "./competition.js";

/** @typedef {{ id: string, label: string, types: string[], planned?: boolean, note?: string }} FinanceLineDef */
/** @typedef {{ id: string, title: string, intro?: string, lines: FinanceLineDef[] }} FinanceSectionDef */

/** Ledger entry_type → section line id (only types that exist or are imminent). */
export const LEDGER_TYPE_TO_LINE = {
  transfer_sale: "transfer_sales",
  transfer_foreign_sale: "transfer_sales",
  transfer_overflow_release: "transfer_sales",
  transfer_purchase: "transfer_purchases",
  transfer_agent_fee: "transfer_purchases",
  gate_league_home: "infra_gates",
  gate_cup_share: "infra_gates",
  prize: "prize_other",
  prize_league: "prize_league",
  prize_cup: "prize_cup",
  prize_challenge: "prize_challenge",
  tv_revenue: "prize_tv",
  infra_maintenance: "infra_maintenance",
  infra_purchase: "infra_purchase",
  infra_expansion: "infra_expansion",
  gov_fine_compensation: "infra_fines",
  gov_hg_subsidy: "gov_hg",
  gov_youth_subsidy: "gov_youth",
  gov_bnb_subsidy: "gov_bnb",
  gov_emergency_tax: "gov_emergency_tax",
  gov_income_tax: "gov_income_tax",
  wage_squad: "upkeep_wages",
  wage_renewal_34plus: "upkeep_34plus",
  wage_star_tax: "upkeep_star_tax",
  staff_manager_salary: "staff_manager",
  contract_signing_offer: "staff_offers",
  contract_release_comp: "staff_release",
  contract_release_comp_received: "staff_release",
  contract_termination: "staff_termination",
  eos_debt_interest: "eos_debt_interest",
  eos_ffp_charge: "eos_ffp",
  eos_injection: "eos_injection",
  admin_one_off_injection: "eos_injection",
  adjustment: "other_adjustment",
  admin_purchase_payment: "other_admin",
};

export const FINANCE_UI_SECTIONS = [
  {
    id: "transfers",
    title: "Player transfers",
    intro:
      "Totals for completed deals this season. Future / delayed fees are not used.",
    lines: [
      {
        id: "transfer_sales",
        label: "Sales",
        types: [
          "transfer_sale",
          "transfer_foreign_sale",
          "transfer_overflow_release",
        ],
        note:
          "All players sold: transfer list, direct offers accepted, foreign sales, squad overflow releases, etc.",
      },
      {
        id: "transfer_purchases",
        label: "Purchases",
        types: ["transfer_purchase", "transfer_agent_fee"],
        note:
          "All players bought: draft auction wins, transfer market, special auctions. Agent fees included.",
      },
    ],
  },
  {
    id: "prizes",
    title: "Prize money & TV",
    intro:
      "League prizes pay after all 38 league matches; cup prizes per round from admin settings; challenge and TV rules TBD.",
    lines: [
      {
        id: "prize_league",
        label: "League prize money",
        types: ["prize_league"],
        planned: true,
        note: "Set in admin and shown on the league table by position; paid once the league season is complete.",
      },
      {
        id: "prize_cup",
        label: "Cup prize money",
        types: ["prize_cup"],
        planned: true,
        note: "Paid after each cup tie, using per-round amounts from admin.",
      },
      {
        id: "prize_challenge",
        label: "Challenge prize money",
        types: ["prize_challenge"],
        planned: true,
        note: "Season targets (start / mid / end). May return — e.g. ₿1M per task, bonus for first to complete all five.",
      },
      {
        id: "prize_tv",
        label: "TV revenue",
        types: ["tv_revenue"],
        planned: true,
        note: "Random big-match allocation; top of table weighted higher than mid / bottom (~₿1M per TV match historically).",
      },
      {
        id: "prize_other",
        label: "Prize money (posted)",
        types: ["prize"],
        note: "Generic prize lines until split into league / cup / challenge / TV.",
      },
    ],
  },
  {
    id: "infrastructure",
    title: "Infrastructure",
    intro:
      "Stadium gates, upkeep, starting stadium premium, expansions, and discipline fines.",
    lines: [
      {
        id: "infra_gates",
        label: "Gate receipts",
        types: ["gate_league_home", "gate_cup_share"],
        note:
          "League home 100% / away 0%; cup 50/50. Per match: capacity × ₿20; grows as results are confirmed.",
      },
      {
        id: "infra_maintenance",
        label: "Stadium maintenance",
        types: ["infra_maintenance"],
        planned: true,
        note: "12.5% of stadium value per season; value = capacity × ₿1,500.",
      },
      {
        id: "infra_purchase",
        label: "Infrastructure purchases",
        types: ["infra_purchase"],
        planned: true,
        note: "Starting-budget premium for clubs that begin with larger stadiums.",
      },
      {
        id: "infra_expansion",
        label: "Expansions",
        types: ["infra_expansion"],
        planned: true,
        note: "Capacity upgrade costs — formula to be restored.",
      },
      {
        id: "infra_fines",
        label: "Fines & compensation",
        types: ["gov_fine_compensation"],
        planned: true,
        note: "DOGSO, time wasting, and other offences — tariff list to follow.",
      },
    ],
  },
  {
    id: "government",
    title: "Government",
    intro: "Subsidies and taxes; emergency tax and income tax % from admin.",
    lines: [
      {
        id: "gov_hg",
        label: "Homegrown (HG) subsidy",
        types: ["gov_hg_subsidy"],
        planned: true,
        note: "Tiered by homegrown levels in squad (e.g. flying the flag) — rules to follow.",
      },
      {
        id: "gov_youth",
        label: "Youth subsidy",
        types: ["gov_youth_subsidy"],
        planned: true,
        note: "Payout scales with youth players in the squad.",
      },
      {
        id: "gov_bnb",
        label: "Built not bought",
        types: ["gov_bnb_subsidy"],
        planned: true,
        note: "₿10M-style support for weaker squads — formula to follow.",
      },
      {
        id: "gov_emergency_tax",
        label: "Emergency tax",
        types: ["gov_emergency_tax"],
        planned: true,
        note: "Admin-controlled levy if clubs hold too much cash.",
      },
      {
        id: "gov_income_tax",
        label: "Income tax",
        types: ["gov_income_tax"],
        planned: true,
        note: "Percentage of player spend; rate set in admin.",
      },
    ],
  },
  {
    id: "upkeep",
    title: "Player upkeep",
    intro: "Wages from admin % of value; individual wages; 34+ and star tax.",
    lines: [
      {
        id: "upkeep_wages",
        label: "Wages",
        types: ["wage_squad"],
        planned: true,
        note:
          "Admin % of squad value; per-player wage from calculated value, or negotiated wage after free-agent path.",
      },
      {
        id: "upkeep_34plus",
        label: "34+ renewals",
        types: ["wage_renewal_34plus"],
        planned: true,
        note: "Per-player seasonal fee for players aged 34+.",
      },
      {
        id: "upkeep_star_tax",
        label: "Star tax",
        types: ["wage_star_tax"],
        planned: true,
        note: "Surcharge for 70+ rated players — formula to follow.",
      },
    ],
  },
  {
    id: "staff",
    title: "Staff",
    intro: "Manager salary, renewals, releases, and mid-season termination.",
    lines: [
      {
        id: "staff_manager",
        label: "Manager salary",
        types: ["staff_manager_salary"],
        planned: true,
        note: "From manager rating → value → salary %.",
      },
      {
        id: "staff_offers",
        label: "Contract offers",
        types: ["contract_signing_offer"],
        planned: true,
        note: "Renewal fee every two seasons.",
      },
      {
        id: "staff_release",
        label: "Contract releases",
        types: ["contract_release_comp", "contract_release_comp_received"],
        planned: true,
        note: "Failed objectives / resignation / sacking; fee may return; manager cannot rejoin same club.",
      },
      {
        id: "staff_termination",
        label: "Contract termination",
        types: ["contract_termination"],
        planned: true,
        note: "Club fires manager mid-season or at season end.",
      },
    ],
  },
  {
    id: "eos",
    title: "End of season",
    intro: "Debt interest, FFP, and admin injections (individual or league-wide).",
    lines: [
      {
        id: "eos_debt_interest",
        label: "Debt interest",
        types: ["eos_debt_interest", "loan_interest_payment"],
        planned: true,
        note: "Charged on negative balances at season end (and loan interest when live).",
      },
      {
        id: "eos_ffp",
        label: "FFP charges",
        types: ["eos_ffp_charge"],
        planned: true,
        note: "Fine if debt exceeded ₿99M at any point in the season.",
      },
      {
        id: "eos_injection",
        label: "End of season injection",
        types: ["eos_injection", "admin_one_off_injection"],
        note: "Boost for struggling clubs; also one-off central bank credits.",
      },
    ],
  },
  {
    id: "other",
    title: "Other",
    lines: [
      {
        id: "other_adjustment",
        label: "Adjustments",
        types: ["adjustment"],
      },
      {
        id: "other_admin",
        label: "Admin purchase payment",
        types: ["admin_purchase_payment"],
      },
      {
        id: "other_loans",
        label: "Loans",
        types: [
          "loan_drawdown",
          "loan_repayment_principal",
          "loan_interest_payment",
        ],
        planned: true,
      },
    ],
  },
];

/**
 * @param {Array<{ entry_type?: string, amount?: number }>} rows
 * @returns {Map<string, { amount: number, detail: Record<string, number> }>}
 */
export function aggregateLedgerByLine(rows) {
  const byLine = new Map();

  const ensure = (id) => {
    if (!byLine.has(id)) byLine.set(id, { amount: 0, detail: {} });
    return byLine.get(id);
  };

  for (const r of rows) {
    const type = r.entry_type || "other";
    const amt = Number(r.amount || 0);
    const lineId = LEDGER_TYPE_TO_LINE[type];
    if (!lineId) {
      const bucket = ensure("_unmapped");
      bucket.amount += amt;
      bucket.detail[type] = (bucket.detail[type] || 0) + amt;
      continue;
    }
    const bucket = ensure(lineId);
    bucket.amount += amt;
    bucket.detail[type] = (bucket.detail[type] || 0) + amt;
  }

  return byLine;
}

export function summariseLedgerTotals(rows) {
  let incomeTotal = 0;
  let costTotal = 0;

  for (const r of rows) {
    const amt = Number(r.amount || 0);
    if (isFinanceIncomeEntry(r.entry_type, amt)) incomeTotal += amt;
    else costTotal += Math.abs(amt);
  }

  return {
    incomeTotal,
    costTotal,
    net: incomeTotal - costTotal,
  };
}

function formatLineAmount(amount, hasData, planned) {
  if (!hasData && planned) {
    return '<span class="amt planned">—</span>';
  }
  if (!hasData) return '<span class="amt zero">₿ 0</span>';
  const n = Number(amount);
  const cls = n >= 0 ? "income-amt" : "cost-amt";
  const sign = n >= 0 ? "+" : "−";
  return `<span class="amt ${cls}">${sign}${formatMoney(Math.abs(n))}</span>`;
}

/**
 * @param {Map<string, { amount: number, detail: Record<string, number> }>} byLine
 */
export function renderFinanceSections(byLine) {
  const parts = [];

  for (const section of FINANCE_UI_SECTIONS) {
    let sectionNet = 0;
    const lineHtml = section.lines
      .map((line) => {
        const bucket = byLine.get(line.id);
        const hasData = bucket && Math.abs(bucket.amount) > 0.001;
        const planned = line.planned && !hasData;
        if (hasData) sectionNet += bucket.amount;

        const detail =
          hasData && bucket.detail
            ? Object.entries(bucket.detail)
                .filter(([, v]) => Math.abs(v) > 0.001)
                .map(
                  ([t, v]) =>
                    `<div class="detail-line"><span>${financeEntryLabel(t)}</span><span>${formatMoney(Math.abs(v))}</span></div>`
                )
                .join("")
            : "";

        return `
          <div class="fin-line ${planned ? "planned-line" : ""}">
            <div class="fin-line-head">
              <span class="fin-line-label">${line.label}</span>
              ${formatLineAmount(bucket?.amount ?? 0, hasData, line.planned)}
            </div>
            ${line.note ? `<p class="fin-line-note">${line.note}</p>` : ""}
            ${detail ? `<div class="fin-line-detail">${detail}</div>` : ""}
          </div>
        `;
      })
      .join("");

    parts.push(`
      <section class="fin-section" id="fin-${section.id}">
        <h3>${section.title}</h3>
        ${section.intro ? `<p class="fin-section-intro">${section.intro}</p>` : ""}
        ${lineHtml}
        <div class="fin-section-total">
          <span>Section net (posted)</span>
          <span class="amt ${sectionNet >= 0 ? "income-amt" : "cost-amt"}">${sectionNet >= 0 ? "+" : "−"}${formatMoney(Math.abs(sectionNet))}</span>
        </div>
      </section>
    `);
  }

  const unmapped = byLine.get("_unmapped");
  if (unmapped && Math.abs(unmapped.amount) > 0.001) {
    parts.push(`
      <section class="fin-section" id="fin-unmapped">
        <h3>Unmapped ledger</h3>
        <div class="fin-line">
          <div class="fin-line-head">
            <span class="fin-line-label">Other posted types</span>
            <span class="amt">${formatMoney(unmapped.amount)}</span>
          </div>
        </div>
      </section>
    `);
  }

  return parts.join("");
}
