/**
 * Club Wire — outbid / offer / result alerts + fine/forfeit cutoffs
 * (dashboard card + nav badge). One shared poll per tab (~60s, paused while hidden).
 */
import { supabase } from "./supabase_client.js";
import {
  loadFixtureUnavailable,
  formatOwnUnavailableLine,
} from "./player_discipline.js?v=20261028-unavail";
import {
  loadClubsMap,
  fullClubName,
  ownerTagForClub,
} from "./clubs_lookup.js";
import {
  fetchFixturesHomeWeatherMeta,
  formatWeatherPitchPlain,
} from "./competition_conditions.js";

const POLL_MS = 60000;
const COLLAPSE_KEY = "gpsl_cw_collapsed";

const MARKET_LABEL = {
  player_draft: "Draft auction",
  transfer_list: "Transfer list",
  direct_offer: "Direct offer",
  club_auction: "Club auction",
  manager_draft: "Manager draft",
  manager_market: "Manager market",
  special_auction: "Special auction",
  wage_bid: "Wage bid",
};

const KIND_BADGE = {
  outbid: ["OUTBID", "cw-badge--outbid"],
  offer_accepted: ["ACCEPTED", "cw-badge--good"],
  offer_rejected: ["REJECTED", "cw-badge--bad"],
  review_needed: ["REVIEW", "cw-badge--cutoff"],
  under_review: ["PENDING", "cw-badge--cutoff"],
  review_accepted: ["ACCEPTED", "cw-badge--good"],
  review_declined: ["DECLINED", "cw-badge--bad"],
  won: ["WON", "cw-badge--good"],
  lost: ["LOST", "cw-badge--bad"],
};

const CUTOFF_BADGE = {
  month_lock: ["LOCK", "cw-badge--lock"],
  propose: ["PROPOSE", "cw-badge--cutoff"],
  late_fee: ["LATE FEE", "cw-badge--cutoff"],
  reply: ["REPLY", "cw-badge--cutoff"],
  checkin: ["CHECK-IN", "cw-badge--cutoff"],
  noshow: ["NO-SHOW", "cw-badge--bad"],
  play_window: ["PLAY BY", "cw-badge--lock"],
  video: ["VIDEO", "cw-badge--cutoff"],
  video_suspend: ["VIDEO PT", "cw-badge--bad"],
  result_enter: ["RESULT", "cw-badge--cutoff"],
  result_close: ["RESULT", "cw-badge--bad"],
  result_month: ["RESULT", "cw-badge--cutoff"],
  result_void: ["VOID", "cw-badge--bad"],
};

