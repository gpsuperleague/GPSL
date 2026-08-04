import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import { formatWage, expiryWageBidStep, minExpiryWageOffer } from "./wages.js";

const POSITION_ORDER = [
  "GK", "LB", "CB", "RB",
  "DMF", "LMF", "CMF", "RMF",
  "AMF", "LWF", "SS", "RWF", "CF",
];

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
  wireFilters();
  await loadMarket();

  const params = new URLSearchParams(window.location.search);
  const pid = params.get("player");
  if (pid) {
    const row = marketRows.find((r) => String(r.player_id) === String(pid));
    if (row) openBidModal(row);
  }
});

function wireFilters() {
  const ids = [
    "fName",
    "fPosition",
    "fNation",
    "fPlaystyle",
    "fClub",
    "fRatingMin",
    "fRatingMax",
    "fAgeMin",
    "fAgeMax",
    "fMyBid",
  ];
  for (const id of ids) {
    const el = document.getElementById(id);
    if (!el) continue;
    el.addEventListener(el.tagName === "SELECT" ? "change" : "input", () => {
      if (id === "fClub") syncMyClubFilterBtn();
      renderMarket();
    });
  }
  document.getElementById("fClearBtn")?.addEventListener("click", () => {
    for (const id of ids) {
      const el = document.getElementById(id);
      if (el) el.value = "";
    }
    syncMyClubFilterBtn();
    renderMarket();
  });

  const myClubBtn = document.getElementById("fMyClubBtn");
  if (myClubBtn) {
    myClubBtn.hidden = !myClubShort;
    myClubBtn.addEventListener("click", () => {
      if (!myClubShort) return;
      const clubSel = document.getElementById("fClub");
      if (!clubSel) return;
      const already = clubSel.value === myClubShort;
      clubSel.value = already ? "" : myClubShort;
      syncMyClubFilterBtn();
      renderMarket();
    });
  }
}

function syncMyClubFilterBtn() {
  const btn = document.getElementById("fMyClubBtn");
  const clubSel = document.getElementById("fClub");
  if (!btn) return;
  const active = Boolean(myClubShort && clubSel?.value === myClubShort);
  btn.classList.toggle("is-active", active);
  btn.style.background = active ? "#3d3200" : "";
  btn.style.borderColor = active ? "#ff9900" : "";
  btn.style.color = active ? "#ffcc66" : "";
}

