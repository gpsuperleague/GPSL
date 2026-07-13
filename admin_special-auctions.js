import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function toIsoFromLocalInput(val) {
  if (!val) return null;
  return new Date(val).toISOString();
}

function snapEndOneHourAfterStart(startIso) {
  const t = new Date(startIso);
  t.setHours(t.getHours() + 1);
  return t.toISOString();
}

function syncSnapUi() {
  const isSnap = document.getElementById("saType")?.value === "snap";
  document.body.classList.toggle("show-snap", isSnap);
  const endEl = document.getElementById("saEnd");
  if (endEl) endEl.disabled = isSnap;
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const typeEl = document.getElementById("saType");
  const endEl = document.getElementById("saEnd");

  typeEl.onchange = () => {
    syncSnapUi();
    if (typeEl.value === "snap") {
      const start = document.getElementById("saStart").value;
      if (start) {
        endEl.value = new Date(snapEndOneHourAfterStart(toIsoFromLocalInput(start)))
          .toISOString()
          .slice(0, 16);
      }
    }
  };
  document.getElementById("saStart").onchange = () => {
    if (typeEl.value === "snap" && document.getElementById("saStart").value) {
      endEl.value = new Date(
        snapEndOneHourAfterStart(toIsoFromLocalInput(document.getElementById("saStart").value))
      )
        .toISOString()
        .slice(0, 16);
    }
  };

  document.getElementById("saPrizePlayerSelect")?.addEventListener("change", (e) => {
    document.getElementById("saPrizePlayerId").value = e.target.value || "";
    const known = document.getElementById("saKnownPlayerId");
    if (known && e.target.value) known.value = e.target.value;
  });

  syncSnapUi();
  await loadReservedPlayers();
  await refreshSpecialAuctionSelect();

  document.getElementById("saCreateBtn").onclick = createAuction;
  document.getElementById("saActivateBtn").onclick = activateAuction;
  document.getElementById("saRevealBtn").onclick = revealAuction;
  document.getElementById("saSettleBtn").onclick = settleAuction;
});

async function loadReservedPlayers() {
  const sel = document.getElementById("saPrizePlayerSelect");
  if (!sel) return;
  const { data, error } = await supabase.rpc("admin_auction_exclusion_list");
  if (error) {
    sel.innerHTML = `<option value="">Run auction_exclusions.sql — ${error.message}</option>`;
    return;
  }
  sel.innerHTML =
    `<option value="">— select reserved player —</option>` +
    (data || [])
      .map(
        (r) =>
          `<option value="${r.player_id}">${r.player_name || r.player_id} (${r.player_id})${
            r.rating != null ? ` · ${r.rating}` : ""
          }</option>`
      )
      .join("");
}

async function refreshSpecialAuctionSelect() {
  const sel = document.getElementById("saSelect");
  const { data } = await supabase
    .from("special_auctions")
    .select("id, title, status, auction_type, start_time")
    .order("id", { ascending: false })
    .limit(30);

  sel.innerHTML = (data || [])
    .map(
      (a) =>
        `<option value="${a.id}">#${a.id} ${a.title} [${a.status}] ${a.auction_type}</option>`
    )
    .join("");
}

async function createAuction() {
  const type = document.getElementById("saType").value;
  const start = toIsoFromLocalInput(document.getElementById("saStart").value);
  let end = toIsoFromLocalInput(document.getElementById("saEnd").value);
  if (type === "snap" && start) end = snapEndOneHourAfterStart(start);

  const prizeType = document.getElementById("saPrizeType").value;
  const prizePlayerId =
    document.getElementById("saPrizePlayerId")?.value?.trim() ||
    document.getElementById("saPrizePlayerSelect")?.value?.trim() ||
    null;

  if (prizeType === "player" && !prizePlayerId) {
    setStatus("saCreateStatus", "❌ Pick a reserved player for a player prize.", false);
    return;
  }

  const row = {
    auction_type: type,
    title: document.getElementById("saTitle").value.trim() || "Special auction",
    status: "draft",
    start_time: start,
    end_time: end,
    prize_type: prizeType,
    prize_player_id: prizeType === "player" ? prizePlayerId : null,
    prize_cash_amount:
      Number(document.getElementById("saPrizeCash").value.replace(/[^\d]/g, "")) || null,
    prize_discount_label: document.getElementById("saPrizeDiscount").value.trim() || null,
    player_mode: document.getElementById("saPlayerMode").value,
    mystery_clue: document.getElementById("saMysteryClue").value.trim() || null,
    known_player_id: document.getElementById("saKnownPlayerId").value.trim() || null,
    clue_1: document.getElementById("saClue1")?.value?.trim() || null,
    clue_2: document.getElementById("saClue2")?.value?.trim() || null,
    clue_3: document.getElementById("saClue3")?.value?.trim() || null,
    clue_4: document.getElementById("saClue4")?.value?.trim() || null,
    snap_bid_fee: 300000,
  };

  if (!start || !end) {
    setStatus("saCreateStatus", "❌ Set start and end times.", false);
    return;
  }

  if (type === "snap" && !row.clue_1 && !row.clue_2 && !row.clue_3 && !row.clue_4) {
    setStatus("saCreateStatus", "❌ Add at least one snap clue.", false);
    return;
  }

  const { data: created, error } = await supabase
    .from("special_auctions")
    .insert(row)
    .select("id")
    .single();

  if (error) {
    setStatus("saCreateStatus", "❌ " + error.message, false);
    return;
  }

  if (document.getElementById("saPublishOnCreate").checked && created?.id) {
    const { error: actErr } = await supabase.rpc("special_auction_activate", {
      p_auction_id: created.id,
    });
    setStatus(
      "saCreateStatus",
      actErr
        ? "✅ Created as draft but publish failed: " + actErr.message
        : "✅ Created and published (snap random end set on activate).",
      !actErr
    );
  } else {
    setStatus("saCreateStatus", "✅ Created as draft.", true);
  }
  await refreshSpecialAuctionSelect();
}

async function activateAuction() {
  const id = Number(document.getElementById("saSelect").value);
  if (!id) {
    setStatus("saManageStatus", "Select an auction.", false);
    return;
  }
  const { error } = await supabase.rpc("special_auction_activate", { p_auction_id: id });
  setStatus("saManageStatus", error ? "❌ " + error.message : "✅ Published.", !error);
  await refreshSpecialAuctionSelect();
}

async function revealAuction() {
  const id = Number(document.getElementById("saSelect").value);
  const { error } = await supabase.rpc("special_auction_reveal_lowest_unique", {
    p_auction_id: id,
  });
  setStatus("saManageStatus", error ? "❌ " + error.message : "✅ Bids revealed.", !error);
}

async function settleAuction() {
  const id = Number(document.getElementById("saSelect").value);
  const { error } = await supabase.rpc("special_auction_settle", { p_auction_id: id });
  setStatus("saManageStatus", error ? "❌ " + error.message : "✅ Settled.", !error);
}
