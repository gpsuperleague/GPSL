import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";
import {
  loadClubsMap,
  fullClubName,
  ownerTagForClub,
  ownerIdForClub,
  ownerTagLinkHtml,
} from "./clubs_lookup.js";

/** Club behind a selection: club markets key on ShortName; player markets carry metadata.club. */
function selectionClub(sel) {
  const metaClub = String(sel?.metadata?.club || "").trim();
  if (metaClub) return metaClub;
  const key = String(sel?.selection_key || "").trim();
  return key && fullClubName(key) !== key ? key : "";
}

function isOwnSelection(sel) {
  const club = selectionClub(sel);
  return Boolean(club && currentClub && club.toUpperCase() === String(currentClub).toUpperCase());
}

/** Club-market selection for a club with no owner — always finishes bottom, so no odds offered. */
function isVacantClubSelection(sel) {
  if (sel?.metadata?.club) return false;
  const club = selectionClub(sel);
  return Boolean(club && !ownerTagForClub(club));
}

function selectionOwnerTagHtml(sel) {
  const club = selectionClub(sel);
  if (!club) return "";
  const tag = ownerTagForClub(club);
  if (!tag) return ` <span class="club-owner-tag club-owner-tag--vacant">Vacant</span>`;
  return ` ${ownerTagLinkHtml(tag, ownerIdForClub(club))}`;
}

function formatFractionalOdds(decimalOdds, fractionalLabel) {
  if (fractionalLabel && String(fractionalLabel).trim() && fractionalLabel !== "—") {
    return String(fractionalLabel).trim();
  }
  const d = Number(decimalOdds);
  if (!Number.isFinite(d) || d <= 1) return "—";
  const profit = d - 1;
  let bestN = 1;
  let bestD = 1;
  let bestErr = Infinity;
  for (let den = 1; den <= 20; den++) {
    const num = Math.max(1, Math.round(profit * den));
    const err = Math.abs(num / den - profit);
    if (err < bestErr - 1e-12 || (Math.abs(err - bestErr) < 1e-12 && den < bestD)) {
      bestErr = err;
      bestN = num;
      bestD = den;
    }
  }
  let g = 1;
  for (let i = Math.min(bestN, bestD); i >= 1; i--) {
    if (bestN % i === 0 && bestD % i === 0) {
      g = i;
      break;
    }
  }
  return `${bestN / g}-${bestD / g}`;
}

let currentClub = null;
let ownerTag = null;
let currentUserId = null;
let isAdmin = false;
let markets = [];
let selectionsByMarket = new Map();
let myBets = [];
/** @type {Array<Record<string, unknown>>} */
let allBetsAdmin = [];
let slipsTab = "mine";
/** @type {Map<number, { running: boolean, reason: string|null, cupClubs: Set<string>|null }>} */
let marketStates = new Map();

async function loadMarketStates() {
  marketStates = new Map();
  const { data, error } = await supabase.rpc("bookies_market_states");
  if (error) {
    console.warn("bookies_market_states:", error.message);
    return;
  }
  for (const s of Array.isArray(data) ? data : []) {
    marketStates.set(Number(s.market_id), {
      running: s.running !== false,
      reason: s.reason || null,
      cupClubs: Array.isArray(s.cup_clubs)
        ? new Set(s.cup_clubs.map((c) => String(c).toUpperCase()))
        : null,
    });
  }
}

function marketState(marketId) {
  return marketStates.get(Number(marketId)) || { running: true, reason: null, cupClubs: null };
}