const STYLE = `
.cw-card {
  margin: 10px 0 14px; border-radius: 10px; overflow: visible;
  background: #0f1720; border: 1px solid #2c3e50; color: #e6edf3;
  font-size: 0.9rem; box-shadow: 0 2px 10px rgba(0,0,0,0.25);
}
.cw-head {
  display: flex; align-items: center; gap: 10px; padding: 7px 12px;
  background: repeating-linear-gradient(135deg, #16222e 0 10px, #142029 10px 20px);
  border-bottom: 1px solid #2c3e50;
}
.cw-title {
  font-family: "Courier New", ui-monospace, monospace; font-weight: 700;
  letter-spacing: 0.14em; text-transform: uppercase; color: #f5b041; font-size: 0.82rem;
}
.cw-live { width: 8px; height: 8px; border-radius: 50%; background: #2ecc71; box-shadow: 0 0 6px #2ecc71; }
.cw-head .cw-sub {
  color: #8aa0b4; font-size: 0.78rem; flex: 1 1 auto; min-width: 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.cw-head .cw-clear {
  margin-left: auto; background: none; border: 1px solid #34495e; color: #8aa0b4;
  border-radius: 999px; padding: 2px 10px; font-size: 0.75rem; cursor: pointer;
}
.cw-head .cw-toggle {
  margin-left: 8px; background: none; border: 1px solid #34495e; color: #8aa0b4;
  border-radius: 4px; padding: 2px 8px; font-size: 0.72rem; cursor: pointer;
}
.cw-head .cw-toggle:hover { color: #fff; border-color: #5d6d7e; }
.cw-card:not(:has(.cw-clear)) .cw-toggle { margin-left: auto; }
.cw-body[hidden] { display: none !important; }
.cw-head .cw-clear:hover { color: #fff; border-color: #5d6d7e; }
.cw-list { list-style: none; margin: 0; padding: 0; }
.cw-item {
  display: flex; align-items: center; flex-wrap: wrap; gap: 8px 10px; padding: 8px 12px;
  border-top: 1px solid #1d2a36;
}
.cw-item:first-child { border-top: 0; }
.cw-item.cw-fresh { animation: cwFlash 2.4s ease-out; }
@keyframes cwFlash { from { background: rgba(245,176,65,0.18); } to { background: transparent; } }
.cw-badge {
  flex-shrink: 0; font-family: "Courier New", ui-monospace, monospace; font-weight: 700;
  font-size: 0.7rem; letter-spacing: 0.08em; padding: 2px 7px; border-radius: 4px;
}
.cw-badge--outbid { background: #f5b041; color: #1b1300; }
.cw-badge--good { background: #27ae60; color: #fff; }
.cw-badge--bad { background: #5d6d7e; color: #fff; }
.cw-badge--cutoff { background: #e67e22; color: #fff; }
.cw-badge--lock { background: #8e44ad; color: #fff; }
.cw-text { flex: 1 1 auto; min-width: 0; line-height: 1.3; }
.cw-text .cw-market { color: #8aa0b4; font-size: 0.75rem; display: block; }
.cw-text .cw-detail { color: #8aa0b4; font-size: 0.75rem; display: block; margin-top: 2px; }
.cw-tip {
  position: relative; display: inline-block; margin-top: 4px; cursor: help;
  color: #d5e2ee; font-size: 0.75rem; border-bottom: 1px dotted #8aa0b4;
}
.cw-tip-box {
  display: none; position: fixed; z-index: 80; width: 260px; padding: 8px 10px;
  background: #0e1720; border: 1px solid #3d5166; border-radius: 6px; color: #d5e2ee;
  font-size: 0.75rem; font-weight: 400; line-height: 1.4; white-space: normal;
  box-shadow: 0 8px 20px rgba(0,0,0,0.35);
}
.cw-text .cw-unavail {
  color: #ffd0a8; font-size: 0.78rem; display: block; margin-top: 4px;
  font-weight: 600; line-height: 1.35;
}
.cw-time { color: #8aa0b4; font-size: 0.75rem; white-space: nowrap; }
.cw-go {
  white-space: nowrap; font-weight: 700; font-size: 0.8rem; text-decoration: none;
  color: #0f1720; background: #f5b041; padding: 4px 10px; border-radius: 999px;
}
.cw-go--plain { background: #2c3e50; color: #e6edf3; }
.cw-x { background: none; border: 0; color: #5d6d7e; cursor: pointer; font-size: 1rem; padding: 0 4px; }
.cw-x:hover { color: #fff; }
.cw-empty { padding: 9px 12px; color: #8aa0b4; font-size: 0.85rem; }
.cw-cutoffs { border-bottom: 1px solid #2c3e50; background: #121c26; }
.cw-cutoffs-head {
  padding: 6px 12px 2px; font-family: "Courier New", ui-monospace, monospace;
  font-size: 0.72rem; letter-spacing: 0.12em; text-transform: uppercase; color: #e67e22;
}
.cw-item.cw-sev-urgent { background: rgba(230,126,34,0.12); }
.cw-item.cw-sev-warn { background: rgba(245,176,65,0.08); }
a.nav-club-wire { position: relative; }
a.nav-club-wire .nav-club-wire-mark { font-size: 1rem; }
a.nav-club-wire .nav-club-wire-badge {
  position: absolute; top: -4px; right: -6px; min-width: 16px; height: 16px; padding: 0 4px;
  border-radius: 8px; background: #f5b041; color: #1b1300; font-size: 10px; font-weight: 700;
  line-height: 16px; text-align: center;
}
a.nav-club-wire.cw-pulse .nav-club-wire-badge { animation: cwPulse 1s ease-in-out 3; }
@keyframes cwPulse { 50% { transform: scale(1.35); } }
`;

let state = { count: 0, items: [], cutoffs: [] };
let strikeBoard = null;

function placeHoverBox(tip) {
  const box = tip.querySelector(":scope > .cw-tip-box, :scope > .mc-tip-box");
  if (!box) return;
  const r = tip.getBoundingClientRect();
  const width = 260;
  const left = Math.min(Math.max(8, r.left), Math.max(8, window.innerWidth - width - 8));
  box.style.display = "block";
  box.style.left = `${left}px`;
  const h = box.offsetHeight || 72;
  const below = r.bottom + 6;
  const top = below + h < window.innerHeight - 8 ? below : Math.max(8, r.top - h - 6);
  box.style.top = `${top}px`;
}

