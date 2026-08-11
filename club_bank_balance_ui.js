/**
 * Bank / advisory budget badge for market / draft / transfer pages.
 * Uses Club_Finances for owned clubs, advisory transfer budget when requested,
 * or an explicit balance override (e.g. club auction starting budget).
 */

import { supabase } from "./supabase_client.js";
import { formatMoney, loadClubBalance } from "./competition.js";
import {
  advisoryBudgetTitle,
  computeAdvisoryTransferBudget,
  renderAdvisoryBudgetBadgeHtml,
} from "./finance_advisory_budget.js";

const STYLE_ID = "club-bank-balance-style";

export function ensureClubBankBalanceStyles() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
    .club-bank-status-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 12px 16px;
      margin: 0 0 16px;
    }
    .club-bank-status-row.inset {
      margin-left: 20px;
      margin-right: 20px;
    }
    .club-bank-status-left {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 10px 14px;
      min-width: 0;
    }
    .club-bank-balance {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin: 0;
      padding: 6px 12px;
      background: #1a1a1a;
      border: 1px solid #333;
      border-radius: 6px;
      font-size: 13px;
      color: #ccc;
      line-height: 1.3;
      flex-shrink: 0;
    }
    .club-bank-balance .cbb-refresh-btn {
      flex: 0 0 auto;
      width: 28px;
      height: 28px;
      margin: 0;
      padding: 0;
      border: 1px solid #555;
      border-radius: 4px;
      background: #252525;
      color: #ffaa22;
      font-size: 15px;
      line-height: 1;
      cursor: pointer;
      align-self: center;
    }
    .club-bank-balance .cbb-refresh-btn:hover:not(:disabled) {
      background: #333;
      border-color: #ff9900;
      color: #ffcc66;
    }
    .club-bank-balance .cbb-refresh-btn:disabled,
    .club-bank-balance .cbb-refresh-btn.is-busy {
      opacity: 0.55;
      cursor: wait;
    }
    .club-bank-balance .cbb-refresh-btn.is-busy {
      animation: cbb-spin 0.8s linear infinite;
    }
    @keyframes cbb-spin {
      to { transform: rotate(360deg); }
    }
    .club-bank-balance[hidden] { display: none !important; }
    .club-bank-balance .cbb-label { color: #888; }
    .club-bank-balance .cbb-amount {
      color: #ff9900;
      font-weight: bold;
      font-variant-numeric: tabular-nums;
    }
    .club-bank-balance.is-negative .cbb-amount { color: #f88; }
    .club-bank-balance.is-zero-advisory .cbb-amount { color: #f88; }
    .club-bank-balance.is-runway-warn {
      border-color: #664444;
      background: #221818;
    }
    .club-bank-balance a {
      color: inherit;
      text-decoration: none;
      display: inline-flex;
      align-items: baseline;
      gap: 8px;
    }
    .club-bank-balance a:hover .cbb-amount { color: #ffcc66; }
    .club-bank-balance .cbb-stack {
      display: flex;
      flex-direction: column;
      gap: 2px;
      align-items: flex-start;
    }
    .club-bank-balance .cbb-row {
      display: inline-flex;
      align-items: baseline;
      gap: 8px;
    }
    .club-bank-balance .cbb-subline {
      font-size: 11px;
      color: #888;
    }
    .club-bank-balance .cbb-warn {
      font-size: 11px;
      color: #f88;
      font-weight: bold;
    }
  `;
  document.head.appendChild(style);
}

async function resolveOwnerClubShort() {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  return data?.ShortName ? String(data.ShortName).trim() : null;
}

function hideBadge(el) {
  el.hidden = true;
  el.textContent = "";
  el.className = "club-bank-balance";
  el.removeAttribute("title");
}

/**
 * @param {string|HTMLElement|null} target
 * @param {{
 *   clubShortName?: string|null,
 *   balance?: number|null,
 *   label?: string,
 *   href?: string|null,
 *   hideIfUnknown?: boolean,
 *   advisory?: boolean,
 * }} [opts]
 */
export async function mountClubBankBalance(target, opts = {}) {
  ensureClubBankBalanceStyles();

  const el =
    typeof target === "string" ? document.getElementById(target) : target;
  if (!el) return null;

  if (opts.advisory) {
    return mountAdvisoryTransferBudget(el, opts);
  }

  const label = opts.label || "Current Bank Balance";
  const href = opts.href === undefined ? "finances.html" : opts.href;

  let balance = opts.balance;
  let clubShort = opts.clubShortName ?? null;

  if (balance == null) {
    if (!clubShort) clubShort = await resolveOwnerClubShort();
    if (!clubShort) {
      if (opts.hideIfUnknown !== false) {
        hideBadge(el);
      } else {
        el.hidden = false;
        el.className = "club-bank-balance";
        el.innerHTML = `<span class="cbb-label">${label}</span><span class="cbb-amount">—</span>`;
      }
      return null;
    }
    const row = await loadClubBalance(supabase, clubShort);
    balance = row?.balance != null ? Number(row.balance) : null;
  }

  if (balance == null || !Number.isFinite(Number(balance))) {
    if (opts.hideIfUnknown !== false) {
      hideBadge(el);
    }
    return null;
  }

  const amount = Number(balance);
  const negative = amount < 0;
  const amountHtml = `<span class="cbb-amount">${formatMoney(amount)}</span>`;
  const labelHtml = `<span class="cbb-label">${label}</span>`;

  el.hidden = false;
  el.className = `club-bank-balance${negative ? " is-negative" : ""}`;
  el.title = clubShort ? `${label} · ${clubShort}` : label;

  if (href) {
    el.innerHTML = `<a href="${href}">${labelHtml}${amountHtml}</a>`;
  } else {
    el.innerHTML = `${labelHtml}${amountHtml}`;
  }

  return { clubShortName: clubShort, balance: amount };
}

/**
 * Advisory season transfer budget badge (floored at ₿0 for spend).
 * @param {string|HTMLElement|null} target
 * @param {{
 *   clubShortName?: string|null,
 *   href?: string|null,
 *   hideIfUnknown?: boolean,
 *   refreshButton?: boolean,
 * }} [opts]
 */
export async function mountAdvisoryTransferBudget(target, opts = {}) {
  ensureClubBankBalanceStyles();

  const el =
    typeof target === "string" ? document.getElementById(target) : target;
  if (!el) return null;

  let clubShort = opts.clubShortName ?? null;
  if (!clubShort) clubShort = await resolveOwnerClubShort();

  if (!clubShort) {
    if (opts.hideIfUnknown !== false) hideBadge(el);
    return null;
  }

  let advisory;
  try {
    advisory = await computeAdvisoryTransferBudget(supabase, clubShort);
  } catch (err) {
    console.warn("advisory transfer budget:", err);
    if (opts.hideIfUnknown !== false) hideBadge(el);
    return null;
  }

  const href = opts.href === undefined ? "finances.html" : opts.href;
  const showRefresh = opts.refreshButton !== false;
  const zeroSpend = advisory.spendable < 0.5;
  const classes = [
    "club-bank-balance",
    "is-advisory",
    zeroSpend ? "is-zero-advisory" : "",
    advisory.runwayNegative ? "is-runway-warn" : "",
  ]
    .filter(Boolean)
    .join(" ");

  el.hidden = false;
  el.className = classes;
  el.title = advisoryBudgetTitle(advisory);
  const badgeHtml = renderAdvisoryBudgetBadgeHtml(advisory, { href });
  el.innerHTML = showRefresh
    ? `${badgeHtml}<button type="button" class="cbb-refresh-btn" title="Refresh advisory transfer budget" aria-label="Refresh advisory transfer budget">↻</button>`
    : badgeHtml;

  if (showRefresh) {
    const btn = el.querySelector(".cbb-refresh-btn");
    btn?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (btn.disabled) return;
      btn.disabled = true;
      btn.classList.add("is-busy");
      mountAdvisoryTransferBudget(el, {
        ...opts,
        clubShortName: clubShort,
        refreshButton: true,
      }).catch((err) => {
        console.warn("advisory transfer budget refresh:", err);
        btn.disabled = false;
        btn.classList.remove("is-busy");
      });
    });
  }

  return { clubShortName: clubShort, advisory };
}

/**
 * Update an existing badge with a known balance (e.g. club auction budget refresh).
 * Pass null/undefined to hide.
 * @param {string|HTMLElement|null} target
 * @param {number|null|undefined} balance
 * @param {{ label?: string, href?: string|null }} [opts]
 */
export function setClubBankBalance(target, balance, opts = {}) {
  if (balance == null || !Number.isFinite(Number(balance))) {
    const el =
      typeof target === "string" ? document.getElementById(target) : target;
    if (el) hideBadge(el);
    return Promise.resolve(null);
  }
  return mountClubBankBalance(target, {
    ...opts,
    balance,
    hideIfUnknown: false,
  });
}
