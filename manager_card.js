/**
 * Manager card pop-up — portrait, ratings, all playstyle proficiencies,
 * player boost bands and board expectations. Reads managers_gpdb_public.
 *
 *   openManagerCard(managerId, { onBid, bidLabel })
 */
import { supabase } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import { applyManagerPortrait, managerInitials } from "./manager_images.js";

const PLAYSTYLES = [
  { key: "possession", label: "Possession" },
  { key: "quick_counter", label: "Quick Counter" },
  { key: "long_ball_counter", label: "Long Ball Counter" },
  { key: "out_wide", label: "Out Wide" },
  { key: "long_ball", label: "Long Ball" },
  { key: "overload", label: "Overload" },
];

const BAR_MIN = 40;
const BAR_MAX = 99;

let stylesInjected = false;
let overlay = null;
let openSeq = 0;

function esc(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function injectStyles() {
  if (stylesInjected) return;
  stylesInjected = true;
  const css = document.createElement("style");
  css.textContent = `
.mgr-card-overlay { position: fixed; inset: 0; z-index: 120; background: rgba(0,0,0,.78);
  display: flex; align-items: center; justify-content: center; padding: 16px; }
.mgr-card-overlay[hidden] { display: none; }
.mgr-card { position: relative; width: 100%; max-width: 460px; max-height: calc(100vh - 32px); overflow-y: auto;
  background: linear-gradient(180deg, #1c1608 0%, #121212 38%); border: 1px solid #6b5418; border-radius: 12px;
  box-shadow: 0 12px 40px rgba(0,0,0,.6), inset 0 1px 0 rgba(255,204,102,.15); color: #ddd; text-align: left; }
.mgr-card-close { position: absolute; top: 8px; right: 10px; background: none; border: 0; color: #aaa;
  font-size: 22px; line-height: 1; cursor: pointer; padding: 4px; }
.mgr-card-close:hover { color: #fff; }
.mgr-card-head { display: flex; gap: 14px; align-items: center; padding: 18px 18px 12px; }
.mgr-card-photo { width: 84px; height: 84px; flex-shrink: 0; border-radius: 10px; overflow: hidden;
  background: #0a0a0a; border: 1px solid #6b5418; display: flex; align-items: center; justify-content: center; }
.mgr-card-photo img { width: 100%; height: 100%; object-fit: cover; display: block; }
.mgr-card-initials { font-size: 26px; font-weight: bold; color: #ffcc66; letter-spacing: 1px; }
.mgr-card-id { flex: 1; min-width: 0; }
.mgr-card-name { margin: 0; font-size: 20px; color: #ffcc66; line-height: 1.2; padding-right: 22px; }
.mgr-card-sub { font-size: 12px; color: #aaa; margin-top: 4px; }
.mgr-card-club { font-size: 12px; margin-top: 3px; color: #ddd; }
.mgr-card-club.is-fa { color: #8fbf6a; font-weight: bold; }
.mgr-card-ovr { flex-shrink: 0; width: 58px; height: 58px; border-radius: 50%; display: flex; flex-direction: column;
  align-items: center; justify-content: center; background: #ffcc66; color: #1a1205; font-weight: bold; }
.mgr-card-ovr b { font-size: 22px; line-height: 1; }
.mgr-card-ovr span { font-size: 9px; letter-spacing: .5px; text-transform: uppercase; }
.mgr-card-stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1px; background: #2a2a2a;
  border-top: 1px solid #2a2a2a; border-bottom: 1px solid #2a2a2a; }
.mgr-card-stat { background: #151515; padding: 8px 10px; }
.mgr-card-stat small { display: block; font-size: 10px; color: #888; text-transform: uppercase; letter-spacing: .4px; }
.mgr-card-stat b { font-size: 13px; color: #eee; }
.mgr-card-section { padding: 12px 18px; }
.mgr-card-section h4 { margin: 0 0 8px; font-size: 11px; color: #ffcc66; text-transform: uppercase; letter-spacing: .6px; }
.mgr-card-ps { display: grid; grid-template-columns: 128px 1fr 30px; align-items: center; gap: 8px;
  font-size: 12px; margin-bottom: 6px; }
.mgr-card-ps-label { color: #ccc; white-space: nowrap; }
.mgr-card-ps.is-best .mgr-card-ps-label { color: #ffcc66; font-weight: bold; }
.mgr-card-ps-bar { height: 8px; background: #262626; border-radius: 4px; overflow: hidden; }
.mgr-card-ps-fill { height: 100%; border-radius: 4px; }
.mgr-card-ps-val { text-align: right; font-weight: bold; font-variant-numeric: tabular-nums; }
.mgr-card-tier-elite { background: #8fbf6a; color: #8fbf6a; }
.mgr-card-tier-good { background: #ffcc33; color: #ffcc33; }
.mgr-card-tier-ok { background: #ff9933; color: #ff9933; }
.mgr-card-tier-low { background: #666; color: #888; }
.mgr-card-ps-val.mgr-card-tier-elite, .mgr-card-ps-val.mgr-card-tier-good,
.mgr-card-ps-val.mgr-card-tier-ok, .mgr-card-ps-val.mgr-card-tier-low { background: none; }
.mgr-card-chips { display: flex; flex-wrap: wrap; gap: 6px; font-size: 12px; }
.mgr-card-chip { background: #1e1e1e; border: 1px solid #333; border-radius: 999px; padding: 3px 10px; color: #ddd; }
.mgr-card-foot { display: flex; justify-content: space-between; align-items: center; gap: 10px;
  padding: 12px 18px 16px; border-top: 1px solid #2a2a2a; }
.mgr-card-foot a { color: #ffcc66; font-size: 12px; text-decoration: none; }
.mgr-card-foot a:hover { text-decoration: underline; }
.mgr-card-msg { padding: 30px 18px; text-align: center; color: #aaa; }
@media (max-width: 420px) {
  .mgr-card-ps { grid-template-columns: 104px 1fr 28px; }
  .mgr-card-stats { grid-template-columns: repeat(2, 1fr); }
}`;
  document.head.appendChild(css);
}

function ensureOverlay() {
  if (overlay) return overlay;
  injectStyles();
  overlay = document.createElement("div");
  overlay.className = "mgr-card-overlay";
  overlay.hidden = true;
  overlay.innerHTML = `<div class="mgr-card" role="dialog" aria-modal="true" aria-label="Manager card"></div>`;
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay || e.target.closest(".mgr-card-close")) closeManagerCard();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && overlay && !overlay.hidden) closeManagerCard();
  });
  document.body.appendChild(overlay);
  return overlay;
}

