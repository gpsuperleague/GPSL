/**
 * Small “Current Bank Balance” badge for market / draft pages.
 * Uses Club_Finances for owned clubs, or an explicit balance override
 * (e.g. club auction starting budget).
 */

import { supabase } from "./supabase_client.js";
import { formatMoney, loadClubBalance } from "./competition.js";

const STYLE_ID = "club-bank-balance-style";

export function ensureClubBankBalanceStyles() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
    .club-bank-balance {
      display: inline-flex;
      align-items: baseline;
      gap: 8px;
      margin: 0 0 12px;
      padding: 6px 12px;
      background: #1a1a1a;
      border: 1px solid #333;
      border-radius: 6px;
      font-size: 13px;
      color: #ccc;
      line-height: 1.3;
    }
    .club-bank-balance[hidden] { display: none !important; }
    .club-bank-balance .cbb-label { color: #888; }
    .club-bank-balance .cbb-amount {
      color: #ff9900;
      font-weight: bold;
      font-variant-numeric: tabular-nums;
    }
    .club-bank-balance.is-negative .cbb-amount { color: #f88; }
    .club-bank-balance a {
      color: inherit;
      text-decoration: none;
      display: inline-flex;
      align-items: baseline;
      gap: 8px;
    }
    .club-bank-balance a:hover .cbb-amount { color: #ffcc66; }
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

/**
 * @param {string|HTMLElement|null} target
 * @param {{
 *   clubShortName?: string|null,
 *   balance?: number|null,
 *   label?: string,
 *   href?: string|null,
 *   hideIfUnknown?: boolean,
 * }} [opts]
 */
export async function mountClubBankBalance(target, opts = {}) {
  ensureClubBankBalanceStyles();

  const el =
    typeof target === "string" ? document.getElementById(target) : target;
  if (!el) return null;

  const label = opts.label || "Current Bank Balance";
  const href = opts.href === undefined ? "finances.html" : opts.href;

  let balance = opts.balance;
  let clubShort = opts.clubShortName ?? null;

  if (balance == null) {
    if (!clubShort) clubShort = await resolveOwnerClubShort();
    if (!clubShort) {
      if (opts.hideIfUnknown !== false) {
        el.hidden = true;
        el.textContent = "";
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
      el.hidden = true;
      el.textContent = "";
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
    if (el) {
      el.hidden = true;
      el.textContent = "";
    }
    return Promise.resolve(null);
  }
  return mountClubBankBalance(target, {
    ...opts,
    balance,
    hideIfUnknown: false,
  });
}