function hideHoverBox(tip) {
  const box = tip?.querySelector(":scope > .cw-tip-box, :scope > .mc-tip-box");
  if (box) box.style.display = "none";
}

function bindHoverTips(root) {
  if (!root || root.dataset.hoverTips === "1") return;
  root.dataset.hoverTips = "1";
  const tipFrom = (node) => node?.closest?.(".cw-tip");
  root.addEventListener("mouseover", (e) => {
    const tip = tipFrom(e.target);
    if (tip && root.contains(tip)) placeHoverBox(tip);
  });
  root.addEventListener("mouseout", (e) => {
    const tip = tipFrom(e.target);
    if (!tip || !root.contains(tip)) return;
    if (e.relatedTarget && tip.contains(e.relatedTarget)) return;
    hideHoverBox(tip);
  });
  root.addEventListener("focusin", (e) => {
    const tip = tipFrom(e.target);
    if (tip && root.contains(tip)) placeHoverBox(tip);
  });
  root.addEventListener("focusout", (e) => {
    const tip = tipFrom(e.target);
    if (!tip || !root.contains(tip)) return;
    if (e.relatedTarget && tip.contains(e.relatedTarget)) return;
    hideHoverBox(tip);
  });
  root.addEventListener("scroll", () => {
    root.querySelectorAll(".cw-tip").forEach(hideHoverBox);
  }, true);
}

function strikeTipHtml(fixtureId) {
  if (!strikeBoard || strikeBoard.ok === false || fixtureId == null) return "";
  const row = (strikeBoard.fixtures || []).find((f) => Number(f.fixture_id) === Number(fixtureId));
  const matchStrikes = Number(row?.fixture_strikes ?? 0);
  const seasonStrikes = Number(strikeBoard.season_strikes ?? 0);
  const help =
    `This match: ${matchStrikes} of 3. A third strike forfeits it and adds ₿1m. ` +
    `Season: ${seasonStrikes}. Each strike is ₿500k. Strike 5, 10, 15… adds ₿1m.`;
  return `<span class="cw-tip" tabindex="0">Strikes ${matchStrikes}/3 · season ${seasonStrikes}<span class="cw-tip-box">${esc(help)}</span></span>`;
}
let started = false;
let seenIds = new Set();
const listeners = new Set();

function ensureStyle() {
  if (document.getElementById("clubWireStyle")) return;
  const s = document.createElement("style");
  s.id = "clubWireStyle";
  s.textContent = STYLE;
  document.head.appendChild(s);
}

