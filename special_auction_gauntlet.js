import { initGlobal, supabase, getAuthUserFast } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./special_auction.js";

let state = null;
let auctionId = null;
let timerHandle = null;

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

function render() {
  if (!state) return;
  document.getElementById("pageTitle").textContent = state.title || "Blind Gauntlet";
  document.getElementById("phaseLabel").textContent = phaseTitle(
    state.gauntlet_phase,
    state.status
  );

  const tierEl = document.getElementById("myTier");
  const tier = state.my_phase1?.tier;
  if (tier && ["reveal", "phase2", "complete", "failed"].includes(state.gauntlet_phase)) {
    tierEl.innerHTML = `<span class="tier ${tier}">Your tier: ${tier.toUpperCase()}</span>`;
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
  document.getElementById("myBids").innerHTML = my.join("<br>") || "No bids from you yet.";

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
    if (input && state.phase2_min) input.min = String(state.phase2_min);
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
  render();
}

async function submitBid() {
  const raw = Number(document.getElementById("bidAmount").value);
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
  await refreshState();
  timerHandle = setInterval(updateTimer, 1000);
  setInterval(refreshState, 15000);
});
