import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";

let currentClub = null;
let ownerBalance = 0;
let catalogue = [];
let stock = [];
let medalShop = null;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function setStatus(msg, ok = true) {
  const el = document.getElementById("shopStatus");
  if (!el) return;
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  el.hidden = false;
  el.textContent = msg;
  el.style.color = ok ? "#e8c060" : "#e07070";
  el.style.borderColor = ok ? "#8a6a28" : "#8a3038";
}

function stockLabel(row) {
  if (row.prize_type === "medical_token") return `Consult −${row.param_int}`;
  if (row.prize_type === "appeal_card") return "Appeal card";
  if (row.prize_type === "fee_discount") return `Fee discount ${row.param_int}%`;
  if (row.prize_type === "draft_token") return "Draft token";
  if (row.prize_type === "agent_bribe") return "Brown envelope";
  return row.prize_type;
}

function stockTypeClass(prizeType) {
  if (prizeType === "medical_token") return "shop-stock-type--med";
  if (prizeType === "appeal_card") return "shop-stock-type--disc";
  if (prizeType === "agent_bribe") return "shop-stock-type--shady";
  return "";
}

function stockTypeLabel(prizeType) {
  if (prizeType === "medical_token") return "Medical";
  if (prizeType === "appeal_card") return "Discipline";
  if (prizeType === "fee_discount") return "Fees";
  if (prizeType === "draft_token") return "Draft";
  if (prizeType === "agent_bribe") return "Side door";
  return prizeType;
}

async function loadHeader() {
  const clubEl = document.getElementById("shopClub");
  const balEl = document.getElementById("shopOwnerBal");
  const stockClub = document.getElementById("shopStockClub");
  if (clubEl) clubEl.textContent = currentClub || "—";
  if (stockClub) stockClub.textContent = currentClub || "club";

  const { data: wallet, error: wErr } = await supabase.rpc("owner_wallet_get_self");
  if (wErr) {
    ownerBalance = 0;
    if (balEl) balEl.textContent = "—";
    setStatus(
      "Owner wallet not ready — run owners_shop_wallet_catalogue_20260822.sql in Supabase.",
      false
    );
  } else {
    ownerBalance = Number(wallet?.balance ?? 0);
    if (balEl) balEl.textContent = formatMoney(ownerBalance);
  }
}

async function loadCatalogue() {
  const { data, error } = await supabase.rpc("owners_shop_catalogue", {
    p_include_inactive: false,
  });
  if (error) {
    catalogue = [];
    setStatus(error.message || "Could not load shop catalogue", false);
    return;
  }
  catalogue = Array.isArray(data) ? data : [];
}

async function loadStock() {
  const { data, error } = await supabase.rpc("owners_shop_club_stock", {
    p_club: currentClub || null,
  });
  if (error) {
    stock = [];
    document.getElementById("shopStockCount").textContent = "—";
    return;
  }
  stock = Array.isArray(data) ? data : [];
  const total = stock.reduce((n, r) => n + (Number(r.qty) || 0), 0);
  document.getElementById("shopStockCount").textContent =
    total === 1 ? "1 item" : `${total} items`;
}

function shelves() {
  return catalogue.filter((s) => {
    if (s.code !== "trophy_room") return true;
    return Array.isArray(medalShop?.honours) && medalShop.honours.length > 0;
  });
}

function renderAisles() {
  const nav = document.getElementById("shopAisles");
  if (!nav) return;
  nav.innerHTML = shelves()
    .map((s, idx) => {
      const theme = s.theme_key || "default";
      const mark =
        theme === "medical"
          ? "+"
          : theme === "discipline"
            ? "■"
            : theme === "shady"
              ? "‽"
              : theme === "coming"
                ? "…"
                : "•";
      const soon = theme === "coming" ? " shop-aisle--soon" : "";
      const active = idx === 0 ? " is-active" : "";
      return `<a class="shop-aisle shop-aisle--${escapeHtml(theme)}${soon}${active}" href="#aisle-${escapeHtml(s.code)}">
        <span class="shop-aisle-mark" aria-hidden="true">${mark}</span>
        <span class="shop-aisle-label">${escapeHtml(s.label)}</span>
      </a>`;
    })
    .join("");
}