export function closeManagerCard() {
  openSeq += 1;
  if (overlay) overlay.hidden = true;
}

function tierClass(v) {
  if (v >= 85) return "mgr-card-tier-elite";
  if (v >= 80) return "mgr-card-tier-good";
  if (v >= 75) return "mgr-card-tier-ok";
  return "mgr-card-tier-low";
}

function playstyleRowsHtml(mgr) {
  const vals = PLAYSTYLES.map((p) => ({ ...p, v: Number(mgr[p.key]) || 0 }));
  const best = Math.max(...vals.map((p) => p.v));
  return vals
    .map((p) => {
      const pct = Math.max(
        3,
        Math.min(100, ((p.v - BAR_MIN) / (BAR_MAX - BAR_MIN)) * 100)
      );
      const tier = tierClass(p.v);
      const isBest = p.v > 0 && p.v === best;
      return `<div class="mgr-card-ps${isBest ? " is-best" : ""}">
        <span class="mgr-card-ps-label">${isBest ? "★ " : ""}${esc(p.label)}</span>
        <span class="mgr-card-ps-bar"><span class="mgr-card-ps-fill ${tier}" style="width:${p.v ? pct.toFixed(1) : 0}%"></span></span>
        <span class="mgr-card-ps-val ${tier}">${p.v || "—"}</span>
      </div>`;
    })
    .join("");
}

function expectationsHtml(mgr) {
  const rows = [
    ["Superleague", mgr.target_superleague],
    ["Championship A", mgr.target_championship_a],
    ["Championship B", mgr.target_championship_b],
  ].filter(([, v]) => v);
  if (!rows.length) return "";
  return `<div class="mgr-card-section">
    <h4>Board expectation</h4>
    <div class="mgr-card-chips">${rows
      .map(([k, v]) => `<span class="mgr-card-chip">${esc(k)}: <b>${esc(v)}</b></span>`)
      .join("")}</div>
  </div>`;
}

function boostsHtml(mgr) {
  const bands = [mgr.boost1_label, mgr.boost2_label, mgr.boost3_label].filter(Boolean);
  if (!bands.length) return "";
  return `<div class="mgr-card-section">
    <h4>Player boost</h4>
    <div class="mgr-card-chips">${bands
      .map((b) => `<span class="mgr-card-chip">${esc(b)}</span>`)
      .join("")}</div>
  </div>`;
}