function esc(v) {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function money(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return "";
  return `₿${Math.round(n).toLocaleString("en-GB")}`;
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  return `${Math.floor(s / 3600)} h ago`;
}

function formatUk(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function relWhen(iso) {
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const diff = t - Date.now();
  const mins = Math.round(Math.abs(diff) / 60000);
  const txt =
    mins < 60
      ? `${mins}m`
      : mins < 2880
        ? `${Math.floor(mins / 60)}h`
        : `${Math.floor(mins / 1440)}d`;
  return diff >= 0 ? `in ${txt}` : `${txt} ago`;
}

function itemText(it) {
  const who = `<b>${esc(it.subject_name)}</b>`;
  const by = esc(it.by_label || "");
  const amt = money(it.amount);
  switch (it.kind) {
    case "outbid":
      return `${who} — ${by} now leads${amt ? ` at ${amt}` : ""}`;
    case "offer_accepted":
      return `${by} accepted your ${amt} offer for ${who} — it's now a 24h listing`;
    case "offer_rejected":
      return `${by} rejected your ${amt} offer for ${who}`;
    case "review_needed": {
      const bidBit = amt ? ` leading bid ${amt}` : " a leading bid";
      const fromBit = by ? ` from ${by}` : "";
      return `${who} needs your seller review —${bidBit}${fromBit}`;
    }
    case "under_review":
      return `Your bid for ${who}${amt ? ` (${amt})` : ""} is with ${
        by || "the seller"
      } for review`;
    case "review_accepted":
      return `Seller review accepted for ${who}${amt ? ` at ${amt}` : ""}${
        by ? ` (${by})` : ""
      }`;
    case "review_declined":
      return `Seller review declined for ${who}${amt ? ` at ${amt}` : ""}${
        by ? ` (${by})` : ""
      }`;
    case "won":
      return it.market === "wage_bid"
        ? `You won ${who}'s contract (your offer ${amt})`
        : `You won ${who}${amt ? ` for ${amt}` : ""}`;
    case "lost":
      if (it.market === "wage_bid") return `${who} went to ${by} (your offer ${amt})`;
      return by
        ? `${by} won ${who}${amt ? ` for ${amt}` : ""}`
        : `${who} ended with no winner`;
    default:
      return who;
  }
}

function actionHtml(it) {
  if (!it.href) return "";
  let label = "View →";
  if (it.kind === "outbid") label = "Rebid →";
  else if (it.kind === "review_needed") label = "Review →";
  const cls =
    it.kind === "outbid" || it.kind === "review_needed"
      ? "cw-go"
      : "cw-go cw-go--plain";
  return `<a class="${cls}" href="${esc(it.href)}">${label}</a>`;
}

function emit() {
  for (const fn of listeners) {
    try {
      fn(state);
    } catch (err) {
      console.warn("club wire listener:", err);
    }
  }
}

const UNAVAIL_CUTOFF_KINDS = new Set([
  "propose",
  "late_fee",
  "reply",
  "checkin",
]);

/** Expand RPC short codes (e.g. vs BOC) to full Clubs.Club names. */
function expandShortsInLabel(text) {
  return String(text || "")
    .replace(/\bvs\s+([A-Za-z0-9]{2,6})\b/gi, (_, code) => {
      const full = fullClubName(code);
      return `vs ${full || code}`;
    })
    .replace(
      /\b(@|against)\s+([A-Za-z0-9]{2,6})\b/gi,
      (_, prep, code) => `${prep} ${fullClubName(code) || code}`
    );
}

function oppShortFromCutoffTitle(title) {
  const m = String(title || "").match(/\b(?:vs|@|against)\s+([A-Za-z0-9]{2,6})\b/i);
  return m ? m[1] : null;
}

/** Hover text for opponent owner (Vacant when club known but no tag). */
function ownerHoverForCutoff(title) {
  const code = oppShortFromCutoffTitle(title);
  if (!code) return "";
  const full = fullClubName(code);
  if (!full || full === code) return "";
  const owner = ownerTagForClub(code);
  return owner ? `Owner: ${owner}` : "Owner: Vacant";
}

/** Attach own-club suspended/injured line onto propose / check-in cutoffs. */
async function enrichCutoffsWithUnavailable(cutoffs, clubShort) {
  if (!cutoffs?.length || !clubShort) return cutoffs || [];
  const ids = [
    ...new Set(
      cutoffs
        .filter((c) => UNAVAIL_CUTOFF_KINDS.has(c.kind) && c.fixture_id != null)
        .map((c) => Number(c.fixture_id))
        .filter((id) => Number.isFinite(id) && id > 0)
    ),
  ].slice(0, 10);

  if (!ids.length) return cutoffs;

  const payloads = await Promise.all(
    ids.map((id) => loadFixtureUnavailable(supabase, id))
  );
  const byId = new Map(ids.map((id, i) => [id, payloads[i]]));

  return cutoffs.map((c) => {
    if (!UNAVAIL_CUTOFF_KINDS.has(c.kind) || c.fixture_id == null) return c;
    const line = formatOwnUnavailableLine(
      byId.get(Number(c.fixture_id)),
      clubShort,
      { maxNames: 3 }
    );
    if (!line) return c;
    return { ...c, unavailable_line: line };
  });
}

/** Attach home club + matchday weather/pitch onto fixture cutoffs. */
async function enrichCutoffsWithHomeWeather(cutoffs) {
  if (!cutoffs?.length) return cutoffs || [];
  const ids = cutoffs.map((c) => c.fixture_id);
  const meta = await fetchFixturesHomeWeatherMeta(supabase, ids);
  if (!meta.size) return cutoffs;

  return cutoffs.map((c) => {
    if (c.fixture_id == null) return c;
    const m = meta.get(Number(c.fixture_id));
    if (!m) return c;
    const homeShort = String(m.home_club_short_name || "").toUpperCase();
    const homeName = fullClubName(homeShort) || homeShort;
    const wx = formatWeatherPitchPlain(m);
    const bits = [];
    if (homeName) bits.push(`Home ${homeName}`);
    if (wx) bits.push(wx);
    if (!bits.length) return c;
    const metaLine = bits.join(" · ");
    const detail = c.detail ? `${c.detail} · ${metaLine}` : metaLine;
    return {
      ...c,
      home_club_short_name: homeShort || c.home_club_short_name,
      weather: m.weather ?? null,
      pitch_condition: m.pitch_condition ?? null,
      kit_season: m.kit_season ?? null,
      detail,
    };
  });
}

const RESULT_RECOVER_HOURS = 24;

function dueMonthKey(fixture, months) {
  const fixMonth = String(fixture?.gpsl_month || "").trim().toLowerCase();
  const playAt = fixture?.agreed_kickoff_at || null;
  if (!playAt || !months.length) return fixMonth;
  const t = new Date(playAt).getTime();
  if (!Number.isFinite(t)) return fixMonth;
  let playMonth = null;
  let playSort = -Infinity;
  let fixSort = -Infinity;
  for (const m of months) {
    const key = String(m.gpsl_month || "").trim().toLowerCase();
    if (!key) continue;
    const order = Number(m.sort_order);
    const sort = Number.isFinite(order) ? order : 0;
    if (key === fixMonth) fixSort = sort;
    const unlockMs = m.unlock_at ? new Date(m.unlock_at).getTime() : NaN;
    if (!Number.isFinite(unlockMs) || unlockMs > t) continue;
    if (sort >= playSort) {
      playSort = sort;
      playMonth = key;
    }
  }
  if (playMonth && playSort > fixSort) return playMonth;
  return fixMonth || playMonth;
}

/** Next result deadline for each match where this club has not entered its side. */
async function loadWireResultDeadlines(clubShort) {
  const me = String(clubShort || "").trim().toUpperCase();
  if (!me) return [];

  let grace = 72;
  try {
    const { data, error } = await supabase.rpc("match_video_missing_fine_grace_hours");
    if (!error && Number(data) > 0) grace = Number(data);
  } catch {
    /* 72 */
  }

  const [fxRes, calRes] = await Promise.all([
    supabase
      .from("competition_fixtures_public")
      .select(
        "id, home_club_short_name, away_club_short_name, home_club_name, away_club_name, status, home_goals, away_goals, is_forfeit, submission_status, submitted_by_club, agreed_kickoff_at, gpsl_month, schedule_status"
      ),
    supabase
      .from("competition_season_calendar_public")
      .select("gpsl_month, lock_at, unlock_at, sort_order")
      .order("sort_order", { ascending: true }),
  ]);
  if (fxRes.error) throw fxRes.error;
  if (calRes.error) throw calRes.error;

  const months = calRes.data || [];
  const now = Date.now();
  const pastMs = 21 * 86400_000;
  const out = [];

  for (const f of fxRes.data || []) {
    const home = String(f.home_club_short_name || "").trim().toUpperCase();
    const away = String(f.away_club_short_name || "").trim().toUpperCase();
    if (home !== me && away !== me) continue;
    if (f.is_forfeit === true) continue;
    const ko = f.agreed_kickoff_at ? new Date(f.agreed_kickoff_at).getTime() : NaN;
    if (!Number.isFinite(ko) || ko > now) continue;

    const pending = String(f.submission_status || "").toLowerCase() === "pending";
    const enteredBy = String(f.submitted_by_club || "").trim().toUpperCase();
    if (pending && enteredBy === me) continue;
    const played = String(f.status || "").toLowerCase() === "played";
    if (!pending && played && f.home_goals != null && f.away_goals != null) continue;

    const monthKey = dueMonthKey(f, months);
    const month = months.find(
      (m) => String(m.gpsl_month || "").trim().toLowerCase() === monthKey
    );
    const lockMs = month?.lock_at ? new Date(month.lock_at).getTime() : NaN;
    if (!Number.isFinite(lockMs)) continue;

    const remindMs = lockMs + grace * 3600_000;
    const closeMs = remindMs + RESULT_RECOVER_HOURS * 3600_000;
    const arranged = String(f.schedule_status || "").toLowerCase() === "agreed";
    const oppShort = home === me ? f.away_club_short_name : f.home_club_short_name;
    const oppName = home === me ? f.away_club_name : f.home_club_name;
    const opp = fullClubName(oppShort) || oppName || oppShort || "opponent";
    const href = `matchday.html?fixture=${encodeURIComponent(String(f.id))}`;
    const events = [];

    if (closeMs > now - 3600_000) {
      events.push({
        id: `result_enter:${f.id}`,
        fixture_id: f.id,
        kind: "result_enter",
        at: new Date(remindMs).toISOString(),
        title: pending ? `Confirm result vs ${opp}` : `Enter result vs ${opp}`,
        detail: pending
          ? "Your opponent has entered a score. ₿500,000 if you have not confirmed by this time."
          : `₿500,000 if your result is still not in. You then have ${RESULT_RECOVER_HOURS} hours to finish it.`,
        href,
        severity: remindMs - now <= 24 * 3600_000 ? "urgent" : "warn",
      });
    }
    if (pending || arranged) {
      events.push({
        id: `result_close:${f.id}`,
        fixture_id: f.id,
        kind: "result_close",
        at: new Date(closeMs).toISOString(),
        title: pending ? `Score confirmed vs ${opp}` : `Result extension vs ${opp}`,
        detail: pending
          ? "If you still have not confirmed, another ₿500,000 and their score is confirmed. Starters are rated 3. It cannot be edited."
          : "No score in. Another ₿500,000 to each club. The result stays open.",
        href,
        severity: closeMs - now <= 24 * 3600_000 ? "urgent" : "warn",
      });
    }

    if (!pending) {
      const dueSort = Number(month?.sort_order);
      if (Number.isFinite(dueSort)) {
        const later = months
          .filter((m) => Number(m.sort_order) > dueSort && m.lock_at)
          .sort((a, b) => Number(a.sort_order) - Number(b.sort_order));
        for (const m of later) {
          const lockAt = new Date(m.lock_at).getTime();
          if (!Number.isFinite(lockAt)) continue;
          const step = Number(m.sort_order) - dueSort;
          const label = m.gpsl_month || "that month";
          if (step >= 2) {
            events.push({
              id: `result_void:${f.id}`,
              fixture_id: f.id,
              kind: "result_void",
              at: new Date(lockAt).toISOString(),
              title: `Result void vs ${opp}`,
              detail: "Two months after the played month. If there is still no score, the match is void. Neither club gets the result. It counts as played.",
              href,
              severity: "warn",
            });
            break;
          }
          if (arranged) {
            events.push({
              id: `result_month:${f.id}:${String(m.gpsl_month || "").toLowerCase()}`,
              fixture_id: f.id,
              kind: "result_month",
              at: new Date(lockAt).toISOString(),
              title: `Result still open vs ${opp}`,
              detail: `Another ₿500,000 at the ${label} lock while the match is still arranged and no score is in.`,
              href,
              severity: "info",
            });
          }
        }
      }
    }

    const upcoming = events
      .filter((e) => new Date(e.at).getTime() >= now)
      .sort((a, b) => new Date(a.at) - new Date(b.at));
    const recent = events
      .filter((e) => {
        const t = new Date(e.at).getTime();
        return t < now && t >= now - pastMs;
      })
      .sort((a, b) => new Date(b.at) - new Date(a.at));
    const next = upcoming[0] || recent[0];
    if (next) out.push(next);
  }

  return out;
}

async function poll() {
  if (document.hidden) return;
  try {
    try {
      await loadClubsMap();
    } catch (err) {
      console.warn("club wire loadClubsMap:", err);
    }
    const [wireRes, cutRes, strikeRes] = await Promise.all([
      supabase.rpc("club_wire_list", { p_limit: 8 }),
      supabase.rpc("club_wire_cutoffs"),
      supabase.rpc("my_club_strike_board"),
    ]);
    if (!strikeRes.error) strikeBoard = strikeRes.data;
    if (wireRes.error) {
      console.warn("club_wire_list:", wireRes.error.message);
    }
    const items = Array.isArray(wireRes.data?.items) ? wireRes.data.items : [];
    let cutoffs = Array.isArray(cutRes.data?.cutoffs) ? cutRes.data.cutoffs : [];
    if (cutRes.error) {
      console.warn("club_wire_cutoffs:", cutRes.error.message);
    }
    let clubShort =
      cutRes.data?.club_short_name || wireRes.data?.club_short_name || null;
    if (!clubShort) {
      try {
        const { data: auth } = await supabase.auth.getUser();
        if (auth?.user?.id) {
          const { data: club } = await supabase
            .from("Clubs")
            .select("ShortName")
            .eq("owner_id", auth.user.id)
            .maybeSingle();
          clubShort = club?.ShortName || null;
        }
      } catch (err) {
        console.warn("club wire club:", err);
      }
    }
    try {
      const results = await loadWireResultDeadlines(clubShort);
      const seen = new Set(cutoffs.map((c) => c?.id).filter(Boolean));
      const coveredFixture = new Set(
        cutoffs
          .filter((c) =>
            ["result_enter", "result_close", "result_video", "video", "video_suspend"].includes(
              c?.kind
            )
          )
          .map((c) => String(c.fixture_id))
      );
      for (const row of results) {
        if (seen.has(row.id) || coveredFixture.has(String(row.fixture_id))) continue;
        seen.add(row.id);
        cutoffs.push(row);
      }
      cutoffs.sort((a, b) => new Date(a?.at).getTime() - new Date(b?.at).getTime());
    } catch (err) {
      console.warn("club wire result deadlines:", err);
    }
    try {
      cutoffs = await enrichCutoffsWithUnavailable(cutoffs, clubShort);
    } catch (err) {
      console.warn("club wire unavailable enrich:", err);
    }
    try {
      cutoffs = await enrichCutoffsWithHomeWeather(cutoffs);
    } catch (err) {
      console.warn("club wire home/weather enrich:", err);
    }
    state = {
      count: Number(wireRes.data?.count) || 0,
      items,
      cutoffs,
    };
    emit();
  } catch (err) {
    console.warn("club wire poll:", err);
  }
}

export function startClubWire() {
  if (started) return;
  started = true;
  ensureStyle();
  bindHoverTips(document.getElementById("clubWire"));
  void poll();
  setInterval(poll, POLL_MS);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) void poll();
  });
}