function renderSections() {
  const root = document.getElementById("shopSections");
  if (!root) return;

  root.innerHTML = shelves()
    .map((s) => {
      const theme = s.theme_key || "default";
      const panelMod =
        theme === "medical"
          ? "shop-panel--med"
          : theme === "discipline"
            ? "shop-panel--disc"
            : theme === "shady"
              ? "shop-panel--shady"
              : theme === "coming"
                ? "shop-panel--soon"
                : "";

      if (theme === "coming") {
        return `<section class="shop-panel ${panelMod}" id="aisle-${escapeHtml(s.code)}">
          <div class="shop-panel-head"><div>
            <p class="shop-panel-kicker">${escapeHtml(s.kicker || "")}</p>
            <h2>${escapeHtml(s.label)}</h2>
            <p class="shop-panel-intro">${escapeHtml(s.intro || "")}</p>
          </div></div>
          <div class="shop-coming">${(s.items || [])
            .map((i) => `<span>${escapeHtml(i.title)}</span>`)
            .join("") || "<span>Coming soon</span>"}</div>
        </section>`;
      }

      const items = (s.items || [])
        .map((i) => {
          const feat = i.is_featured ? " shop-item--featured" : "";
          const visualMod =
            theme === "discipline"
              ? "shop-item-visual--disc"
              : theme === "shady"
                ? "shop-item-visual--shady"
                : "shop-item-visual--med";
          const buyMod =
            theme === "discipline"
              ? " shop-buy--disc"
              : theme === "shady"
                ? " shop-buy--shady"
                : "";
          const badge = i.badge_label || "•";
          const medal = i.prize_type === "winner_medal" || i.sku_code === "winner_medal";
          const canBuy = currentClub && ownerBalance >= Number(i.price);
          const buyLabel = medal
            ? "Nominate a player"
            : theme === "shady"
              ? "Slip cash under the door"
              : `Buy for ${currentClub || "club"}`;
          return `<article class="shop-item${feat}${theme === "shady" ? " shop-item--shady" : ""}">
            <div class="shop-item-visual ${visualMod}">${escapeHtml(badge)}</div>
            <h3>${escapeHtml(i.title)}</h3>
            <p>${escapeHtml(i.description || "")}</p>
            <div class="shop-item-meta">
              <span class="shop-price">${formatMoney(i.price)}</span>
              <button type="button" class="shop-buy${buyMod}" data-buy="${i.id}"
                ${canBuy ? "" : "disabled"}>
                ${escapeHtml(buyLabel)}
              </button>
            </div>
          </article>`;
        })
        .join("");

      return `<section class="shop-panel ${panelMod}" id="aisle-${escapeHtml(s.code)}">
        <div class="shop-panel-head"><div>
          <p class="shop-panel-kicker">${escapeHtml(s.kicker || "")}</p>
          <h2>${escapeHtml(s.label)}</h2>
          <p class="shop-panel-intro">${escapeHtml(s.intro || "")}</p>
        </div></div>
        <div class="shop-shelf${theme === "discipline" ? " shop-shelf--narrow" : ""}">${items || '<p class="shop-panel-intro">No items in this aisle.</p>'}</div>
      </section>`;
    })
    .join("");

  root.querySelectorAll("[data-buy]").forEach((btn) => {
    btn.onclick = () => buyItem(Number(btn.getAttribute("data-buy")));
  });
}

function renderStock() {
  const list = document.getElementById("shopStockList");
  if (!list) return;
  if (!stock.length) {
    list.innerHTML = `<li>No available prize stock on this club.</li>`;
    return;
  }
  list.innerHTML = stock
    .map((r) => {
      const tc = stockTypeClass(r.prize_type);
      return `<li>
        <span class="shop-stock-type ${tc}">${escapeHtml(stockTypeLabel(r.prize_type))}</span>
        ${escapeHtml(stockLabel(r))} <b>×${r.qty}</b>
      </li>`;
    })
    .join("");
}

function medalHonours() {
  return Array.isArray(medalShop?.honours) ? medalShop.honours : [];
}

function fillMedalPlayers() {
  const titleSel = document.getElementById("medalTitle");
  const playerSel = document.getElementById("medalPlayer");
  const empty = document.getElementById("medalModalEmpty");
  const confirm = document.getElementById("medalConfirm");
  if (!titleSel || !playerSel) return;
  const honour = medalHonours().find(
    (h) =>
      String(h.season_id) === titleSel.value.split("|")[0] &&
      String(h.honour_type) === titleSel.value.split("|")[1] &&
      String(h.cup_code || "") === (titleSel.value.split("|")[2] || "")
  );
  const players = Array.isArray(honour?.players) ? honour.players : [];
  playerSel.innerHTML = players
    .map(
      (p) =>
        `<option value="${escapeHtml(p.player_id)}">${escapeHtml(p.name || p.player_id)}</option>`
    )
    .join("");
  const none = players.length === 0;
  if (empty) {
    empty.hidden = !none;
    empty.textContent = none
      ? "Everyone in that season’s squad who can have this medal already has one."
      : "";
  }
  if (confirm) confirm.disabled = none || ownerBalance < Number(medalShop?.price || 0);
}

function openMedalModal() {
  const modal = document.getElementById("medalModal");
  const titleSel = document.getElementById("medalTitle");
  const note = document.getElementById("medalModalNote");
  if (!modal || !titleSel) return;
  const honours = medalHonours();
  if (!honours.length) {
    setStatus("Winner medals open once a league or cup win is archived.", false);
    return;
  }
  titleSel.innerHTML = honours
    .map((h) => {
      const key = `${h.season_id}|${h.honour_type}|${h.cup_code || ""}`;
      const label = `${h.honour_label || "Title"} · ${h.season_label || ""}`;
      return `<option value="${escapeHtml(key)}">${escapeHtml(label)}</option>`;
    })
    .join("");
  if (note) {
    note.textContent =
      `${formatMoney(medalShop?.price)} from your personal balance. ` +
      `Only players who were in the squad that season, and who did not already earn the medal.`;
  }
  fillMedalPlayers();
  modal.hidden = false;
}

