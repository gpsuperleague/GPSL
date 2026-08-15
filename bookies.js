import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";

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
let isAdmin = false;
let markets = [];
let selectionsByMarket = new Map();
let myBets = [];

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
  const clubEl = document.getElementById("bkClub");
  const balEl = document.getElementById("bkBalance");
  if (clubEl) clubEl.textContent = currentClub || "—";

  if (!currentClub) {
    if (balEl) balEl.textContent = "—";
    return;
  }

  const { data } = await supabase
    .from("Club_Finances")
    .select("balance")
    .eq("club_name", currentClub)
    .maybeSingle();
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
}

async function loadMyBets() {
  const { data, error } = await supabase
    .from("bookies_my_bets_public")
    .select("*")
    .order("placed_at", { ascending: false })
    .limit(80);

  if (error) {
    myBets = [];
    return;
  }
  myBets = data || [];
  const openN = myBets.filter((b) => b.status === "open").length;
  const el = document.getElementById("bkOpenCount");
  if (el) el.textContent = String(openN);
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

  root.innerHTML = markets
    .map((m) => {
      const sels = selectionsByMarket.get(m.id) || [];
      const pill =
        m.status === "open"
          ? "open"
          : m.status === "settled"
            ? "settled"
            : "closed";
      const rows = sels
        .map((s) => {
          const taken = alreadyBetOn(s.id);
          const canBet = m.status === "open" && currentClub && !taken;
          return `<tr>
            <td>${escapeHtml(s.label)}</td>
            <td class="bk-odds">${escapeHtml(formatFractionalOdds(s.odds_decimal, s.odds_fractional))}</td>
            <td>
              ${
                canBet
                  ? `<div class="bk-bet-row">
                      <input type="number" min="1" max="1000" step="1" value="100"
                        data-stake-for="${s.id}" aria-label="Stake" />
                      <button type="button" class="bk-btn bk-btn--gold" data-place="${s.id}">Bet</button>
                    </div>`
                  : taken
                    ? `<span class="bk-muted">Already bet</span>`
                    : `<span class="bk-muted">${m.status !== "open" ? m.status : "—"}</span>`
              }
            </td>
          </tr>`;
        })
        .join("");

      return `<article class="bk-market" data-market="${m.id}">
        <div class="bk-market-head" data-toggle="${m.id}">
          <span class="bk-market-title">${escapeHtml(m.title)}</span>
          <span class="bk-pill bk-pill--${pill}">${escapeHtml(m.status)}</span>
          <span class="bk-muted">${sels.length} options · ${escapeHtml(m.market_kind)}</span>
        </div>
        <div class="bk-market-body">
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
}

function renderMyBets() {
  const root = document.getElementById("bkMyBets");
  if (!root) return;
  if (!myBets.length) {
    root.innerHTML = `<p class="bk-muted">No bets yet this season.</p>`;
    return;
  }
  root.innerHTML = myBets
    .map((b) => {
      const st = String(b.status || "open");
      return `<div class="bk-bet-card">
        <div>
          <div><b>${escapeHtml(b.market_title)}</b></div>
          <div class="bk-muted">${escapeHtml(b.selection_label)} @ ${escapeHtml(formatFractionalOdds(b.odds_decimal, b.odds_fractional))}</div>
          <div>Stake ${formatMoney(b.stake)} · returns ${formatMoney(b.potential_return)}</div>
        </div>
        <div class="status-${st}">${escapeHtml(st)}</div>
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
      `Place stake ${formatMoney(stake)} on this selection?\n\nPosted to finances as Bookies Expenditure.`
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
    `Bet placed — potential return ${formatMoney(data?.potential_return)}.`,
    true
  );
  await refreshAll();
}

async function openMarkets(refresh) {
  setStatus(refresh ? "Refreshing odds…" : "Opening markets…");
  const { data, error } = await supabase.rpc("admin_bookies_open_markets", {
    p_season_id: null,
    p_refresh: Boolean(refresh),
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
  await Promise.all([loadMarkets(), loadMyBets(), loadHeader()]);
  renderMarkets();
  renderMyBets();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  currentClub = club?.ShortName || null;

  isAdmin = await resolveAdmin();
  const adminPanel = document.getElementById("bkAdminPanel");
  if (adminPanel) adminPanel.hidden = !isAdmin;

  document.getElementById("bkOpenMarketsBtn")?.addEventListener("click", () => openMarkets(false));
  document.getElementById("bkRefreshOddsBtn")?.addEventListener("click", () => openMarkets(true));

  await refreshAll();
});
