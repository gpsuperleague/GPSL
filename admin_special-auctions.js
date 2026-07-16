import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function toIsoFromLocalInput(val) {
  if (!val) return null;
  return new Date(val).toISOString();
}

/** Add minutes to a datetime-local value, keeping local wall-clock (not UTC). */
function addMinutesToLocalInput(localVal, minutes) {
  if (!localVal) return "";
  const d = new Date(localVal);
  if (Number.isNaN(d.getTime())) return "";
  d.setMinutes(d.getMinutes() + minutes);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(
    d.getMinutes()
  )}`;
}

function parseIntList(raw, allowed) {
  return String(raw || "")
    .split(/[,;\s]+/)
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isFinite(n) && n > 0 && (!allowed || allowed.includes(n)));
}

function syncTypeUi() {
  const type = document.getElementById("saType")?.value;
  document.body.classList.toggle("show-snap", type === "snap");
  document.body.classList.toggle("show-gauntlet", type === "blind_gauntlet");
  const endEl = document.getElementById("saEnd");
  // Auto types: show computed end, keep editable so timezone mistakes are fixable
  if (endEl) {
    endEl.disabled = false;
    endEl.readOnly = type === "snap" || type === "blind_gauntlet";
  }
}

function fillAutoEnd() {
  const type = document.getElementById("saType")?.value;
  const start = document.getElementById("saStart").value;
  const endEl = document.getElementById("saEnd");
  if (!start || !endEl) return;
  if (type === "snap") {
    endEl.value = addMinutesToLocalInput(start, 60);
  } else if (type === "blind_gauntlet") {
    endEl.value = addMinutesToLocalInput(start, 30);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const typeEl = document.getElementById("saType");
  typeEl.onchange = () => {
    syncTypeUi();
    fillAutoEnd();
  };
  document.getElementById("saStart").onchange = fillAutoEnd;

  document.getElementById("saPrizePlayerSelect")?.addEventListener("change", (e) => {
    document.getElementById("saPrizePlayerId").value = e.target.value || "";
    const known = document.getElementById("saKnownPlayerId");
    if (known && e.target.value) known.value = e.target.value;
  });

  syncTypeUi();
  await loadReservedPlayers();
  await refreshSpecialAuctionSelect();

  document.getElementById("saCreateBtn").onclick = createAuction;
  document.getElementById("saActivateBtn").onclick = activateAuction;
  document.getElementById("saNotifyBtn").onclick = notifyOwners;
  document.getElementById("saRevealBtn").onclick = revealAuction;
  document.getElementById("saSettleBtn").onclick = settleAuction;
  document.getElementById("saGauntletTickBtn")?.addEventListener("click", gauntletTick);
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
    .select("id, title, status, auction_type, start_time, gauntlet_phase")
    .order("id", { ascending: false })
    .limit(30);

  sel.innerHTML = (data || [])
    .map((a) => {
      const phase = a.auction_type === "blind_gauntlet" && a.gauntlet_phase
        ? `/${a.gauntlet_phase}`
        : "";
      return `<option value="${a.id}">#${a.id} ${a.title} [${a.status}${phase}] ${a.auction_type}</option>`;
    })
    .join("");
}

function gauntletPackPayload() {
  return {
    medical_tokens: parseIntList(document.getElementById("saGauntletMedical")?.value, [2, 4, 6, 8, 10]),
    fee_discounts: parseIntList(document.getElementById("saGauntletDiscount")?.value).filter((n) => n <= 50),
    appeal_cards: Math.max(0, Number(document.getElementById("saGauntletAppeals")?.value) || 0),
    draft_tokens: Math.max(0, Number(document.getElementById("saGauntletDraft")?.value) || 0),
  };
}