function setStatus(msg, ok = true) {
  const el = document.getElementById("bkStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("err", !ok);
}

async function resolveAdmin() {
  try {
    const { data, error } = await supabase.rpc("is_gpsl_admin");
    if (!error) return Boolean(data);
  } catch (_) {
    /* ignore */
  }
  return false;
}

async function loadHeader() {
  const tagEl = document.getElementById("bkOwnerTag");
  const balEl = document.getElementById("bkBalance");
  if (tagEl) tagEl.textContent = ownerTag || "—";

  const { data, error } = await supabase.rpc("owner_wallet_get_self");
  if (error) {
    if (balEl) balEl.textContent = "—";
    return;
  }
  if (balEl) balEl.textContent = formatMoney(data?.balance ?? 0);
}

async function loadMarkets() {
  const { data, error } = await supabase
    .from("bookies_markets_public")
    .select("*")
    .order("id", { ascending: true });

  if (error) {
    setStatus(
      error.message.includes("bookies_markets")
        ? "Run supabase/sql/patches/gpsl_bookies_20260815.sql first."
        : error.message,
      false
    );
    markets = [];
    return;
  }
  markets = data || [];

  const { data: sels, error: sErr } = await supabase
    .from("bookies_selections_public")
    .select("*")
    .order("sort_order", { ascending: true });

  if (sErr) {
    setStatus(sErr.message, false);
    selectionsByMarket = new Map();
    return;
  }

  selectionsByMarket = new Map();
  for (const s of sels || []) {
    if (!selectionsByMarket.has(s.market_id)) selectionsByMarket.set(s.market_id, []);
    selectionsByMarket.get(s.market_id).push(s);
  }
  for (const list of selectionsByMarket.values()) {
    list.sort((a, b) => {
      const va = isVacantClubSelection(a);
      const vb = isVacantClubSelection(b);
      if (va !== vb) return va ? 1 : -1;
      if (va) return String(a.label || "").localeCompare(String(b.label || ""));
      const oa = Number(a.odds_decimal) || Infinity;
      const ob = Number(b.odds_decimal) || Infinity;
      if (oa !== ob) return oa - ob;
      return (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0);
    });
  }
}

async function loadMyBets() {
  myBets = [];
  if (!currentUserId) return;

  const { data, error } = await supabase
    .from("bookies_my_bets_public")
    .select("*")
    .eq("owner_id", currentUserId)
    .order("placed_at", { ascending: false })
    .limit(80);

  if (error) {
    console.warn("bookies_my_bets_public:", error.message);
    myBets = [];
  } else {
    // Own slips only — never include another owner's row
    myBets = (data || []).filter(
      (b) => String(b.owner_id) === String(currentUserId)
    );
  }
  const openN = myBets.filter((b) => b.status === "open").length;
  const el = document.getElementById("bkOpenCount");
  if (el) el.textContent = String(openN);
}

async function loadAllBetsAdmin() {
  allBetsAdmin = [];
  if (!isAdmin) return;
  const { data, error } = await supabase
    .from("bookies_admin_bets_public")
    .select("*")
    .order("placed_at", { ascending: false })
    .limit(500);
  if (error) {
    console.warn("bookies_admin_bets_public:", error.message);
    return;
  }
  allBetsAdmin = data || [];
}

function marketKindSectionLabel(kind) {
  const k = String(kind || "").toLowerCase();
  if (k === "club") return "Club markets";
  if (k === "player") return "Player markets";
  return kind ? String(kind) : "Other markets";
}

function setSlipsTab(tab) {
  slipsTab = tab === "all" && isAdmin ? "all" : "mine";
  const mineBtn = document.getElementById("bkTabMine");
  const allBtn = document.getElementById("bkTabAll");
  const minePanel = document.getElementById("bkMyBets");
  const allPanel = document.getElementById("bkAllBets");
  if (allBtn) allBtn.hidden = !isAdmin;
  mineBtn?.classList.toggle("is-active", slipsTab === "mine");
  allBtn?.classList.toggle("is-active", slipsTab === "all");
  if (mineBtn) mineBtn.setAttribute("aria-selected", slipsTab === "mine" ? "true" : "false");
  if (allBtn) allBtn.setAttribute("aria-selected", slipsTab === "all" ? "true" : "false");
  if (minePanel) minePanel.hidden = slipsTab !== "mine";
  // Non-admins never see the all-slips panel
  if (allPanel) allPanel.hidden = !isAdmin || slipsTab !== "all";
}

function alreadyBetOnMarket(marketId) {
  return myBets.some(
    (b) => Number(b.market_id) === Number(marketId) && b.status !== "void"
  );
}

function alreadyBetOn(selectionId) {
  return myBets.some(
    (b) => Number(b.selection_id) === Number(selectionId) && b.status !== "void"
  );
}

function renderMarkets() {
  const root = document.getElementById("bkMarkets");
  if (!root) return;

  if (!markets.length) {
    root.innerHTML =
      `<p class="bk-muted">No markets yet.` +
      (isAdmin
        ? ` Use <b>Open / create markets</b> above.`
        : ` Ask an admin to open the Bookies board.`) +
      `</p>`;
    return;
  }

  const shopClosed = markets.some((m) =>
    String(marketState(m.id).reason || "").startsWith("Betting opens")
  );
  const visible = markets.filter((m) => {
    if (shopClosed || marketState(m.id).running || m.status === "settled") return true;
    return myBets.some((b) => Number(b.market_id) === Number(m.id) && b.status !== "void");
  });
  const hiddenCount = markets.length - visible.length;

  const ordered = [...visible].sort(
    (a, b) => Number(!marketState(a.id).running) - Number(!marketState(b.id).running)
  );

  const hiddenNote = hiddenCount
    ? `<p class="bk-muted">${hiddenCount} market${hiddenCount === 1 ? "" : "s"} hidden until ${
        hiddenCount === 1 ? "its" : "their"
      } fixtures are drawn.</p>`
    : "";

  if (!ordered.length) {
    root.innerHTML =
      hiddenNote || `<p class="bk-muted">No competitions have fixtures yet.</p>`;
    return;
  }

  root.innerHTML = hiddenNote + ordered
    .map((m) => {
      const state = marketState(m.id);
      const sels = (selectionsByMarket.get(m.id) || []).filter(
        (s) =>
          !s.metadata?.withdrawn &&
          (!state.cupClubs || state.cupClubs.has(String(s.selection_key || "").toUpperCase()))
      );
      const myBet = myBets.find(
        (b) => Number(b.market_id) === Number(m.id) && b.status !== "void"
      );
      const marketTaken = Boolean(myBet);
      const pill =
        m.status === "open"
          ? "open"
          : m.status === "settled"
            ? "settled"
            : "closed";
      const rows = sels
        .map((s) => {
          const taken = alreadyBetOn(s.id);
          const own = isOwnSelection(s);
          const vacant = isVacantClubSelection(s);
          const canBet =
            m.status === "open" && state.running && currentClub && !marketTaken && !own && !vacant;
          return `<tr class="${taken ? "bk-sel--yours" : ""}${vacant ? " bk-sel--vacant" : ""}">
            <td>${escapeHtml(s.label)}${selectionOwnerTagHtml(s)}${taken ? ` <span class="bk-yours-mark">Your slip</span>` : ""}</td>
            <td class="bk-odds">${vacant ? "—" : escapeHtml(formatFractionalOdds(s.odds_decimal, s.odds_fractional))}</td>
            <td>
              ${
                vacant && !taken
                  ? `<span class="bk-muted" title="Clubs without an owner always finish at the bottom">No odds — vacant</span>`
                  : canBet
                  ? `<div class="bk-bet-row">
                      <input type="number" min="1" max="1000" step="1" value="100"
                        data-stake-for="${s.id}" aria-label="Stake" />
                      <button type="button" class="bk-btn bk-btn--gold" data-place="${s.id}">Bet</button>
                    </div>`
                  : !state.running && !taken
                    ? `<span class="bk-muted">Not running</span>`
                  : own && !taken
                    ? `<span class="bk-muted" title="Owners can't bet on their own club or players">Your club</span>`
                  : marketTaken
                    ? `<span class="bk-muted">${taken ? "Your bet" : "Already bet this market"}</span>`
                    : `<span class="bk-muted">${m.status !== "open" ? m.status : "—"}</span>`
              }
            </td>
          </tr>`;
        })
        .join("");

      return `<article class="bk-market${marketTaken ? " bk-market--yours" : ""}${state.running ? "" : " bk-market--inactive"}" data-market="${m.id}">
        <div class="bk-market-head" data-toggle="${m.id}">
          <span class="bk-market-title">${escapeHtml(m.title)}</span>
          ${
            state.running
              ? ""
              : `<span class="bk-pill bk-pill--inactive">${escapeHtml(state.reason || "Not running yet")}</span>`
          }
          ${
            marketTaken
              ? `<span class="bk-pill bk-pill--yours">Your bet · ${escapeHtml(myBet.status || "open")}</span>`
              : ""
          }
          <span class="bk-pill bk-pill--${pill}">${escapeHtml(m.status)}</span>
          <span class="bk-muted">${sels.length} options · ${escapeHtml(m.market_kind)}</span>
        </div>
        <div class="bk-market-body">
          ${
            m.market_kind === "player" && m.status === "open" && state.running
              ? `<div class="bk-player-search" data-player-search-market="${m.id}">
                  <label class="bk-muted">Find a player not on the board</label>
                  <div class="bk-player-search-row">
                    <input type="search" class="bk-player-search-input" data-search-input="${m.id}"
                      placeholder="Search name…" autocomplete="off" />
                    <button type="button" class="bk-btn" data-search-go="${m.id}">Search</button>
                  </div>
                  <div class="bk-player-search-results" data-search-results="${m.id}" hidden></div>
                </div>`
              : ""
          }
          <table class="bk-sel-table">
            <thead><tr><th>Selection</th><th>Odds</th><th>Bet (max ₿1,000)</th></tr></thead>
            <tbody>${rows || `<tr><td colspan="3" class="bk-muted">No selections</td></tr>`}</tbody>
          </table>
          ${
            isAdmin && m.status !== "settled"
              ? `<div style="padding:8px 10px;">
                  <label class="bk-muted">Settle result key (club ShortName or player id): </label>
                  <input type="text" id="settleKey-${m.id}" style="width:160px;margin:0 6px;padding:4px;background:#0c140e;border:1px solid #3a5a42;color:#ddd;border-radius:4px;" />
                  <button type="button" class="bk-btn" data-settle="${m.id}">Settle</button>
                  ${
                    m.status === "open"
                      ? `<button type="button" class="bk-btn" data-close="${m.id}" style="margin-left:6px;">Close betting</button>`
                      : ""
                  }
                </div>`
              : m.status === "settled" && m.result_selection_key
                ? `<p class="bk-muted" style="padding:8px 10px;">Result: <b>${escapeHtml(m.result_selection_key)}</b></p>`
                : ""
          }
        </div>
      </article>`;
    })
    .join("");

  root.querySelectorAll("[data-toggle]").forEach((el) => {
    el.addEventListener("click", () => {
      const art = el.closest(".bk-market");
      art?.classList.toggle("open");
    });
  });

  root.querySelectorAll("[data-place]").forEach((btn) => {
    btn.addEventListener("click", () => placeBet(Number(btn.dataset.place)));
  });

  root.querySelectorAll("[data-settle]").forEach((btn) => {
    btn.addEventListener("click", () => settleMarket(Number(btn.dataset.settle)));
  });

  root.querySelectorAll("[data-close]").forEach((btn) => {
    btn.addEventListener("click", () => closeMarket(Number(btn.dataset.close)));
  });

  wirePlayerSearch(root);
}

function wirePlayerSearch(root) {
  root.querySelectorAll("[data-search-go]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      void runPlayerSearch(Number(btn.dataset.searchGo));
    });
  });
  root.querySelectorAll("[data-search-input]").forEach((input) => {
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        void runPlayerSearch(Number(input.dataset.searchInput));
      }
    });
    input.addEventListener("click", (e) => e.stopPropagation());
  });
}

