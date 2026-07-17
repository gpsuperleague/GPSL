import { initGlobal, supabase, getAuthUserFast } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney, fetchPrizePlayerBrief, fetchPlayerCareerBundle, renderPrizeCareerStatsHtml } from "./special_auction.js";
import { playerNameLinkHtml, playerThumbLinkHtml } from "./player_links.js";
import { parseMoneyInput, wireMoneyBidInput } from "./money_input.js";
import { renderHonoursHtml } from "./player_career_medals.js";

let state = null;
let auctionId = null;
let timerHandle = null;
let prizeHtml = "";
let bidAmountControl = null;
function setBidStatus(msg, kind = "") {
  const el = document.getElementById("bidStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = "status" + (kind === "ok" ? " ok" : kind === "err" ? " err" : "");
}

function clubLabel(id) {
  return fullClubName(id) || id || "—";
}

function phaseTitle(phase, status) {
  if (status === "scheduled") return "Scheduled — waiting to start";
  if (phase === "phase1") return "Phase 1 — Blind qualification";
  if (phase === "reveal") return "Reveal break — tiers assigned";
  if (phase === "phase2") return "Phase 2 — Final showdown";
  if (phase === "complete") return "Complete — results revealed";
  if (phase === "failed") return "Failed — no valid bids";
  if (status === "settled") return "Settled";
  return phase || status || "—";
}

function deadlineFor(state) {
  const phase = state.gauntlet_phase;
  if (state.status === "scheduled") return state.start_time;
  if (phase === "phase1") return state.phase1_end_at;
  if (phase === "reveal") return state.reveal_end_at;
  if (phase === "phase2") return state.phase2_end_at;
  return null;
}

function updateTimer() {
  const el = document.getElementById("timer");
  if (!el || !state) return;
  const endIso = deadlineFor(state);
  if (!endIso || state.revealed) {
    el.textContent = state.revealed ? "Auction finished" : "—";
    return;
  }
  const ms = new Date(endIso).getTime() - Date.now();
  if (ms <= 0) {
    el.textContent = "Phase ending…";
    refreshState();
    return;
  }
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  const pad = (n) => String(n).padStart(2, "0");
  el.textContent = `${pad(h)}:${pad(m)}:${pad(s)} remaining`;
}

function renderBidsTable(rows, cols) {
  if (!rows?.length) return "<p class='meta'>None.</p>";
  return `<table>
    <thead><tr>${cols.map((c) => `<th>${c.label}</th>`).join("")}</tr></thead>
    <tbody>
      ${rows
        .map(
          (r) =>
            `<tr class="${r.is_winner ? "winner" : ""}">${cols
              .map((c) => `<td>${c.render(r)}</td>`)
              .join("")}</tr>`
        )
        .join("")}
    </tbody>
  </table>`;
}

function packExtrasLine(pack) {
  if (!pack || typeof pack !== "object") return "";
  const bits = [];
  const med = pack.medical_tokens || [];
  const disc = pack.fee_discounts || [];
  if (med.length) bits.push(`Medical: ${med.map((n) => `${n}-match`).join(", ")}`);
  if (disc.length) bits.push(`Fee discounts: ${disc.map((n) => `${n}%`).join(", ")}`);
  if (pack.appeal_cards > 0) bits.push(`Appeal cards: ${pack.appeal_cards}`);
  if (pack.draft_tokens > 0) bits.push(`Draft tokens: ${pack.draft_tokens}`);
  return bits.length ? `<div style="margin-top:6px;color:#aaa;">Extras: ${bits.join(" · ")}</div>` : "";
}

async function loadPrizeBlock() {
  const el = document.getElementById("prizeBlock");
  if (!el || !state) return;

  const packLine = packExtrasLine(state.gauntlet_prize_pack);
  const pid = state.prize_player_id || state.known_player_id;

  if (state.prize_type === "player" && pid) {
    const [p, career] = await Promise.all([
      fetchPrizePlayerBrief(supabase, pid),
      fetchPlayerCareerBundle(supabase, pid),
    ]);
    if (p) {
      const medalsHtml = career?.honours?.length
        ? renderHonoursHtml(career.honours, {
            emptyMessage: "No league/cup winner medals yet.",
          })
        : "";
      const careerHtml = renderPrizeCareerStatsHtml(career, {
        playerId: pid,
        medalsHtml,
      });
      prizeHtml = `
        <div class="sa-player-row">
          ${playerThumbLinkHtml(p.Konami_ID, {
            alt: p.Name || pid,
            className: "sa-player-card",
            linkClass: "sa-player-card-link",
          })}
          <div class="sa-player-meta">
            <div>${playerNameLinkHtml(p.Konami_ID, p.Name || pid)}</div>
            <div class="sa-player-sub">
              ${p.Position || "?"} · Rating ${p.Rating || "?"}
              · MV ${formatMoney(p.market_value)}
            </div>
            <div class="sa-player-sub">Player prize · ID ${pid}</div>
          </div>
        </div>
        ${careerHtml}
        ${packLine}`;
    } else {
      prizeHtml = `<div><b>Player prize</b> · ID ${pid}</div>${packLine}`;
    }
  } else if (state.prize_type === "cash") {
    prizeHtml = `<div><b>Cash prize</b> · ${formatMoney(state.prize_cash_amount)}</div>${packLine}`;
  } else if (state.prize_type === "discount") {
    prizeHtml = `<div><b>Discount</b> · ${state.prize_discount_label || "—"}</div>${packLine}`;
  } else {
    prizeHtml = `<div>Prize not set on this auction.</div>${packLine}`;
  }
  el.innerHTML = prizeHtml;
}

function render() {
  if (!state) return;
  document.getElementById("pageTitle").textContent = state.title || "Blind Gauntlet";
  document.getElementById("phaseLabel").textContent = phaseTitle(
    state.gauntlet_phase,
    state.status
  );
  const prizeEl = document.getElementById("prizeBlock");
  if (prizeEl && prizeHtml) prizeEl.innerHTML = prizeHtml;

  const tierEl = document.getElementById("myTier");
  const tier = state.my_phase1?.tier;
  if (tier && ["reveal", "phase2", "complete", "failed"].includes(state.gauntlet_phase)) {
    if (tier === "top") {
      tierEl.innerHTML = `
        <span class="tier top">Your tier: TOP</span>
        <p class="tier-note advance">You advanced to Phase 2 (Round 2).</p>`;
    } else if (tier === "middle" || tier === "bottom") {
      const fee =
        Number(state.my_phase1?.phase1_fee) ||
        (tier === "middle" ? 500000 : 1000000);
      tierEl.innerHTML = `
        <span class="tier ${tier}">Your tier: ${tier.toUpperCase()}</span>
        <p class="tier-note eliminated">You have been eliminated from Round 2.</p>
        <p class="tier-note fee">Phase 1 fee charged: ${formatMoney(fee)} (non-refundable).</p>`;
    } else {
      tierEl.innerHTML = `<span class="tier ${tier}">Your tier: ${String(tier).toUpperCase()}</span>`;
    }
  } else {
    tierEl.innerHTML = "";
  }

  const my = [];
  if (state.my_phase1) {
    my.push(
      `Phase 1 bid: ${formatMoney(state.my_phase1.bid_amount)}` +
        (state.my_phase1.phase1_fee
          ? ` · fee ${formatMoney(state.my_phase1.phase1_fee)}`
          : "")
    );
  }
  if (state.my_phase2) {
    my.push(
      `Phase 2 bid: ${formatMoney(state.my_phase2.bid_amount)} · entry fee ${formatMoney(
        state.my_phase2.phase2_fee || 3000000
      )}`
    );
  }
  const waitingToOpen =
    state.status === "scheduled" ||
    (state.start_time && Date.now() < new Date(state.start_time).getTime());
  document.getElementById("myBids").innerHTML =
    my.join("<br>") ||
    (waitingToOpen
      ? "Waiting for Auction to open before bidding is allowed"
      : "No bids from you yet.");

  const bidPanel = document.getElementById("bidPanel");
  const help = document.getElementById("bidHelp");
  const can1 = state.can_bid_phase1;
  const can2 = state.can_bid_phase2;
  bidPanel.hidden = !(can1 || can2);
  if (can1) {
    help.textContent =
      "Phase 1: one blind bid. Not charged. Locks your Phase 2 minimum.";
  } else if (can2) {
    help.textContent = `Phase 2: one blind bid ≥ ${formatMoney(
      state.phase2_min || 0
    )}. Submitting charges ₿3,000,000 entry fee immediately.`;
    const input = document.getElementById("bidAmount");
    if (input && state.phase2_min) {
      bidAmountControl?.set(Math.max(Number(state.phase2_min) || 0, 1000000));
    }
  }

  const reveal = document.getElementById("revealPanel");
  reveal.hidden = !state.revealed;
  if (state.revealed) {
    const win = state.winning_club_id
      ? `<div class="winner">${clubLabel(state.winning_club_id)} won with ${formatMoney(
          state.winning_amount
        )}</div>`
      : "<div class='meta'>No winner.</div>";
    document.getElementById("winnerBanner").innerHTML = win;
    document.getElementById("phase2Table").innerHTML = renderBidsTable(state.phase2_bids, [
      { label: "Club", render: (r) => clubLabel(r.club_id) },
      { label: "Bid", render: (r) => formatMoney(r.bid_amount) },
      { label: "", render: (r) => (r.is_winner ? "★ Winner" : "") },
    ]);
    document.getElementById("phase1Table").innerHTML = renderBidsTable(state.phase1_bids, [
      { label: "Club", render: (r) => clubLabel(r.club_id) },
      { label: "Bid", render: (r) => formatMoney(r.bid_amount) },
      { label: "Tier", render: (r) => r.tier || "—" },
      { label: "P1 fee", render: (r) => formatMoney(r.phase1_fee || 0) },
    ]);
  }

  updateTimer();
}

async function refreshState() {
  if (!auctionId) return;
  const { data, error } = await supabase.rpc("special_auction_gauntlet_owner_state", {
    p_auction_id: auctionId,
  });
  if (error) {
    document.getElementById("phaseLabel").textContent = "❌ " + error.message;
    return;
  }
  state = data;
  await loadPrizeBlock();
  render();
}

async function submitBid() {
  const raw = bidAmountControl?.parse() ?? parseMoneyInput(
    document.getElementById("bidAmount")?.value
  );
  if (!raw || raw <= 0) {
    setBidStatus("Enter a bid amount.", "err");
    return;
  }
  const phaseNote = state?.can_bid_phase2
    ? "This will charge ₿3,000,000 entry fee now."
    : "Phase 1 amount is not charged.";
  if (!confirm(`Submit blind bid ${formatMoney(raw)}?\n\n${phaseNote}`)) return;

  setBidStatus("Submitting…");
  const { data, error } = await supabase.rpc("special_auction_submit_gauntlet_bid", {
    p_auction_id: auctionId,
    p_amount: raw,
  });
  if (error) {
    setBidStatus("❌ " + error.message, "err");
    return;
  }
  setBidStatus(`✅ Bid locked at ${formatMoney(data?.bid_amount)}. ${data?.note || ""}`, "ok");
  bidAmountControl?.set(0);
  document.getElementById("bidAmount").value = "";
  await refreshState();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();
  const user = await getAuthUserFast();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const params = new URLSearchParams(location.search);
  auctionId = Number(params.get("id"));

  if (!auctionId) {
    const { data } = await supabase.rpc("special_auction_fetch_owner_active");
    if (data?.auction_type === "blind_gauntlet" && data?.id) {
      auctionId = data.id;
    } else if (data?.id) {
      window.location = `special_auction.html?id=${data.id}`;
      return;
    }
  }

  if (!auctionId) {
    document.getElementById("phaseLabel").textContent = "No Blind Gauntlet auction is live.";
    return;
  }

  document.getElementById("bidBtn").onclick = submitBid;

  const bidInput = document.getElementById("bidAmount");
  bidAmountControl = wireMoneyBidInput(bidInput, {
    min: () =>
      state?.can_bid_phase2
        ? Math.max(Number(state.phase2_min) || 0, 1000000)
        : 1000000,
  });
  if (bidInput && !bidInput.value) {
    bidAmountControl?.set(1000000);
  }

  await refreshState();
  timerHandle = setInterval(updateTimer, 1000);
  setInterval(refreshState, 15000);
});