export function refreshClubWire() {
  return poll();
}

async function dismiss(id) {
  const { error } = await supabase.rpc("club_wire_dismiss", { p_id: id ?? null });
  if (error) {
    console.warn("club_wire_dismiss:", error.message);
    return;
  }
  state = id == null
    ? { count: 0, items: [], cutoffs: state.cutoffs || [] }
    : {
        count: Math.max(0, state.count - 1),
        items: state.items.filter((i) => i.id !== id),
        cutoffs: state.cutoffs || [],
      };
  emit();
  void poll();
}

/**
 * Nav shortcut with a count badge (only shown while there are alerts).
 * @param {HTMLElement} nav
 * @param {{ href?: string }} [opts]
 */
export function mountClubWireNavBadge(nav, opts = {}) {
  if (!nav) return;
  ensureStyle();
  const actions = nav.querySelector(".gpsl-nav-actions-primary");
  if (!actions) return;

  let link = actions.querySelector("a.nav-club-wire");
  if (!link) {
    link = document.createElement("a");
    link.className = "nav-shortcut nav-club-wire";
    link.href = opts.href || "dashboard.html#clubWire";
    link.title = "Club Wire — outbid alerts";
    link.innerHTML = `<span class="nav-club-wire-mark" aria-hidden="true">⚡</span>`;
    link.hidden = true;
    const before = actions.querySelector("a.nav-inbox, .nav-theme-toggle, #logoutBtn");
    actions.insertBefore(link, before || null);
  }

  let lastCount = 0;
  listeners.add((s) => {
    const n = s.count;
    link.hidden = n <= 0;
    link.setAttribute("aria-label", n > 0 ? `Club Wire, ${n} alert${n === 1 ? "" : "s"}` : "Club Wire");
    let badge = link.querySelector(".nav-club-wire-badge");
    if (n > 0) {
      if (!badge) {
        badge = document.createElement("span");
        badge.className = "nav-club-wire-badge";
        link.appendChild(badge);
      }
      badge.textContent = n > 99 ? "99+" : String(n);
      if (n > lastCount) {
        link.classList.remove("cw-pulse");
        void link.offsetWidth;
        link.classList.add("cw-pulse");
      }
    } else if (badge) {
      badge.remove();
    }
    lastCount = n;
  });

  startClubWire();
}

