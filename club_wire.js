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

const POLL_MS = 60000;

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
};

const STYLE = `
.cw-card {
  margin: 10px 0 14px; border-radius: 10px; overflow: hidden;
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
.cw-head .cw-sub { color: #8aa0b4; font-size: 0.78rem; }
.cw-head .cw-clear {
  margin-left: auto; background: none; border: 1px solid #34495e; color: #8aa0b4;
  border-radius: 999px; padding: 2px 10px; font-size: 0.75rem; cursor: pointer;
}
.cw-head .cw-clear:hover { color: #fff; border-color: #5d6d7e; }
.cw-list { list-style: none; margin: 0; padding: 0; }
.cw-item {
  display: flex; align-items: center; gap: 10px; padding: 8px 12px;
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

async function poll() {
  if (document.hidden) return;
  try {
    try {
      await loadClubsMap();
    } catch (err) {
      console.warn("club wire loadClubsMap:", err);
    }
    const [wireRes, cutRes] = await Promise.all([
      supabase.rpc("club_wire_list", { p_limit: 8 }),
      supabase.rpc("club_wire_cutoffs"),
    ]);
    if (wireRes.error) {
      console.warn("club_wire_list:", wireRes.error.message);
    }
    const items = Array.isArray(wireRes.data?.items) ? wireRes.data.items : [];
    let cutoffs = Array.isArray(cutRes.data?.cutoffs) ? cutRes.data.cutoffs : [];
    if (cutRes.error) {
      console.warn("club_wire_cutoffs:", cutRes.error.message);
    }
    const clubShort =
      cutRes.data?.club_short_name || wireRes.data?.club_short_name || null;
    try {
      cutoffs = await enrichCutoffsWithUnavailable(cutoffs, clubShort);
    } catch (err) {
      console.warn("club wire unavailable enrich:", err);
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
        c.kind === "video" || c.kind === "video_suspend" ? "Upload →" : "Open →";
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
      <div class="cw-cutoffs-head">Cutoffs · fines, forfeits &amp; videos</div>
      <ul class="cw-list">${rows}</ul>
    </div>`;
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

    host.innerHTML = `
      <section class="cw-card" aria-label="Club Wire">
        <div class="cw-head">
          <span class="cw-live" aria-hidden="true"></span>
          <span class="cw-title">Club Wire</span>
          <span class="cw-sub">Cutoffs · videos · outbids &amp; results</span>
          ${items.length ? `<button type="button" class="cw-clear">Clear all</button>` : ""}
        </div>
        ${cutoffRowsHtml(cutoffs)}
        ${alertsBody}
      </section>`;
    host.hidden = false;

    host.querySelectorAll(".cw-x").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = Number(btn.closest(".cw-item")?.dataset.id);
        if (id) void dismiss(id);
      });
    });
    host.querySelector(".cw-clear")?.addEventListener("click", () => void dismiss(null));
  };

  listeners.add(render);
  render(state);
  startClubWire();
  void poll();
}
