import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import { formatWage } from "./wages.js";

let myClubShort = null;
let marketRows = [];
let bidTarget = null;

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

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  myClubShort = club?.ShortName ?? null;

  wireBidModal();
  await loadMarket();

  const params = new URLSearchParams(window.location.search);
  const pid = params.get("player");
  if (pid) {
    const row = marketRows.find((r) => String(r.player_id) === String(pid));
    if (row) openBidModal(row);
  }
});

async function loadMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");

  const { data, error } = await supabase.rpc("list_expiring_contract_market");

  if (error) {
    status.textContent = "Could not load market.";
    tbody.innerHTML = "";
    console.error(error);
    return;
  }

  marketRows = Array.isArray(data) ? data : [];

  if (!marketRows.length) {
    status.textContent =
      "No players on the expiring-contract market right now (final-year standard players only).";
    tbody.innerHTML =
      '<tr><td colspan="7">—</td></tr>';
    return;
  }

  status.textContent = `${marketRows.length} player(s) — hidden bids until season rollover.`;

  tbody.innerHTML = marketRows
    .map((row) => {
      const myBid =
        row.my_wage_bid != null
          ? `<span class="my-bid">${formatWage(row.my_wage_bid)}</span>`
          : "—";
      return `
        <tr data-player-id="${row.player_id}">
          <td>${row.player_name}</td>
          <td>${row.position || "—"}</td>
          <td>${row.rating ?? "—"}</td>
          <td>${displayClubName(row.holding_club)}</td>
          <td>${formatWage(row.current_wage)}</td>
          <td>${myBid}</td>
          <td>
            <button type="button" class="bid-btn" data-player-id="${row.player_id}">
              ${row.my_wage_bid != null ? "Update bid" : "Place bid"}
            </button>
          </td>
        </tr>
      `;
    })
    .join("");

  tbody.querySelectorAll(".bid-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.playerId;
      const row = marketRows.find((r) => String(r.player_id) === String(id));
      if (row) openBidModal(row);
    });
  });
}

function wireBidModal() {
  document.getElementById("bidCancelBtn").onclick = closeBidModal;
  document.getElementById("bidSubmitBtn").onclick = submitBid;
}

function openBidModal(row) {
  if (!myClubShort) {
    alert("Link a club to your account to place bids.");
    return;
  }

  bidTarget = row;
  const modal = document.getElementById("bidModal");
  const isHolder = row.holding_club === myClubShort;

  document.getElementById("bidModalTitle").textContent = `Bid — ${row.player_name}`;
  document.getElementById("bidModalHint").textContent = isHolder
    ? `You hold this player. Bid must be at least current wage (${formatWage(row.current_wage)}).`
    : "Highest wage wins at season rollover. Other clubs cannot see your amount.";
  document.getElementById("bidWageInput").value =
    row.my_wage_bid != null
      ? String(row.my_wage_bid)
      : row.current_wage != null
        ? String(row.current_wage)
        : "";
  document.getElementById("bidModalError").textContent = "";
  modal.style.display = "flex";
}

function closeBidModal() {
  document.getElementById("bidModal").style.display = "none";
  bidTarget = null;
}

async function submitBid() {
  const errEl = document.getElementById("bidModalError");
  errEl.textContent = "";
  if (!bidTarget) return;

  const raw = document.getElementById("bidWageInput").value;
  const wage = Number(String(raw).replace(/[^\d]/g, ""));
  if (!Number.isFinite(wage) || wage <= 0) {
    errEl.textContent = "Enter a valid wage amount.";
    return;
  }

  const { error } = await supabase.rpc("contract_submit_expiry_wage_bid", {
    p_player_id: String(bidTarget.player_id),
    p_wage_offer: wage,
  });

  if (error) {
    errEl.textContent = error.message || "Bid failed.";
    return;
  }

  closeBidModal();
  await loadMarket();
}