function cutoffRowsHtml(cutoffs) {
  if (!cutoffs?.length) return "";
  const rows = cutoffs
    .map((c) => {
      const [label, cls] = CUTOFF_BADGE[c.kind] || ["CUTOFF", "cw-badge--cutoff"];
      const sev = c.severity === "urgent" || c.severity === "warn" ? ` cw-sev-${c.severity}` : "";
      const goLabel =
        c.kind === "video" || c.kind === "video_suspend"
          ? "Upload →"
          : c.kind === "result_enter"
            ? "Enter →"
            : c.kind === "result_close"
              ? "Confirm →"
              : "Open →";
      const go = c.href
        ? `<a class="cw-go cw-go--plain" href="${esc(c.href)}">${goLabel}</a>`
        : "";
      const title = expandShortsInLabel(c.title);
      const ownerHover = ownerHoverForCutoff(c.title);
      const titleAttr = ownerHover ? ` title="${esc(ownerHover)}"` : "";
      return `
        <li class="cw-item${sev}">
          <span class="cw-badge ${cls}">${label}</span>
          <span class="cw-text">
            <b${titleAttr}>${esc(title)}</b>
            ${c.detail ? `<span class="cw-detail">${esc(c.detail)}</span>` : ""}
            ${strikeTipHtml(c.fixture_id)}
            ${
              c.unavailable_line
                ? `<span class="cw-unavail">${esc(c.unavailable_line)}</span>`
                : ""
            }
          </span>
          <span class="cw-time" title="${esc(formatUk(c.at))} UK">${relWhen(c.at)}<br>${esc(formatUk(c.at))}</span>
          ${go}
        </li>`;
    })
    .join("");
  return `
    <div class="cw-cutoffs">
      <div class="cw-cutoffs-head">Cutoffs · fines, forfeits, videos &amp; results</div>
      <ul class="cw-list">${rows}</ul>
    </div>`;
}