function fillSelect(id, values, labelFn = (v) => v) {
  const sel = document.getElementById(id);
  if (!sel) return;
  const current = sel.value;
  const opts = ['<option value="">All</option>'].concat(
    values.map((v) => `<option value="${escapeAttr(v)}">${escapeHtml(labelFn(v))}</option>`)
  );
  sel.innerHTML = opts.join("");
  if (current && values.includes(current)) sel.value = current;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(text) {
  return escapeHtml(text).replace(/'/g, "&#39;");
}

function rebuildFilterOptions() {
  const positions = [
    ...new Set(marketRows.map((r) => r.position).filter(Boolean)),
  ].sort((a, b) => {
    const ai = POSITION_ORDER.indexOf(a);
    const bi = POSITION_ORDER.indexOf(b);
    return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
  });
  const nations = [...new Set(marketRows.map((r) => r.nation).filter(Boolean))].sort(
    (a, b) => a.localeCompare(b)
  );
  const playstyles = [
    ...new Set(marketRows.map((r) => r.playstyle).filter(Boolean)),
  ].sort((a, b) => a.localeCompare(b));
  const clubs = [
    ...new Set(marketRows.map((r) => r.holding_club).filter(Boolean)),
  ].sort((a, b) =>
    displayClubName(a).localeCompare(displayClubName(b), undefined, {
      sensitivity: "base",
    })
  );

  fillSelect("fPosition", positions);
  fillSelect("fNation", nations);
  fillSelect("fPlaystyle", playstyles);
  fillSelect("fClub", clubs, (v) => displayClubName(v));
  syncMyClubFilterBtn();
}

function filteredRows() {
  const name = (document.getElementById("fName")?.value || "").trim().toLowerCase();
  const position = document.getElementById("fPosition")?.value || "";
  const nation = document.getElementById("fNation")?.value || "";
  const playstyle = document.getElementById("fPlaystyle")?.value || "";
  const club = document.getElementById("fClub")?.value || "";
  const ratingMin = Number(document.getElementById("fRatingMin")?.value);
  const ratingMax = Number(document.getElementById("fRatingMax")?.value);
  const ageMin = Number(document.getElementById("fAgeMin")?.value);
  const ageMax = Number(document.getElementById("fAgeMax")?.value);
  const myBid = document.getElementById("fMyBid")?.value || "";

  return marketRows.filter((row) => {
    if (name && !String(row.player_name || "").toLowerCase().includes(name)) {
      return false;
    }
    if (position && row.position !== position) return false;
    if (nation && row.nation !== nation) return false;
    if (playstyle && row.playstyle !== playstyle) return false;
    if (club && row.holding_club !== club) return false;

    const rating = Number(row.rating);
    if (Number.isFinite(ratingMin) && document.getElementById("fRatingMin")?.value !== "") {
      if (!Number.isFinite(rating) || rating < ratingMin) return false;
    }
    if (Number.isFinite(ratingMax) && document.getElementById("fRatingMax")?.value !== "") {
      if (!Number.isFinite(rating) || rating > ratingMax) return false;
    }

    const age = Number(row.age);
    if (Number.isFinite(ageMin) && document.getElementById("fAgeMin")?.value !== "") {
      if (!Number.isFinite(age) || age < ageMin) return false;
    }
    if (Number.isFinite(ageMax) && document.getElementById("fAgeMax")?.value !== "") {
      if (!Number.isFinite(age) || age > ageMax) return false;
    }

    if (myBid === "yes" && row.my_wage_bid == null) return false;
    if (myBid === "no" && row.my_wage_bid != null) return false;

    return true;
  });
}

function formatMv(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  return `<span class="money">₿ ${n.toLocaleString("en-GB")}</span>`;
}

function renderMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  const rows = filteredRows();

  if (!marketRows.length) {
    status.textContent =
      "No players on the expiring-contract market right now (final-year standard players only).";
    tbody.innerHTML = '<tr><td colspan="11">—</td></tr>';
    return;
  }

  status.textContent =
    rows.length === marketRows.length
      ? `${marketRows.length} player(s) — hidden bids until season rollover (₿250,000 steps).`
      : `Showing ${rows.length} of ${marketRows.length} — hidden bids until season rollover.`;

  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="11">No players match these filters.</td></tr>';
    return;
  }

  tbody.innerHTML = rows
    .map((row) => {
      const myBid =
        row.my_wage_bid != null
          ? `<span class="my-bid">${formatWage(row.my_wage_bid)}</span>`
          : "—";
      return `
        <tr data-player-id="${row.player_id}">
          <td class="name-cell">${escapeHtml(row.player_name)}</td>
          <td>${escapeHtml(row.position || "—")}</td>
          <td>${escapeHtml(row.nation || "—")}</td>
          <td>${row.age ?? "—"}</td>
          <td>${row.rating ?? "—"}</td>
          <td>${escapeHtml(row.playstyle || "—")}</td>
          <td>${formatMv(row.market_value)}</td>
          <td>${escapeHtml(displayClubName(row.holding_club))}</td>
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

async function loadMarket() {
  const status = document.getElementById("marketStatus");
  const tbody = document.getElementById("marketBody");
  status.textContent = "Loading…";

  const { data, error } = await supabase.rpc("list_expiring_contract_market");

  if (error) {
    status.textContent =
      "Could not load market — run patches/expiring_contracts_gpdb_filters.sql if filters/columns are missing.";
    tbody.innerHTML = "";
    console.error(error);
    return;
  }

  marketRows = Array.isArray(data) ? data : [];
  rebuildFilterOptions();
  renderMarket();
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
  const step = Number(row.wage_step) || expiryWageBidStep();
  const minOffer =
    row.min_wage_offer != null
      ? Number(row.min_wage_offer)
      : minExpiryWageOffer(row.current_wage, step);

  document.getElementById("bidModalTitle").textContent = `Bid — ${row.player_name}`;
  document.getElementById("bidModalHint").textContent =
    `Current wage ${formatWage(row.current_wage)}. Offer must be higher, in ${formatWage(step)} steps (minimum ${formatWage(minOffer)}). Bids stay hidden until season rollover.`;
  document.getElementById("bidWageInput").value =
    row.my_wage_bid != null
      ? String(row.my_wage_bid)
      : String(minOffer);
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
  const step = Number(bidTarget.wage_step) || expiryWageBidStep();
  const minOffer =
    bidTarget.min_wage_offer != null
      ? Number(bidTarget.min_wage_offer)
      : minExpiryWageOffer(bidTarget.current_wage, step);

  if (!Number.isFinite(wage) || wage <= 0) {
    errEl.textContent = "Enter a valid wage amount.";
    return;
  }
  if (wage % step !== 0) {
    errEl.textContent = `Wage offers must be in ${formatWage(step)} increments.`;
    return;
  }
  if (wage < minOffer) {
    errEl.textContent = `Minimum offer is ${formatWage(minOffer)} (above current wage).`;
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
