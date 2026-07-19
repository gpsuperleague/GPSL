import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

let myClub = { short: null };

function showError(msg) {
  const el = document.getElementById("friendliesError");
  if (!el) return;
  el.textContent = msg;
  el.style.display = msg ? "block" : "none";
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function matchLineHtml(row) {
  const leftShort = String(row.club_left || "").toUpperCase();
  const rightShort = String(row.club_right || "").toUpperCase();
  const mine = String(myClub.short || "").toUpperCase();
  const leftCls = leftShort === mine ? "mine" : "";
  const rightCls = rightShort === mine ? "mine" : "";
  return `
    <span class="${leftCls}">${clubWithOwnerHtml(row.club_left_name, row.club_left, "inline")}</span>
    <span style="color:#666;margin:0 4px;">vs</span>
    <span class="${rightCls}">${clubWithOwnerHtml(row.club_right_name, row.club_right, "inline")}</span>
  `;
}

function payoutBadge(row) {
  const paid = Number(row.my_payout);
  if (Number.isFinite(paid) && paid > 0) {
    return `<span class="friendly-badge paid">Paid ${escapeHtml(formatMoney(paid))}</span>`;
  }
  const reason = row.my_payout_skipped
    ? String(row.my_payout_skipped)
    : "No payout";
  return `<span class="friendly-badge unpaid" title="${escapeHtml(reason)}">No payout</span>`;
}

function renderConfirmedCard(row) {
  return `
    <div class="friendly-card">
      <div class="friendly-top">
        <span class="friendly-badge friendly">Friendly</span>
        <div class="friendly-match">${matchLineHtml(row)}</div>
        <span class="friendly-score">${escapeHtml(row.score_left)} - ${escapeHtml(row.score_right)}</span>
        ${payoutBadge(row)}
      </div>
      <div class="friendly-meta">
        <span><b>Stadium</b> ${escapeHtml(row.stadium || "—")}</span>
        <span><b>Confirmed</b> ${escapeHtml(formatWhen(row.confirmed_at))}</span>
        <span><b>${row.is_home ? "Home" : "Away"}</b> (scoreline order)</span>
      </div>
    </div>
  `;
}

function renderPendingCard(row) {
  const waiting = row.i_reported
    ? "Waiting for opponent to post the matching result in Discord."
    : "Opponent posted — post the matching result in Discord to confirm.";
  return `
    <div class="friendly-card">
      <div class="friendly-top">
        <span class="friendly-badge pending">Pending</span>
        <div class="friendly-match">${matchLineHtml(row)}</div>
        <span class="friendly-score">${escapeHtml(row.score_left)} - ${escapeHtml(row.score_right)}</span>
      </div>
      <div class="friendly-meta">
        <span><b>Stadium</b> ${escapeHtml(row.stadium || "—")}</span>
        <span><b>Posted</b> ${escapeHtml(formatWhen(row.posted_at))}</span>
        <span><b>Reporter</b> ${escapeHtml(row.reporter_club_short_name || "—")}</span>
      </div>
      <p class="pending-note">${escapeHtml(waiting)}</p>
    </div>
  `;
}

function renderMonth(month) {
  const paid = Number(month.paid_count) || 0;
  const cap = Number(month.month_cap) || 10;
  const confirmed = Array.isArray(month.friendlies) ? month.friendlies : [];
  const pending = Array.isArray(month.pending) ? month.pending : [];
  const cards = [
    ...pending.map(renderPendingCard),
    ...confirmed.map(renderConfirmedCard),
  ].join("");

  if (!cards) return "";

  return `
    <section class="month-block">
      <div class="month-head">
        <span>${escapeHtml(month.gpsl_month_label || month.gpsl_month || "Month")}</span>
        <span class="cap">Paid friendlies: <b style="color:#ffcc66">${paid}</b> / ${cap}</span>
      </div>
      ${cards}
    </section>
  `;
}

function renderSummary(data) {
  const el = document.getElementById("friendliesSummary");
  if (!el) return;
  const seasonPaid = Number(data.season_paid_total) || 0;
  const seasonCap = Number(data.season_cap) || 500000;
  const payout = Number(data.payout_amount) || 5000;
  const monthCap = Number(data.month_cap) || 10;
  el.innerHTML = `
    <span class="pill">Club <b>${escapeHtml(data.club || "—")}</b></span>
    <span class="pill">Active month <b>${escapeHtml(data.active_gpsl_month_label || "—")}</b></span>
    <span class="pill">Pay <b>${escapeHtml(formatMoney(payout))}</b> each (first ${monthCap} / month)</span>
    <span class="pill">Season friendlies income <b>${escapeHtml(formatMoney(seasonPaid))}</b> / ${escapeHtml(formatMoney(seasonCap))}</span>
  `;
}

async function loadPage() {
  showError("");
  const root = document.getElementById("friendliesRoot");
  root.innerHTML = `<p class="empty">Loading…</p>`;

  const { data, error } = await supabase.rpc("club_friendlies_my_club");
  if (error) {
    root.innerHTML = `<p class="empty">Could not load friendlies.</p>`;
    showError(
      error.message?.includes("club_friendlies_my_club")
        ? "Run supabase/sql/patches/club_friendlies_page.sql in Supabase SQL Editor."
        : error.message
    );
    return;
  }

  if (!data?.ok) {
    root.innerHTML = `<p class="empty">${escapeHtml(data?.reason || "No club linked.")}</p>`;
    return;
  }

  myClub.short = data.club;
  document.getElementById("friendliesTitle").textContent =
    `Friendlies — ${data.club}`;
  renderSummary(data);

  const months = Array.isArray(data.months) ? data.months : [];
  if (!months.length) {
    root.innerHTML = `
      <p class="empty">
        No friendlies yet. Post in Discord <b>#gpsl-friendly-results</b> as
        <code style="color:#ffcc66">JUB 2 - 2 BEN</code> or <code style="color:#ffcc66">ROS 2 - JUB 3</code>.
        When your opponent posts the matching scoreline, it appears here.
      </p>`;
    return;
  }

  root.innerHTML = months.map(renderMonth).join("") ||
    `<p class="empty">No friendlies yet.</p>`;
}

async function main() {
  await initGlobal();
  await loadClubsMap(supabase);
  await loadPage();
}

main().catch((e) => {
  console.error(e);
  showError(e.message || String(e));
});