function closeMedalModal() {
  const modal = document.getElementById("medalModal");
  if (modal) modal.hidden = true;
}

async function confirmMedal() {
  const titleSel = document.getElementById("medalTitle");
  const playerSel = document.getElementById("medalPlayer");
  const confirm = document.getElementById("medalConfirm");
  if (!titleSel || !playerSel?.value) return;
  const [seasonId, honourType, cupCode] = titleSel.value.split("|");
  const name = playerSel.selectedOptions[0]?.textContent || "this player";
  const title = titleSel.selectedOptions[0]?.textContent || "this title";
  if (
    !window.confirm(
      `Buy a winner medal for ${name}?\n\n${title}\n${formatMoney(medalShop?.price)} comes off your personal wealth.`
    )
  ) {
    return;
  }
  if (confirm) confirm.disabled = true;
  const { data, error } = await supabase.rpc("owner_buy_winner_medal", {
    p_player_id: playerSel.value,
    p_season_id: Number(seasonId),
    p_honour_type: honourType,
    p_cup_code: cupCode || null,
  });
  if (error || data?.ok === false) {
    setStatus(error?.message || data?.reason || "Could not buy the medal.", false);
    if (confirm) confirm.disabled = false;
    return;
  }
  closeMedalModal();
  setStatus(
    `Winner medal for ${data?.player_name || name} — ${data?.honour_label || title}.`
  );
  await refreshAll();
}

function wireMedalModal() {
  document.getElementById("medalTitle")?.addEventListener("change", fillMedalPlayers);
  document.getElementById("medalCancel")?.addEventListener("click", closeMedalModal);
  document.getElementById("medalConfirm")?.addEventListener("click", () => {
    void confirmMedal();
  });
  document.getElementById("medalModal")?.addEventListener("click", (e) => {
    if (e.target?.id === "medalModal") closeMedalModal();
  });
}

async function buyItem(itemId) {
  if (!currentClub) {
    setStatus("Link a club before buying — stock delivers to your club.", false);
    return;
  }
  const item = catalogue.flatMap((s) => s.items || []).find((i) => i.id === itemId);
  if (item?.prize_type === "winner_medal" || item?.sku_code === "winner_medal") {
    openMedalModal();
    return;
  }
  const label = item?.title || "item";
  const shady = item?.prize_type === "agent_bribe";
  if (
    !window.confirm(
      shady
        ? `${label} for ${formatMoney(item?.price)}?\n\nNo shop receipt. Building Society will show a personal cheque to someone who does not exist. Envelope stocks on ${currentClub}.`
        : `Buy ${label} for ${formatMoney(item?.price)}?\n\nDebits your owner balance and stocks ${currentClub}.`
    )
  ) {
    return;
  }

  const { data, error } = await supabase.rpc("owners_shop_buy", { p_item_id: itemId });
  if (error) {
    setStatus(error.message || "Purchase failed", false);
    return;
  }
  if (shady && data?.disguised_payee) {
    setStatus(
      `Envelope slipped under the door for ${data?.club_short_name || currentClub}. Statement: Cheque to ${data.disguised_payee}.`
    );
  } else {
    setStatus(
      `Bought ${data?.item_title || label} ×${data?.quantity || 1} for ${data?.club_short_name || currentClub}.`
    );
  }
  await refreshAll();
}

async function loadMedalShop() {
  const { data, error } = await supabase.rpc("owner_winner_medal_shop");
  medalShop = error ? null : data;
}

async function refreshAll() {
  await loadHeader();
  await Promise.all([loadCatalogue(), loadStock(), loadMedalShop()]);
  renderAisles();
  renderSections();
  renderStock();
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

  wireMedalModal();
  await Promise.all([refreshAll(), renderBookiesReminder()]);
});

async function renderBookiesReminder() {
  const el = document.getElementById("shopBookiesReminder");
  if (!el) return;
  const { data, error } = await supabase.rpc("bookies_shop_status");
  if (error || !data) return;

  const opensAt = data.opens_at ? new Date(data.opens_at) : null;
  const when = opensAt
    ? opensAt.toLocaleString("en-GB", {
        weekday: "short",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
        timeZone: "Europe/London",
      })
    : null;

  if (data.open && Number(data.open_markets) > 0) {
    el.innerHTML =
      `🎰 <b>The GPSL Bookies is open</b> — bet on league champions, cup winners and top scorers from your owner balance. ` +
      `<a href="bookies.html" style="color:#9fdf9f;">Place a bet →</a>`;
  } else if (!data.open) {
    el.innerHTML =
      `🎰 <b>The GPSL Bookies opens in GPSL August</b>${when ? ` (${escapeHtml(when)} UK)` : ""}. ` +
      `Opening prices use June/July friendlies; once league and cups are underway the board tracks the table, cup progress and scoring charts. Early bets keep the odds you took.`;
  } else {
    el.innerHTML = `🎰 <b>The GPSL Bookies opens shortly</b> — markets are being set up for GPSL August.`;
  }
  el.hidden = false;
}