async function runPlayerSearch(marketId) {
  const input = document.querySelector(`[data-search-input="${marketId}"]`);
  const results = document.querySelector(`[data-search-results="${marketId}"]`);
  if (!input || !results) return;

  const q = String(input.value || "").trim();
  if (q.length < 2) {
    results.hidden = false;
    results.innerHTML = `<p class="bk-muted">Type at least 2 letters.</p>`;
    return;
  }

  results.hidden = false;
  results.innerHTML = `<p class="bk-muted">Searching…</p>`;

  const { data, error } = await supabase.rpc("bookies_search_players_for_market", {
    p_market_id: marketId,
    p_query: q,
    p_limit: 12,
  });

  if (error) {
    results.innerHTML = `<p class="bk-muted" style="color:#e07070;">${escapeHtml(error.message)}</p>`;
    return;
  }

  const list = Array.isArray(data) ? data : [];
  if (!list.length) {
    results.innerHTML = `<p class="bk-muted">No eligible players match. Position rules still apply (e.g. GKs only on clean sheets).</p>`;
    return;
  }

  const m = markets.find((x) => Number(x.id) === Number(marketId));
  const state = marketState(marketId);
  const myBet = myBets.find(
    (b) => Number(b.market_id) === Number(marketId) && b.status !== "void"
  );

  results.innerHTML = list
    .map((p) => {
      const club = String(p.club || "");
      const own =
        club && currentClub && club.toUpperCase() === String(currentClub).toUpperCase();
      const listed = p.already_listed === true;
      const canAdd =
        m?.status === "open" && state.running && currentClub && !myBet && !own;
      return `<div class="bk-player-search-hit">
        <div>
          <b>${escapeHtml(p.player_name)}</b>
          <span class="bk-muted"> · ${escapeHtml(p.position || "—")} · ${escapeHtml(fullClubName(club) || club)}</span>
          ${listed ? ` <span class="bk-yours-mark">On board</span>` : ""}
        </div>
        <div>
          ${
            own
              ? `<span class="bk-muted">Your club</span>`
              : myBet
                ? `<span class="bk-muted">Already bet this market</span>`
                : canAdd
                  ? `<button type="button" class="bk-btn bk-btn--gold" data-ensure-player="${escapeHtml(p.player_id)}" data-ensure-market="${marketId}">
                      ${listed ? "Show & bet" : "Add & bet"}
                    </button>`
                  : `<span class="bk-muted">—</span>`
          }
        </div>
      </div>`;
    })
    .join("");

  results.querySelectorAll("[data-ensure-player]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      void ensurePlayerAndBet(
        Number(btn.dataset.ensureMarket),
        String(btn.dataset.ensurePlayer)
      );
    });
  });
}

