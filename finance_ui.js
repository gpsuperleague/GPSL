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
  new_owner_release: "transfer_sales",
  special_auction_fee: "transfer_purchases",
  special_auction_prize: "prize_other",
  transfer_purchase: "transfer_purchases",
  transfer_agent_fee: "transfer_purchases",
  gate_league_home: "infra_gates",
  gate_cup_share: "infra_gates",
  gate_friendlies: "infra_gates",
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
  medical_doctor_hire: "staff_medical",
  medical_physio_hire: "staff_medical",
  contract_signing_offer: "staff_offers",
  contract_release_comp: "staff_release",
  contract_release_comp_received: "staff_release",
  contract_termination: "staff_termination",
  eos_debt_interest: "eos_debt_interest",
  eos_ffp_charge: "eos_ffp",
  eos_balance_interest: "eos_balance_interest",
  eos_injection: "eos_injection",
  admin_one_off_injection: "eos_injection",
  adjustment: "other_adjustment",
  admin_purchase_payment: "other_admin",
  loan_drawdown: "loan_drawdowns",
  loan_repayment_principal: "loan_repayments",
  loan_interest_payment: "loan_interest",
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
          "new_owner_release",
        ],
        note:
          "All players sold: transfer list, direct offers accepted, foreign sales, squad overflow releases, New Owner release refunds, etc.",
      },
      {
        id: "transfer_purchases",
        label: "Purchases",
        types: ["transfer_purchase", "transfer_agent_fee", "special_auction_fee"],
        note:
          "All players bought: draft auction wins, transfer market, special auction fees. Agent fees included. Winning draft bids show as pending until outbid or settled.",
      },
    ],
  },
  {
    id: "prizes",
    title: "Prize money & TV",
    intro:
      "League prizes pay after all 38 league matches; cup prizes per round; TV revenue on selected league and cup fixtures (80% home / 20% away).",
    lines: [
      {
        id: "prize_league",
        label: "League prize money",
        types: ["prize_league"],
        note: "Set in admin (League Prize Money) and shown on the league table; paid when all 38 league matches in your division are complete.",
      },
      {
        id: "prize_cup",
        label: "Cup prize money",
        types: ["prize_cup"],
        note: "Paid to both clubs after each confirmed cup tie (same round fee). Admin override for walkovers.",
      },
      {
        id: "prize_challenge",
        label: "Challenge prize money",
        types: ["prize_challenge"],
        note: "Instant award when your club hits an admin target; bonus for first to complete all in a window.",
      },
      {
        id: "prize_tv",
        label: "TV revenue",
        types: ["tv_revenue"],
        note: "Up to 5 league + cup matches per division per month; 80% home / 20% away when played. Selects automatically when each GPSL month locks.",
      },
      {
        id: "prize_other",
        label: "Prize money (posted)",
        types: ["prize", "special_auction_prize"],
        note: "Generic prize lines, special auction cash prizes, etc.",
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
        types: ["gate_league_home", "gate_cup_share", "gate_friendlies"],
        note:
          "League home 100% / away 0%; cup 50/50; Discord friendlies ₿5,000 each (mutual confirm, monthly/season caps).",
      },
      {
        id: "infra_maintenance",
        label: "Stadium maintenance",
        types: ["infra_maintenance"],
        note: "Posted at Close Finances — 12.5% of stadium value (capacity × ₿1,500).",
      },
      {
        id: "infra_purchase",
        label: "Infrastructure purchases",
        types: ["infra_purchase"],
        note: "Stadium purchase at club assignment — capacity × ₿1,000 (club auction win or admin assign).",
      },
      {
        id: "infra_expansion",
        label: "Expansions",
        types: ["infra_expansion", "infra_expansion_refund", "infra_expansion_penalty"],
        planned: true,
        note: "Capacity upgrade — tiered cost per seat (Stadium page).",
      },
      {
        id: "infra_fines",
        label: "Fines & compensation",
        types: ["gov_fine_compensation"],
        note: "Instant admin fines (debit) and compensation (credit) from tariff catalogue.",
      },
    ],
  },
  {
    id: "government",
    title: "Government",
    intro: "Subsidies and taxes; emergency tax and income tax % from Bills & Income admin.",
    lines: [
      {
        id: "gov_hg",
        label: "Homegrown (HG) subsidy",
        types: ["gov_hg_subsidy"],
        note: "Quota / Flying the flag / National pride — paid at season end when all league divisions complete.",
      },
      {
        id: "gov_youth",
        label: "Youth subsidy",
        types: ["gov_youth_subsidy"],
        note: "Grassroots → Centre of excellence by under-21 count — paid at season end.",
      },
      {
        id: "gov_bnb",
        label: "Weak squad bonus",
        types: ["gov_bnb_subsidy"],
        note: "14+ squad players rated ≤72 qualify for a flat ₿10M bonus at season end.",
      },
      {
        id: "gov_emergency_tax",
        label: "Emergency tax",
        types: ["gov_emergency_tax"],
        note: "Admin set-amount levy or season-end % above threshold — Admin → Season Management → Charge Emergency Tax.",
      },
      {
        id: "gov_income_tax",
        label: "Income tax",
        types: ["gov_income_tax"],
        note:
          "League % on player purchases (transfer fee + agent fee, special auction fees). Rate: Admin → Season Break → Bills & Income → Tax %.",
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
        note: "Season squad wage bill (sum of contract wages) — admin Post season wage bills.",
      },
      {
        id: "upkeep_34plus",
        label: "34+ rating fee",
        types: ["wage_renewal_34plus"],
        note: "Per-player fee for squad players at or above admin min rating (default 34).",
      },
      {
        id: "upkeep_star_tax",
        label: "Star tax",
        types: ["wage_star_tax"],
        note: "Per-player fee for squad players at or above admin star rating (default 70).",
      },
    ],
  },
  {
    id: "staff",
    title: "Staff",
    intro: "Manager salary, medical hires, renewals, releases, and mid-season termination.",
    lines: [
      {
        id: "staff_manager",
        label: "Manager salary",
        types: ["staff_manager_salary"],
        note: "Season manager salary (weekly wage × 52) — posted with admin Close Finances / Post season wage bills.",
      },
      {
        id: "staff_medical",
        label: "Medical hires",
        types: ["medical_doctor_hire", "medical_physio_hire"],
        note: "Club doctor and physio hiring fees from the Medical Room.",
      },
      {
        id: "staff_offers",
        label: "Contract offers",
        types: ["contract_signing_offer"],
        note: "Manager signing fees (draft, market, admin assign) and renewal fees every two seasons.",
      },
      {
        id: "staff_release",
        label: "Contract releases",
        types: ["contract_release_comp", "contract_release_comp_received"],
        note: "Player contract buy-outs (wage × seasons remaining) and other release debits.",
      },
      {
        id: "staff_termination",
        label: "Contract termination",
        types: ["contract_termination"],
        note: "Manager sack (January, half market value credit) and other termination payouts.",
      },
    ],
  },
  {
    id: "eos",
    title: "End of season",
    intro: "Debt interest, FFP, balance interest, and admin cash injections.",
    lines: [
      {
        id: "eos_debt_interest",
        label: "Debt interest",
        types: ["eos_debt_interest", "loan_interest_payment"],
        note: "Charged on negative balances at season end via Close Finances (bank rate).",
      },
      {
        id: "eos_ffp",
        label: "FFP charges",
        types: ["eos_ffp_charge"],
        note: "Flat fine if balance ≤ −₿100M at Close Finances (after debt interest).",
      },
      {
        id: "eos_balance_interest",
        label: "Balance interest",
        types: ["eos_balance_interest"],
        note: "0.5% credit on positive balances at Close Finances (paid by central bank).",
      },
      {
        id: "eos_injection",
        label: "End of season injection",
        types: ["eos_injection", "admin_one_off_injection"],
        note: "Admin cash injection (Season Management → Inject cash) and other one-off central bank credits.",
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
    ],
  },
  {
    id: "loans",
    title: "Central Bank loans",
    intro:
      "This season’s payments only. Full terms / remaining interest: Central Bank → Service counter.",
    lines: [
      {
        id: "loan_drawdowns",
        label: "Loan drawdowns",
        types: ["loan_drawdown"],
        note: "Borrowed this season at the service counter.",
      },
      {
        id: "loan_repayments",
        label: "Loan repayments (principal)",
        types: ["loan_repayment_principal"],
        note: "Principal paid this season (usually ~10 instalments Aug–May per loan).",
      },
      {
        id: "loan_interest",
        label: "Loan interest payments",
        types: ["loan_interest_payment"],
        note: "Interest on this season’s instalments (set at drawdown).",
      },
    ],
  },
];