function cardHtml(mgr, opts) {
  const club = String(mgr.contracted_club || "").trim();
  const clubLabel = club ? fullClubName(club) || club : "Free agent";
  const meta = [mgr.nation, mgr.age != null ? `Age ${mgr.age}` : null]
    .filter(Boolean)
    .map(esc)
    .join(" · ");
  const contract =
    club && mgr.contract_seasons_remaining != null
      ? `${mgr.contract_seasons_remaining} season${Number(mgr.contract_seasons_remaining) === 1 ? "" : "s"}`
      : "—";
  const wage = Number(mgr.weekly_wage) > 0 ? `${formatMoney(mgr.weekly_wage)}/wk` : "—";

  return `
    <button type="button" class="mgr-card-close" aria-label="Close">×</button>
    <div class="mgr-card-head">
      <div class="mgr-card-photo">
        <img class="mgr-card-img" alt="" style="display:none">
        <span class="mgr-card-initials">${esc(managerInitials(mgr.name))}</span>
      </div>
      <div class="mgr-card-id">
        <h3 class="mgr-card-name">${esc(mgr.name || "Manager")}</h3>
        <div class="mgr-card-sub">${meta || "—"}</div>
        <div class="mgr-card-club${club ? "" : " is-fa"}">${esc(clubLabel)}</div>
      </div>
      <div class="mgr-card-ovr" title="Manager rating"><b>${esc(mgr.rating ?? "—")}</b><span>Rating</span></div>
    </div>
    <div class="mgr-card-stats">
      <div class="mgr-card-stat"><small>Market value</small><b>${formatMoney(mgr.market_value)}</b></div>
      <div class="mgr-card-stat"><small>Wage</small><b>${wage}</b></div>
      <div class="mgr-card-stat"><small>Contract left</small><b>${contract}</b></div>
    </div>
    <div class="mgr-card-section">
      <h4>Playstyle proficiency</h4>
      ${playstyleRowsHtml(mgr)}
    </div>
    ${boostsHtml(mgr)}
    ${expectationsHtml(mgr)}
    <div class="mgr-card-foot">
      <a href="manager_career.html?manager=${encodeURIComponent(mgr.id)}">Career &amp; trophies →</a>
      ${opts.onBid ? `<button type="button" class="button mgr-card-bid">${esc(opts.bidLabel || "Bid")}</button>` : ""}
    </div>`;
}

async function fetchManager(managerId) {
  const { data, error } = await supabase
    .from("managers_gpdb_public")
    .select("*")
    .eq("id", managerId)
    .maybeSingle();
  if (!error && data) return data;
  const { data: raw } = await supabase
    .from("Managers")
    .select(
      "id, slug, name, nation, age, rating, market_value, weekly_wage, contracted_club, contract_seasons_remaining, possession, quick_counter, long_ball_counter, out_wide, long_ball, overload"
    )
    .eq("id", managerId)
    .maybeSingle();
  return raw || null;
}

/** Open the card. `onBid` (optional) adds a Bid button that closes the card then calls it. */
export async function openManagerCard(managerId, opts = {}) {
  const id = Number(managerId);
  if (!Number.isFinite(id)) return;
  const el = ensureOverlay();
  const box = el.querySelector(".mgr-card");
  const seq = ++openSeq;
  box.innerHTML = `<button type="button" class="mgr-card-close" aria-label="Close">×</button><div class="mgr-card-msg">Loading manager…</div>`;
  el.hidden = false;

  const [mgr] = await Promise.all([fetchManager(id), loadClubsMap().catch(() => null)]);
  if (seq !== openSeq) return;
  if (!mgr) {
    box.innerHTML = `<button type="button" class="mgr-card-close" aria-label="Close">×</button><div class="mgr-card-msg">Manager not found.</div>`;
    return;
  }

  box.innerHTML = cardHtml(mgr, opts);
  applyManagerPortrait(box.querySelector(".mgr-card-img"), mgr.slug, {
    fallbackEl: box.querySelector(".mgr-card-initials"),
    name: mgr.name,
  }).catch(() => {});

  box.querySelector(".mgr-card-bid")?.addEventListener("click", () => {
    closeManagerCard();
    opts.onBid?.(mgr);
  });
}