async function ensurePlayerAndBet(marketId, playerId) {
  setStatus("Adding player to market…");
  const { data, error } = await supabase.rpc("bookies_ensure_player_selection", {
    p_market_id: marketId,
    p_player_id: playerId,
  });

  if (error) {
    setStatus(error.message || "Could not add player.", false);
    return;
  }

  const selectionId = Number(data?.selection_id);
  if (!selectionId) {
    setStatus("Player added but selection id missing — refresh and try again.", false);
    await refreshAll();
    return;
  }

  await refreshAll();

  // Open the market accordion and focus stake for this selection
  const art = document.querySelector(`.bk-market[data-market="${marketId}"]`);
  art?.classList.add("open");
  const stakeInput = document.querySelector(`[data-stake-for="${selectionId}"]`);
  if (stakeInput) {
    stakeInput.focus();
    stakeInput.select?.();
    setStatus(
      data?.created
        ? "Player added to the board — enter stake and Bet."
        : "Player already on the board — enter stake and Bet.",
      true
    );
  } else {
    setStatus("Player is on the board. Open the market list to place your bet.", true);
  }
}

function betCardHtml(b, { showBettor = false } = {}) {
  const st = String(b.status || "open");
  const selById = betCardHtml._selById || new Map();
  const sel = selById.get(Number(b.selection_id));
  const bettor = showBettor
    ? `<div class="bk-bettor">Bettor: <b>${escapeHtml(b.bettor_tag || "—")}</b></div>`
    : "";
  return `<div class="bk-bet-card">
    <div>
      <div><b>${escapeHtml(b.market_title)}</b></div>
      <div class="bk-muted">${escapeHtml(b.selection_label)}${sel ? selectionOwnerTagHtml(sel) : ""} @ ${escapeHtml(formatFractionalOdds(b.odds_decimal, b.odds_fractional))}</div>
      ${bettor}
      <div>Stake ${formatMoney(b.stake)} · returns ${formatMoney(b.potential_return)}</div>
    </div>
    <div class="status-${st}">${escapeHtml(st)}</div>
  </div>`;
}