const LOAN_LEDGER_TYPES = new Set([
  "loan_drawdown",
  "loan_repayment_principal",
  "loan_interest_payment",
]);

const LOAN_LINE_IDS = new Set(["loan_drawdowns", "loan_repayments", "loan_interest"]);

const MONTH_SHORT = {
  january: "Jan",
  february: "Feb",
  march: "Mar",
  april: "Apr",
  may: "May",
  june: "Jun",
  july: "Jul",
  august: "Aug",
  september: "Sep",
  october: "Oct",
  november: "Nov",
  december: "Dec",
};

/** Compact loan breakdown: "Aug · #12 · 3/20" instead of long scheduled descriptions. */
function compactLoanBreakdownLabel(row) {
  const type = row.entry_type || "other";
  const md = parseMetadata(row.metadata);
  let desc = String(row.description || "")
    .replace(/\s*\[Season 1 accounts backfill\]/gi, "")
    .trim();

  if (!desc && md.loan_id != null) {
    const kind =
      type === "loan_drawdown"
        ? "Drawdown"
        : type === "loan_interest_payment"
          ? "Interest"
          : "Repayment";
    return `${kind} · #${md.loan_id}`;
  }
  if (!desc) return financeEntryLabel(type);

  const instMatch = desc.match(/inst\s+(\d+)\s*\/\s*(\d+)/i);
  const loanMatch = desc.match(/loan\s*#\s*(\d+)/i);
  const loanId = loanMatch?.[1] ?? (md.loan_id != null ? String(md.loan_id) : null);

  let monthRaw =
    (desc.match(/—\s*([A-Za-z]+)/) || [])[1] ||
    (desc.match(
      /\b(January|February|March|April|May|June|July|August|September|October|November|December)\b/i
    ) || [])[1];
  const monthShort = monthRaw
    ? MONTH_SHORT[String(monthRaw).toLowerCase()] || String(monthRaw).slice(0, 3)
    : null;

  if (type === "loan_drawdown" && loanId != null) {
    return monthShort ? `${monthShort} · #${loanId}` : `Drawdown · #${loanId}`;
  }

  if (monthShort && loanId != null) {
    const parts = [monthShort, `#${loanId}`];
    if (instMatch) parts.push(`${instMatch[1]}/${instMatch[2]}`);
    return parts.join(" · ");
  }

  if (loanId != null && instMatch) {
    return `#${loanId} · ${instMatch[1]}/${instMatch[2]}`;
  }

  if (loanId != null) {
    return type === "loan_interest_payment"
      ? `Interest · #${loanId}`
      : `Repayment · #${loanId}`;
  }

  return (
    desc
      .replace(/^Scheduled loan repayment\s*—\s*/i, "")
      .replace(/^Loan interest(?:\s*payment)?\s*—\s*/i, "")
      .replace(/^Loan principal repayment\s*/i, "")
      .trim() || financeEntryLabel(type)
  );
}

function ledgerBreakdownLabel(row) {
  const type = row.entry_type || "other";
  if (LOAN_LEDGER_TYPES.has(type)) {
    return compactLoanBreakdownLabel(row);
  }
  if (type === "infra_purchase") {
    const md = parseMetadata(row.metadata);
    if (md.stadium_name) return String(md.stadium_name);
    const desc = String(row.description || "");
    const fromDesc = desc.match(/Stadium purchase — (.+?)(?:\s*\(|$)/i);
    if (fromDesc?.[1]) return fromDesc[1].trim();
    if (row.club_name) return String(row.club_name);
  }
  return financeEntryLabel(type);
}

function parseMetadata(raw) {
  if (!raw) return {};
  if (typeof raw === "object") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

export function aggregateLedgerByLine(rows) {
  /** @type {Map<string, { amount: number, detail: Record<string, number> }>} */
  const byLine = new Map();

  const ensure = (id) => {
    if (!byLine.has(id)) byLine.set(id, { amount: 0, detail: {} });
    return byLine.get(id);
  };

  for (const r of rows) {
    const type = r.entry_type || "other";
    const amt = Number(r.amount || 0);
    const meta = parseMetadata(r.metadata);
    let lineId = LEDGER_TYPE_TO_LINE[type];
    if (
      type === "transfer_purchase" &&
      (meta.kind === "manager" || meta.manager_draft === true || meta.manager_draft === "true")
    ) {
      lineId = "staff_offers";
    }
    if (
      type === "contract_release_comp" &&
      amt > 0.5 &&
      (meta.kind === "manager" || meta.manager_sack === true || meta.sack === true)
    ) {
      lineId = "staff_termination";
    }
    const breakdownKey = ledgerBreakdownLabel(r);
    if (!lineId) {
      const bucket = ensure("_unmapped");
      bucket.amount += amt;
      bucket.detail[breakdownKey] = (bucket.detail[breakdownKey] || 0) + amt;
      continue;
    }
    const bucket = ensure(lineId);
    bucket.amount += amt;
    bucket.detail[breakdownKey] = (bucket.detail[breakdownKey] || 0) + amt;
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

function formatRunningAmount(amount) {
  const n = Number(amount);
  const cls = n >= 0 ? "income-amt" : "cost-amt";
  return `<span class="amt ${cls}">${formatMoney(n)}</span>`;
}

function formatPendingAmount(pending) {
  if (!pending || Math.abs(pending.amount) < 0.001) {
    return '<span class="amt zero">—</span>';
  }
  const n = Number(pending.amount);
  const cls = n >= 0 ? "income-amt" : "cost-amt";
  const sign = n >= 0 ? "+" : "−";
  return `<span class="amt ${cls} pending-amt">${sign}${formatMoney(Math.abs(n))}</span>`;
}

const SUBSIDY_PREVIEW_LINE_KEYS = {
  gov_hg: "homegrown",
  gov_youth: "youth",
  gov_bnb: "bnb",
};

/** Shown under Government lines when preview exists but pending column is — */
function subsidyQualifyingNote(lineId, preview) {
  const key = SUBSIDY_PREVIEW_LINE_KEYS[lineId];
  if (!key || !preview?.[key]) return "";

  const block = preview[key];
  const amt = Number(block.amount || 0);
  const status = block.status && block.status !== "—" ? block.status : null;
  const count = Number(block.count ?? 0);

  if (lineId === "gov_bnb") {
    const min = Number(block.min_required ?? 14);
    const maxR = block.max_rating ?? 72;
    const bonus = Number(block.flat_bonus ?? 10000000);
    const qual = `${count} of ${min} at ≤${maxR}`;
    return `Est. ${formatMoney(amt)} — ${qual} for ${formatMoney(bonus)} weak squad bonus${status ? ` · ${status}` : ""} · paid at 38/38`;
  }

  if (lineId === "gov_youth") {
    return `Est. ${formatMoney(amt)} — ${count} under-21${status ? ` · ${status}` : ""} · paid at 38/38`;
  }

  if (lineId === "gov_hg") {
    return `Est. ${formatMoney(amt)} — ${count} homegrown${status ? ` · ${status}` : ""} · paid at 38/38`;
  }

  return "";
}

/** Pending only when not already fully reflected on the ledger for that line. */
function resolvePendingForLine(lineId, pending, byLine) {
  if (!pending || Math.abs(pending.amount) < 0.001) return null;
  const posted = Number(byLine.get(lineId)?.amount || 0);
  const amt = Number(pending.amount);
  if (amt > 0 && posted > 0.5 && posted >= amt - 0.5) return null;
  if (amt < 0 && posted < -0.5 && Math.abs(posted) >= Math.abs(amt) - 0.5) {
    return null;
  }
  return pending;
}

function sortBreakdownEntries(entries, { loans = false } = {}) {
  return entries.sort((a, b) => {
    if (loans) {
      const loanA = Number((a[0].match(/#(\d+)/) || [])[1]);
      const loanB = Number((b[0].match(/#(\d+)/) || [])[1]);
      if (Number.isFinite(loanA) && Number.isFinite(loanB) && loanA !== loanB) {
        return loanA - loanB;
      }
      const instA = Number((a[0].match(/(\d+)\s*\/\s*\d+/) || [])[1]);
      const instB = Number((b[0].match(/(\d+)\s*\/\s*\d+/) || [])[1]);
      if (Number.isFinite(instA) && Number.isFinite(instB) && instA !== instB) {
        return instA - instB;
      }
    } else {
      const ia = Number((a[0].match(/inst\s+(\d+)/i) || [])[1]);
      const ib = Number((b[0].match(/inst\s+(\d+)/i) || [])[1]);
      if (Number.isFinite(ia) && Number.isFinite(ib) && ia !== ib) return ia - ib;
    }
    return String(a[0]).localeCompare(String(b[0]), undefined, { sensitivity: "base" });
  });
}

function formatBreakdownColumn(bucket, { loans = false } = {}) {
  if (!bucket?.detail) return '<span class="amt zero">—</span>';
  const rows = sortBreakdownEntries(
    Object.entries(bucket.detail).filter(([, v]) => Math.abs(v) > 0.001),
    { loans }
  ).map(([t, v]) => {
    const n = Number(v);
    const sign = n >= 0 ? "+" : "−";
    return `<div class="detail-line"><span>${escapeFinanceHtml(t)}</span><span>${sign}${formatMoney(Math.abs(n))}</span></div>`;
  });
  return rows.length ? rows.join("") : '<span class="amt zero">—</span>';
}

function escapeFinanceHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderSheetColumnsHead() {
  return `<div class="fin-columns-head">
    <span class="fin-col-label">Line</span>
    <span class="fin-col-posted">Posted</span>
    <span class="fin-col-breakdown">Breakdown</span>
    <span class="fin-col-running">Running total</span>
    <span class="fin-col-pending">Pending</span>
  </div>`;
}

function renderFinanceLineRow(line, bucket, running, pending, subsidyPreview) {
  const hasData = bucket && Math.abs(bucket.amount) > 0.001;
  const planned = line.planned && !hasData;
  const isLoan = LOAN_LINE_IDS.has(line.id);

  const pendingNote =
    pending?.note && Math.abs(pending.amount) > 0.001
      ? `<p class="fin-line-note fin-pending-note">${pending.note}</p>`
      : "";

  const subsidyNote =
    subsidyPreview && (!pending || Math.abs(pending.amount) < 0.001)
      ? subsidyQualifyingNote(line.id, subsidyPreview)
      : "";
  const subsidyNoteHtml = subsidyNote
    ? `<p class="fin-line-note fin-subsidy-preview">${subsidyNote}</p>`
    : "";

  const lineClass = [
    "fin-line",
    planned ? "planned-line" : "",
    isLoan ? "fin-line-loans" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return `
    <div class="${lineClass}" data-line="${escapeFinanceHtml(line.id)}">
      <div class="fin-line-head fin-line-cols">
        <span class="fin-line-label">${line.label}</span>
        <span class="fin-col-posted">${formatLineAmount(bucket?.amount ?? 0, hasData, line.planned)}</span>
        <span class="fin-col-breakdown">${
          hasData
            ? formatBreakdownColumn(bucket, { loans: isLoan })
            : '<span class="amt zero">—</span>'
        }</span>
        <span class="fin-col-running">${formatRunningAmount(running)}</span>
        <span class="fin-col-pending">${formatPendingAmount(pending)}</span>
      </div>
      ${line.note ? `<p class="fin-line-note">${line.note}</p>` : ""}
      ${
        bucket?.fromHistory
          ? `<p class="fin-line-note">Season total from completed transfers (transfer history).</p>`
          : ""
      }
      ${pendingNote}
      ${subsidyNoteHtml}
    </div>
  `;
}

function renderProjectedFooter(currentBalance, totalPending, running) {
  const projected =
    currentBalance != null
      ? Number(currentBalance) + totalPending
      : running + totalPending;
  const bal = Number(currentBalance) || 0;
  const pendingSign = totalPending >= 0 ? "+" : "−";
  return `
    <div class="fin-projected-footer">
      <div class="fin-projected-main">
        <span><b>Projected balance</b></span>
        <span class="fin-projected-value amt ${projected >= 0 ? "income-amt" : "cost-amt"}">${formatMoney(projected)}</span>
      </div>
      <p class="fin-projected-sub">
        Current ${formatMoney(bal)} ${pendingSign} pending ${formatMoney(Math.abs(totalPending))}
        · Running total (posted only) ${formatMoney(running)}
      </p>
    </div>
  `;
}

/**
 * @param {Map<string, { amount: number, detail: Record<string, number> }>} byLine
 * @param {{
 *   pendingByLine?: Map<string, { amount: number, note?: string }>,
 *   runningStart?: number,
 *   currentBalance?: number,
 * }} [options]
 */
export function renderFinanceSections(byLine, options = {}) {
  const pendingByLine = options.pendingByLine || new Map();
  const subsidyPreview = options.subsidyPreview || null;
  let running = Number(options.runningStart) || 0;
  let totalPending = 0;
  for (const [lineId, pending] of pendingByLine.entries()) {
    const resolved = resolvePendingForLine(lineId, pending, byLine);
    if (resolved) totalPending += Number(resolved.amount) || 0;
  }

  const parts = [`<div class="fin-sheet">${renderSheetColumnsHead()}`];

  for (const section of FINANCE_UI_SECTIONS) {
    let sectionNet = 0;
    let sectionPending = 0;
    const lineHtml = section.lines
      .map((line) => {
        const bucket = byLine.get(line.id);
        const hasData = bucket && Math.abs(bucket.amount) > 0.001;
        const postedAmt = hasData ? bucket.amount : 0;
        if (hasData) sectionNet += bucket.amount;
        running += postedAmt;

        const pending = resolvePendingForLine(
          line.id,
          pendingByLine.get(line.id),
          byLine
        );
        if (pending && Math.abs(pending.amount) > 0.001) {
          sectionPending += pending.amount;
        }

        return renderFinanceLineRow(line, bucket, running, pending, subsidyPreview);
      })
      .join("");

    const sectionPendingCls = sectionPending >= 0 ? "income-amt" : "cost-amt";
    const sectionPendingSign = sectionPending >= 0 ? "+" : "−";

    parts.push(`
      <section class="fin-section" id="fin-${section.id}">
        <h3>${section.title}</h3>
        ${section.intro ? `<p class="fin-section-intro">${section.intro}</p>` : ""}
        ${lineHtml}
        <div class="fin-section-total fin-line-cols">
          <span>Section net</span>
          <span class="fin-col-posted amt ${sectionNet >= 0 ? "income-amt" : "cost-amt"}">${sectionNet >= 0 ? "+" : "−"}${formatMoney(Math.abs(sectionNet))}</span>
          <span class="fin-col-breakdown"></span>
          <span class="fin-col-running amt ${running >= 0 ? "income-amt" : "cost-amt"}">${formatMoney(running)}</span>
          <span class="fin-col-pending amt ${sectionPendingCls}">${Math.abs(sectionPending) < 0.001 ? "—" : `${sectionPendingSign}${formatMoney(Math.abs(sectionPending))}`}</span>
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
          <div class="fin-line-head fin-line-cols">
            <span class="fin-line-label">Other posted types</span>
            <span class="fin-col-posted amt">${formatMoney(unmapped.amount)}</span>
            <span class="fin-col-breakdown">${formatBreakdownColumn(unmapped)}</span>
            <span class="fin-col-running"></span>
            <span class="fin-col-pending"></span>
          </div>
        </div>
      </section>
    `);
  }

  parts.push(
    renderProjectedFooter(options.currentBalance, totalPending, running),
    "</div>"
  );

  return parts.join("");
}
