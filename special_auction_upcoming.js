/**
 * "Upcoming auctions" list for the special auction pages.
 * Reads only public columns — mystery prize identity is never loaded here.
 */

import { formatInstantUK, isValidInstant } from "./countdown_display.js";

const TYPE_LABELS = {
  snap: "Snap auction",
  blind_gauntlet: "Blind Gauntlet",
  lowest_unique: "Lowest unique bid",
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatMoney(n) {
  return `₿ ${Number(n || 0).toLocaleString("en-GB")}`;
}

function prizeLabel(a) {
  if (a.prize_type === "cash" && Number(a.prize_cash_amount) > 0) {
    return `${formatMoney(a.prize_cash_amount)} cash`;
  }
  if (a.prize_type === "discount" && Number(a.prize_discount_pct) > 0) {
    return `${Number(a.prize_discount_pct)}% fee discount`;
  }
  if (a.prize_type === "player") {
    return a.auction_type === "snap" ? "Mystery player" : "Player";
  }
  return "Prize";
}

function auctionHref(a) {
  return a.auction_type === "blind_gauntlet"
    ? `special_auction_gauntlet.html?id=${a.id}`
    : `special_auction.html?id=${a.id}`;
}

export async function loadUpcomingSpecialAuctions(supabase) {
  const { data, error } = await supabase
    .from("special_auctions")
    .select(
      "id, title, auction_type, status, start_time, end_time, prize_type, prize_cash_amount, prize_discount_pct"
    )
    .in("status", ["scheduled", "active"])
    .order("start_time", { ascending: true })
    .limit(10);
  if (error) {
    console.warn("loadUpcomingSpecialAuctions:", error.message);
    return [];
  }
  return data || [];
}

/**
 * @param {HTMLElement} rootEl
 * @param {Array} auctions
 * @param {number|string|null} currentId auction shown on this page
 */
export function renderUpcomingSpecialAuctions(rootEl, auctions, currentId = null) {
  if (!rootEl) return;
  const list = auctions || [];
  if (list.length < 2 && list.every((a) => String(a.id) === String(currentId))) {
    rootEl.hidden = true;
    rootEl.innerHTML = "";
    return;
  }

  const now = Date.now();
  const rows = list
    .map((a) => {
      const start = new Date(a.start_time);
      const startMs = start.getTime();
      const endMs = new Date(a.end_time).getTime();
      const live = Number.isFinite(startMs) && startMs <= now && (!Number.isFinite(endMs) || now < endMs);
      const isCurrent = String(a.id) === String(currentId);
      const when = isValidInstant(start) ? formatInstantUK(start) : "—";
      const tag = isCurrent
        ? `<span class="sa-upcoming-tag current">Showing</span>`
        : live
          ? `<span class="sa-upcoming-tag live">Live</span>`
          : "";
      const title = escapeHtml(a.title || TYPE_LABELS[a.auction_type] || "Special auction");
      const inner = `
        <div class="sa-upcoming-main">
          <div class="sa-upcoming-title">${title} ${tag}</div>
          <div class="sa-upcoming-meta">${escapeHtml(TYPE_LABELS[a.auction_type] || a.auction_type)} · ${escapeHtml(prizeLabel(a))}</div>
        </div>
        <div class="sa-upcoming-when">${escapeHtml(when)}</div>`;
      return isCurrent
        ? `<li class="sa-upcoming-item is-current">${inner}</li>`
        : `<li class="sa-upcoming-item"><a href="${auctionHref(a)}">${inner}</a></li>`;
    })
    .join("");

  rootEl.hidden = false;
  rootEl.innerHTML = `
    <h2 class="sa-upcoming-heading">Upcoming auctions</h2>
    <ul class="sa-upcoming-list">${rows}</ul>`;
}

export const UPCOMING_SPECIAL_AUCTIONS_CSS = `
  .sa-upcoming { margin: 16px auto; }
  .sa-upcoming-heading { color: #ffcc66; font-size: 16px; margin: 0 0 10px; }
  .sa-upcoming-list { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
  .sa-upcoming-item > a, .sa-upcoming-item.is-current {
    display: flex; flex-wrap: wrap; justify-content: space-between; gap: 6px 12px;
    padding: 10px 12px; background: #1f1f1f; border: 1px solid #333; border-radius: 8px;
    color: #ddd; text-decoration: none;
  }
  .sa-upcoming-item > a:hover { border-color: #ff9900; }
  .sa-upcoming-item.is-current { border-color: #555; opacity: 0.85; }
  .sa-upcoming-title { font-weight: 700; color: #eee; }
  .sa-upcoming-meta { font-size: 12px; color: #999; margin-top: 2px; }
  .sa-upcoming-when { font-size: 13px; color: #ffcc66; align-self: center; white-space: nowrap; }
  .sa-upcoming-tag {
    display: inline-block; margin-left: 6px; padding: 1px 6px; border-radius: 4px;
    font-size: 10px; font-weight: 700; text-transform: uppercase; vertical-align: middle;
  }
  .sa-upcoming-tag.current { background: #333; color: #ccc; }
  .sa-upcoming-tag.live { background: #2a4a2a; color: #8d8; }
`;

export async function mountUpcomingSpecialAuctions(supabase, rootEl, currentId = null) {
  if (!rootEl) return;
  if (!document.getElementById("saUpcomingCss")) {
    const style = document.createElement("style");
    style.id = "saUpcomingCss";
    style.textContent = UPCOMING_SPECIAL_AUCTIONS_CSS;
    document.head.appendChild(style);
  }
  const auctions = await loadUpcomingSpecialAuctions(supabase);
  renderUpcomingSpecialAuctions(rootEl, auctions, currentId);
}
