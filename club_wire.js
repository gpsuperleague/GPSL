/**
 * Club Wire — outbid / offer / result alerts (dashboard card + nav badge).
 * One shared poll per tab (club_wire_list, ~60s, paused while hidden).
 */
import { supabase } from "./supabase_client.js";

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
  won: ["WON", "cw-badge--good"],
  lost: ["LOST", "cw-badge--bad"],
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
.cw-text { flex: 1 1 auto; min-width: 0; line-height: 1.3; }
.cw-text .cw-market { color: #8aa0b4; font-size: 0.75rem; display: block; }
.cw-time { color: #8aa0b4; font-size: 0.75rem; white-space: nowrap; }
.cw-go {
  white-space: nowrap; font-weight: 700; font-size: 0.8rem; text-decoration: none;
  color: #0f1720; background: #f5b041; padding: 4px 10px; border-radius: 999px;
}
.cw-go--plain { background: #2c3e50; color: #e6edf3; }
.cw-x { background: none; border: 0; color: #5d6d7e; cursor: pointer; font-size: 1rem; padding: 0 4px; }
.cw-x:hover { color: #fff; }
.cw-empty { padding: 9px 12px; color: #8aa0b4; font-size: 0.85rem; }
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

let state = { count: 0, items: [] };
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
  const label = it.kind === "outbid" ? "Rebid →" : "View →";
  const cls = it.kind === "outbid" ? "cw-go" : "cw-go cw-go--plain";
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

async function poll() {
  if (document.hidden) return;
  try {
    const { data, error } = await supabase.rpc("club_wire_list", { p_limit: 8 });
    if (error) return;
    const items = Array.isArray(data?.items) ? data.items : [];
    state = { count: Number(data?.count) || 0, items };
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
    ? { count: 0, items: [] }
    : {
        count: Math.max(0, state.count - 1),
        items: state.items.filter((i) => i.id !== id),
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

/** Dashboard card. */
export function mountClubWireCard(host) {
  if (!host) return;
  ensureStyle();

  const render = (s) => {
    const items = s.items || [];
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

    host.innerHTML = `
      <section class="cw-card" aria-label="Club Wire">
        <div class="cw-head">
          <span class="cw-live" aria-hidden="true"></span>
          <span class="cw-title">Club Wire</span>
          <span class="cw-sub">Outbids &amp; results · last 24h</span>
          ${items.length ? `<button type="button" class="cw-clear">Clear all</button>` : ""}
        </div>
        ${items.length
          ? `<ul class="cw-list">${rows}</ul>`
          : `<div class="cw-empty">All quiet — no outbids or results right now.</div>`}
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
