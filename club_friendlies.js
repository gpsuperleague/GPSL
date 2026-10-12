import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import { renderClubFriendliesRules } from "./club_friendlies_rules.js?v=20261012-cap-15";

let myClub = { short: null };
/** Opponent ShortName (upper) → { fdr, ranking_fdr, bookies_fdr, bookies_rank, bookies_pool } */
let difficultyByClub = {};

const FORM_MONTHS = [
  { key: "june", label: "June" },
  { key: "july", label: "July" },
];

function myResult(row) {
  const left = Number(row.score_left);
  const right = Number(row.score_right);
  if (!Number.isFinite(left) || !Number.isFinite(right)) return null;
  const mine = row.is_home ? left : right;
  const theirs = row.is_home ? right : left;
  if (mine > theirs) return { code: "W", mine, theirs };
  if (mine < theirs) return { code: "L", mine, theirs };
  return { code: "D", mine, theirs };
}

const RESULT_TITLES = { W: "Win", D: "Draw", L: "Loss" };

function resultChip(code, title) {
  if (!code) return "";
  return `<span class="wdl wdl--${code}" title="${escapeHtml(title || RESULT_TITLES[code])}">${code}</span>`;
}

function opponentShort(row) {
  return String((row.is_home ? row.club_right : row.club_left) || "").toUpperCase();
}

function difficultyChip(row) {
  const d = difficultyByClub[opponentShort(row)];
  const fdr = Number(d?.fdr);
  if (!Number.isFinite(fdr) || fdr < 1) return "";
  const parts = [];
  if (d.ranking_fdr != null) parts.push(`Ranking ${d.ranking_fdr}/5`);
  if (d.bookies_fdr != null) {
    parts.push(
      `Bookies ${d.bookies_fdr}/5` +
        (d.bookies_rank ? ` (#${d.bookies_rank} of ${d.bookies_pool})` : "")
    );
  }
  const title = `Difficulty ${fdr}/5 — ${parts.join(" · ") || "ranking"}`;
  return `<span class="fdr fdr--${fdr}" title="${escapeHtml(title)}">Diff ${fdr}</span>`;
}

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
  const res = myResult(row);
  return `
    <div class="friendly-card">
      <div class="friendly-top">
        ${resultChip(res?.code)}
        <span class="friendly-badge friendly">Friendly</span>
        <div class="friendly-match">${matchLineHtml(row)}</div>
        <span class="friendly-score">${escapeHtml(row.score_left)} - ${escapeHtml(row.score_right)}</span>
        ${difficultyChip(row)}
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
  const res = myResult(row);
  return `
    <div class="friendly-card">
      <div class="friendly-top">
        ${res ? `<span class="wdl-pending">${resultChip(res.code, `${RESULT_TITLES[res.code]} (not confirmed yet)`)}</span>` : ""}
        <span class="friendly-badge pending">Pending</span>
        <div class="friendly-match">${matchLineHtml(row)}</div>
        <span class="friendly-score">${escapeHtml(row.score_left)} - ${escapeHtml(row.score_right)}</span>
        ${difficultyChip(row)}
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
  const cap = Number(month.month_cap) || 15;
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
  const monthCap = Number(data.month_cap) || 15;
  el.innerHTML = `
    <span class="pill">Club <b>${escapeHtml(data.club || "—")}</b></span>
    <span class="pill">Active month <b>${escapeHtml(data.active_gpsl_month_label || "—")}</b></span>
    <span class="pill">Pay <b>${escapeHtml(formatMoney(payout))}</b> each (first ${monthCap} / month)</span>
    <span class="pill">Season friendlies income <b>${escapeHtml(formatMoney(seasonPaid))}</b> / ${escapeHtml(formatMoney(seasonCap))}</span>
  `;
}

function renderFormTracker(months) {
  const el = document.getElementById("friendliesForm");
  if (!el) return;
  const byKey = new Map(
    months.map((m) => [String(m.gpsl_month || "").toLowerCase(), m])
  );

  const rows = FORM_MONTHS.map(({ key, label }) => {
    const games = (byKey.get(key)?.friendlies || [])
      .slice()
      .sort((a, b) => new Date(a.confirmed_at) - new Date(b.confirmed_at));
    const results = games.map((g) => ({ g, r: myResult(g) })).filter((x) => x.r);

    if (!results.length) {
      return `
        <div class="form-row">
          <span class="form-month">${label}</span>
          <span class="form-empty">No confirmed friendlies</span>
        </div>`;
    }

    const w = results.filter((x) => x.r.code === "W").length;
    const d = results.filter((x) => x.r.code === "D").length;
    const l = results.filter((x) => x.r.code === "L").length;
    const gf = results.reduce((s, x) => s + x.r.mine, 0);
    const ga = results.reduce((s, x) => s + x.r.theirs, 0);
    const ppg = (w * 3 + d) / results.length;
    const fdrs = results
      .map((x) => Number(difficultyByClub[opponentShort(x.g)]?.fdr))
      .filter((n) => Number.isFinite(n) && n > 0);
    const avgFdr = fdrs.length ? fdrs.reduce((s, n) => s + n, 0) / fdrs.length : null;

    const chips = results
      .map(({ g, r }) => {
        const opp = opponentShort(g);
        return resultChip(r.code, `${RESULT_TITLES[r.code]} ${r.mine}-${r.theirs} vs ${opp}`);
      })
      .join("");

    return `
      <div class="form-row">
        <span class="form-month">${label}</span>
        <span class="form-chips" title="Oldest → newest">${chips}</span>
        <span class="form-stats">
          <b>${w}</b>W <b>${d}</b>D <b>${l}</b>L ·
          Goals <b>${gf}-${ga}</b> ·
          <b>${ppg.toFixed(2)}</b> pts/game${
            avgFdr != null ? ` · Avg difficulty <b>${avgFdr.toFixed(1)}</b>` : ""
          }
        </span>
      </div>`;
  }).join("");

  el.innerHTML = `
    <div class="form-head">Pre-season form <span class="form-hint">(confirmed friendlies, oldest → newest)</span></div>
    ${rows}
  `;
  el.style.display = "block";
}

async function loadDifficulty() {
  const { data, error } = await supabase.rpc("club_friendlies_opponent_difficulty");
  if (error) {
    console.warn("Friendly difficulty unavailable:", error.message);
    difficultyByClub = {};
    return;
  }
  difficultyByClub = data && typeof data === "object" ? data : {};
}

async function loadPage() {
  showError("");
  const root = document.getElementById("friendliesRoot");
  root.innerHTML = `<p class="empty">Loading…</p>`;

  const [{ data, error }] = await Promise.all([
    supabase.rpc("club_friendlies_my_club"),
    loadDifficulty(),
  ]);
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
  renderFormTracker(months);
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
  initGpslInfoTips();
  await initGlobal();
  renderClubFriendliesRules();
  await loadClubsMap(supabase);
  await loadPage();
}

main().catch((e) => {
  console.error(e);
  showError(e.message || String(e));
});