function renderMyBets() {
  const root = document.getElementById("bkMyBets");
  if (!root) return;
  const selById = new Map();
  for (const list of selectionsByMarket.values()) {
    for (const s of list) selById.set(Number(s.id), s);
  }
  betCardHtml._selById = selById;
  if (!myBets.length) {
    root.innerHTML = `<p class="bk-muted">No bets placed on your owner account yet.</p>`;
    return;
  }
  root.innerHTML = myBets.map((b) => betCardHtml(b, { showBettor: false })).join("");
}

function renderAllBetsAdmin() {
  const root = document.getElementById("bkAllBets");
  if (!root || !isAdmin) return;
  const selById = new Map();
  for (const list of selectionsByMarket.values()) {
    for (const s of list) selById.set(Number(s.id), s);
  }
  betCardHtml._selById = selById;

  if (!allBetsAdmin.length) {
    root.innerHTML = `<p class="bk-muted">No slips placed by any owner yet.</p>`;
    return;
  }

  const kindOrder = ["club", "player"];
  const byKind = new Map();
  for (const b of allBetsAdmin) {
    const kind = String(b.market_kind || "other").toLowerCase();
    if (!byKind.has(kind)) byKind.set(kind, []);
    byKind.get(kind).push(b);
  }

  const kinds = [
    ...kindOrder.filter((k) => byKind.has(k)),
    ...[...byKind.keys()].filter((k) => !kindOrder.includes(k)).sort(),
  ];

  root.innerHTML = kinds
    .map((kind) => {
      const bets = byKind.get(kind) || [];
      const byMarket = new Map();
      for (const b of bets) {
        const title = String(b.market_title || "Market");
        if (!byMarket.has(title)) byMarket.set(title, []);
        byMarket.get(title).push(b);
      }
      const marketsHtml = [...byMarket.entries()]
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([title, list]) => {
          const openN = list.filter((x) => x.status === "open").length;
          return `<div class="bk-admin-market">
            <h4>${escapeHtml(title)} <span class="bk-muted">(${list.length} slip${list.length === 1 ? "" : "s"}${openN ? ` · ${openN} open` : ""})</span></h4>
            ${list.map((b) => betCardHtml(b, { showBettor: true })).join("")}
          </div>`;
        })
        .join("");
      return `<div class="bk-admin-kind">
        <h3>${escapeHtml(marketKindSectionLabel(kind))}</h3>
        ${marketsHtml}
      </div>`;
    })
    .join("");
}

