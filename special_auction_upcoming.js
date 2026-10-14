/**
 * "Upcoming auctions" list for the special auction pages.
 * Reads only public columns — mystery prize identity is never loaded here.
 */

import { formatInstantUK, isValidInstant } from "./countdown_display.js";
import { downloadIcs, auctionWindowEvents } from "./calendar_ics.js";

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

const UPCOMING_COLUMNS = [
  "id, title, auction_type, status, start_time, end_time, prize_type, prize_cash_amount, prize_discount_pct",
  "id, title, auction_type, status, start_time, end_time",
];

export async function loadUpcomingSpecialAuctions(supabase) {
  for (const cols of UPCOMING_COLUMNS) {
    const { data, error } = await supabase
      .from("special_auctions")
      .select(cols)
      .in("status", ["scheduled", "active"])
      .order("start_time", { ascending: true })
      .limit(10);
    if (!error) return data || [];
    console.warn("loadUpcomingSpecialAuctions:", error.message);
  }
  return [];
}

/**
 * @param {HTMLElement} rootEl
 * @param {Array} auctions
 * @param {number|string|null} currentId auction shown on this page
 */
function auctionCalendarEvents(a) {
  const typeLabel = TYPE_LABELS[a.auction_type] || "Special auction";
  return auctionWindowEvents({
    id: `special-${a.id}`,
    title: `GPSL ${typeLabel}: ${a.title || typeLabel}`,
    startAt: a.start_time,
    // Snap finish is random — never put the hard end (or random end) in calendars
    endAt: a.auction_type === "snap" ? null : a.end_time || null,
    url: new URL(auctionHref(a), window.location.href).href,
  });
}

function wireCalendarButtons(rootEl, list) {
  const byId = new Map(list.map((a) => [String(a.id), a]));
  rootEl.querySelectorAll("[data-sa-cal]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const a = byId.get(btn.dataset.saCal);
      if (a) downloadIcs(`gpsl-special-auction-${a.id}.ics`, auctionCalendarEvents(a));
    });
  });
  rootEl.querySelector("[data-sa-cal-all]")?.addEventListener("click", () => {
    downloadIcs("gpsl-special-auctions.ics", list.flatMap(auctionCalendarEvents));
  });
}

export function renderUpcomingSpecialAuctions(rootEl, auctions, currentId = null) {
  if (!rootEl) return;
  const list = auctions || [];
  if (!list.length) {
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
      const calBtn = `<button type="button" class="sa-upcoming-cal" data-sa-cal="${a.id}" title="Add to your calendar (phone / Outlook / Google)">📅</button>`;
      return isCurrent
        ? `<li class="sa-upcoming-item is-current"><div class="sa-upcoming-card">${inner}</div>${calBtn}</li>`
        : `<li class="sa-upcoming-item"><a class="sa-upcoming-card" href="${auctionHref(a)}">${inner}</a>${calBtn}</li>`;
    })
    .join("");

  rootEl.hidden = false;
  rootEl.innerHTML = `
    <div class="sa-upcoming-head">
      <h2 class="sa-upcoming-heading">Upcoming auctions</h2>
      <button type="button" class="sa-upcoming-cal-all" data-sa-cal-all>📅 Add all to calendar</button>
    </div>
    <ul class="sa-upcoming-list">${rows}</ul>`;
  wireCalendarButtons(rootEl, list);
}

export const UPCOMING_SPECIAL_AUCTIONS_CSS = `
  .sa-upcoming { margin: 16px auto; }
  .sa-upcoming-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; margin: 0 0 10px; }
  .sa-upcoming-heading { color: #ffcc66; font-size: 16px; margin: 0; }
  .sa-upcoming-list { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
  .sa-upcoming-item { display: flex; gap: 8px; align-items: stretch; }
  .sa-upcoming-card {
    flex: 1; min-width: 0;
    display: flex; flex-wrap: wrap; justify-content: space-between; gap: 6px 12px;
    padding: 10px 12px; background: #1f1f1f; border: 1px solid #333; border-radius: 8px;
    color: #ddd; text-decoration: none;
  }
  a.sa-upcoming-card:hover { border-color: #ff9900; }
  .sa-upcoming-item.is-current .sa-upcoming-card { border-color: #555; opacity: 0.85; }
  .sa-upcoming-cal, .sa-upcoming-cal-all {
    background: #2a2a2a; color: #ddd; border: 1px solid #444; border-radius: 8px;
    cursor: pointer; font-size: 13px;
  }
  .sa-upcoming-cal { width: 44px; font-size: 18px; }
  .sa-upcoming-cal-all { padding: 6px 12px; }
  .sa-upcoming-cal:hover, .sa-upcoming-cal-all:hover { border-color: #ff9900; }
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