async function createAuction() {
  const type = document.getElementById("saType").value;
  const startLocal = document.getElementById("saStart").value;
  let endLocal = document.getElementById("saEnd").value;
  if (type === "snap" && startLocal) endLocal = addMinutesToLocalInput(startLocal, 60);
  if (type === "blind_gauntlet" && startLocal) endLocal = addMinutesToLocalInput(startLocal, 30);
  const start = toIsoFromLocalInput(startLocal);
  const end = toIsoFromLocalInput(endLocal);

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

  if (type === "blind_gauntlet") {
    row.gauntlet_phase = "phase1";
    row.gauntlet_prize_pack = gauntletPackPayload();
  }

  if (!start || !end) {
    setStatus("saCreateStatus", "❌ Set start and end times.", false);
    return;
  }

  if (type === "snap" && !row.clue_1 && !row.clue_2 && !row.clue_3 && !row.clue_4) {
    setStatus("saCreateStatus", "❌ Add at least one snap clue.", false);
    return;
  }

  setStatus("saCreateStatus", "Creating…");
  const { data: created, error } = await supabase
    .from("special_auctions")
    .insert(row)
    .select("id")
    .single();

  if (error) {
    setStatus(
      "saCreateStatus",
      "❌ " + error.message + (type === "blind_gauntlet" ? " — run special_auction_blind_gauntlet.sql" : ""),
      false
    );
    return;
  }

  if (type === "blind_gauntlet" && created?.id) {
    const { error: prepErr } = await supabase.rpc("special_auction_gauntlet_prepare", {
      p_auction_id: created.id,
    });
    if (prepErr) {
      setStatus("saCreateStatus", "Created but prepare failed: " + prepErr.message, false);
      await refreshSpecialAuctionSelect();
      return;
    }
  }

  if (document.getElementById("saPublishOnCreate").checked && created?.id) {
    const { error: actErr } = await supabase.rpc("special_auction_activate", {
      p_auction_id: created.id,
    });
    if (!actErr && type === "blind_gauntlet") {
      await supabase.rpc("special_auction_gauntlet_prepare", { p_auction_id: created.id });
    }
    setStatus(
      "saCreateStatus",
      actErr
        ? "✅ Created as draft but publish failed: " + actErr.message
        : "✅ Created and published.",
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
  if (!error) {
    await supabase.rpc("special_auction_gauntlet_prepare", { p_auction_id: id }).catch(() => {});
  }
  setStatus(
    "saManageStatus",
    error ? "❌ " + error.message : "✅ Published (inbox notify sent to owners).",
    !error
  );
  await refreshSpecialAuctionSelect();
}

async function notifyOwners() {
  const id = Number(document.getElementById("saSelect").value);
  if (!id) {
    setStatus("saManageStatus", "Select an auction.", false);
    return;
  }
  const { data, error } = await supabase.rpc("admin_special_auction_notify_scheduled", {
    p_auction_id: id,
    p_force: true,
  });
  if (error) {
    setStatus(
      "saManageStatus",
      "❌ " + error.message + " — run special_auction_inbox_notify.sql",
      false
    );
    return;
  }
  setStatus(
    "saManageStatus",
    `✅ Inbox sent to ${data?.notified ?? 0} owner club(s).`,
    true
  );
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
  await refreshSpecialAuctionSelect();
}

async function gauntletTick() {
  const id = Number(document.getElementById("saSelect").value);
  if (!id) {
    setStatus("saManageStatus", "Select an auction.", false);
    return;
  }
  setStatus("saManageStatus", "Running Gauntlet tick…");
  const { data, error } = await supabase.rpc("special_auction_gauntlet_tick", {
    p_auction_id: id,
  });
  if (error) {
    setStatus(
      "saManageStatus",
      "❌ " + error.message + " — run special_auction_blind_gauntlet.sql",
      false
    );
    return;
  }
  setStatus(
    "saManageStatus",
    `✅ Gauntlet tick OK (${(data?.events || []).length} event(s)).`,
    true
  );
  await refreshSpecialAuctionSelect();
}