async function placeBet(selectionId) {
  const input = document.querySelector(`[data-stake-for="${selectionId}"]`);
  const stake = Number(input?.value);
  if (!Number.isFinite(stake) || stake <= 0) {
    setStatus("Enter a stake greater than zero.", false);
    return;
  }
  if (stake > 1000) {
    setStatus("Maximum stake is ₿1,000.", false);
    return;
  }
  if (
    !confirm(
      `Place stake ${formatMoney(stake)} on this selection?\n\nDebited from your owner balance (not club funds).`
    )
  ) {
    return;
  }

  setStatus("Placing bet…");
  const { data, error } = await supabase.rpc("bookies_place_bet", {
    p_selection_id: selectionId,
    p_stake: stake,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus(
    `Bet placed @ ${formatFractionalOdds(data?.odds, data?.odds_fractional)}` +
      ` — return ${formatMoney(data?.potential_return)}. Board odds updated.`,
    true
  );
  await refreshAll();
}

async function openMarkets(refresh) {
  if (refresh) {
    setStatus("Refreshing board odds from table / cup / stats…");
    const { data, error } = await supabase.rpc("admin_bookies_recompute_all_odds", {
      p_season_id: null,
    });
    if (error) {
      setStatus(error.message, false);
      return;
    }
    setStatus(
      `Board odds updated — ${data?.markets_repriced ?? 0} markets (placed bets keep their slip odds).`,
      true
    );
    await refreshAll();
    return;
  }

  setStatus("Opening markets…");
  const { data, error } = await supabase.rpc("admin_bookies_open_markets", {
    p_season_id: null,
    p_refresh: false,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus(
    `Markets ready — created ${data?.created_markets ?? 0}, refreshed ${data?.refreshed_markets ?? 0}.`,
    true
  );
  await refreshAll();
}

async function settleMarket(marketId) {
  const key = document.getElementById(`settleKey-${marketId}`)?.value?.trim();
  if (!key) {
    setStatus("Enter the winning selection key (club ShortName or player id).", false);
    return;
  }
  if (!confirm(`Settle this market with result "${key}"? Winners are paid as Bookies Income.`)) {
    return;
  }
  const { data, error } = await supabase.rpc("bookies_settle_market", {
    p_market_id: marketId,
    p_result_selection_key: key,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus(
    `Settled — ${data?.won ?? 0} won, ${data?.lost ?? 0} lost, paid ${formatMoney(data?.paid_out)}.`,
    true
  );
  await refreshAll();
}

async function closeMarket(marketId) {
  const { error } = await supabase.rpc("admin_bookies_close_market", {
    p_market_id: marketId,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus("Betting closed for that market.", true);
  await refreshAll();
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function refreshAll() {
  await Promise.all([
    loadMarkets(),
    loadMyBets(),
    loadAllBetsAdmin(),
    loadHeader(),
    loadMarketStates(),
  ]);
  renderMarkets();
  renderMyBets();
  renderAllBetsAdmin();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  currentUserId = user.id;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  currentClub = club?.ShortName || null;

  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");
    ownerTag = String(self?.owner_tag || "").trim() || null;
  } catch {
    ownerTag = null;
  }

  isAdmin = await resolveAdmin();
  const adminPanel = document.getElementById("bkAdminPanel");
  if (adminPanel) adminPanel.hidden = !isAdmin;
  const allTab = document.getElementById("bkTabAll");
  if (allTab) allTab.hidden = !isAdmin;

  document.getElementById("bkOpenMarketsBtn")?.addEventListener("click", () => openMarkets(false));
  document.getElementById("bkRefreshOddsBtn")?.addEventListener("click", () => openMarkets(true));
  document.getElementById("bkTabMine")?.addEventListener("click", () => setSlipsTab("mine"));
  document.getElementById("bkTabAll")?.addEventListener("click", () => {
    setSlipsTab("all");
    renderAllBetsAdmin();
  });

  setSlipsTab("mine");
  await refreshAll();
});
