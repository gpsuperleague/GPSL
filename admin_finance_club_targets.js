/** Shared club targeting UI for admin cash inject / emergency tax pages. */

import { formatMoney } from "./competition.js";

export function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * @param {HTMLElement} host
 * @param {{ ShortName: string, Club: string }[]} clubs
 */
export function renderClubChecklist(host, clubs) {
  if (!host) return;
  if (!clubs.length) {
    host.innerHTML = `<p class="note">No clubs found.</p>`;
    return;
  }
  host.innerHTML = clubs
    .map(
      (c) => `
    <label class="admin-club-check">
      <input type="checkbox" value="${escapeHtml(c.ShortName)}" data-club-check>
      <span>${escapeHtml(c.Club || c.ShortName)} <span class="admin-club-check-short">(${escapeHtml(c.ShortName)})</span></span>
    </label>`
    )
    .join("");
}

export function selectedClubShortNames(host) {
  if (!host) return [];
  return [...host.querySelectorAll("input[data-club-check]:checked")].map((el) => el.value);
}

export function setAllClubChecks(host, checked) {
  if (!host) return;
  host.querySelectorAll("input[data-club-check]").forEach((el) => {
    el.checked = checked;
  });
}

export function syncClubPickerVisibility(scopeValue, pickerEl) {
  if (!pickerEl) return;
  pickerEl.hidden = scopeValue !== "selected";
}

export function parsePositiveAmount(inputEl) {
  const raw = Number(inputEl?.value);
  if (!Number.isFinite(raw) || raw <= 0) return null;
  return Math.round(raw);
}

/**
 * @param {{
 *   actionLabel: string,
 *   amount: number,
 *   scope: 'all' | 'selected',
 *   clubs: string[],
 * }} opts
 */
export function confirmFinanceApply({ actionLabel, amount, scope, clubs }) {
  const clubLine =
    scope === "all"
      ? "all season clubs (Superleague + Championship)"
      : `${clubs.length} selected club(s):\n${clubs.slice(0, 12).join(", ")}${
          clubs.length > 12 ? "…" : ""
        }`;
  return window.confirm(
    `${actionLabel}\n\nAmount: ${formatMoney(amount)}\nTarget: ${clubLine}\n\nContinue?`
  );
}