function isWireCollapsed() {
  try {
    return localStorage.getItem(COLLAPSE_KEY) === "1";
  } catch {
    return false;
  }
}

function setWireCollapsed(v) {
  try {
    localStorage.setItem(COLLAPSE_KEY, v ? "1" : "0");
  } catch {
    /* ignore */
  }
}

/** Dashboard card. */
export function mountClubWireCard(host) {
  if (!host) return;
  ensureStyle();

  const render = (s) => {
    const items = s.items || [];
    const cutoffs = s.cutoffs || [];
    const rows = items
      .map((it) => {
        const [label, cls] = KIND_BADGE[it.kind] || ["ALERT", "cw-badge--bad"];
        const fresh = !seenIds.has(it.id) && seenIds.size > 0;
        return `
        <li class="cw-item${fresh ? " cw-fresh" : ""}" data-id="${it.id}">
          <span class="cw-badge ${cls}">${label}</span>
          <span class="cw-text">
            <span class="cw-market">${esc(MARKET_LABEL[it.market] || "")}</span>
            ${itemText(it)}
          </span>
          <span class="cw-time">${ago(it.updated_at)}</span>
          ${actionHtml(it)}
          <button type="button" class="cw-x" title="Dismiss" aria-label="Dismiss">✕</button>
        </li>`;
      })
      .join("");
    items.forEach((it) => seenIds.add(it.id));
    if (!seenIds.size) seenIds.add(-1);

    const alertsBody = items.length
      ? `<ul class="cw-list">${rows}</ul>`
      : `<div class="cw-empty">${cutoffs.length ? "No market alerts — cutoffs above." : "All quiet — no outbids, results, or cutoffs right now."}</div>`;

    const collapsed = isWireCollapsed();
    const openCount = items.length + cutoffs.length;
    host.innerHTML = `
      <section class="cw-card" aria-label="Club Wire">
        <div class="cw-head">
          <span class="cw-live" aria-hidden="true"></span>
          <span class="cw-title">Club Wire</span>
          <span class="cw-sub">${collapsed && openCount ? `${openCount} open` : "Cutoffs · videos · outbids &amp; results"}</span>
          ${items.length ? `<button type="button" class="cw-clear">Clear all</button>` : ""}
          <button type="button" class="cw-toggle" aria-expanded="${collapsed ? "false" : "true"}">${collapsed ? "Show" : "Hide"}</button>
        </div>
        <div class="cw-body"${collapsed ? " hidden" : ""}>
          ${cutoffRowsHtml(cutoffs)}
          ${alertsBody}
        </div>
      </section>`;
    host.hidden = false;

    host.querySelectorAll(".cw-x").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = Number(btn.closest(".cw-item")?.dataset.id);
        if (id) void dismiss(id);
      });
    });
    host.querySelector(".cw-clear")?.addEventListener("click", () => void dismiss(null));
    host.querySelector(".cw-toggle")?.addEventListener("click", () => {
      setWireCollapsed(!isWireCollapsed());
      render(state);
    });
  };

  listeners.add(render);
  render(state);
  startClubWire();
  void poll();
}
