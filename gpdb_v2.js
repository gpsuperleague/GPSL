/* ============================================================
 MODULE A: Supabase Client (imports MUST be at top)
 ============================================================ */

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

const supabase = createClient(
  'https://omyyogfumrjoaweuawjn.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4'
);

let draftAuctionStartTime = null;
let draftRandomFinishTime = null;

/* ============================================================
   TIME HELPERS – REAL UK TIME, INDEPENDENT OF USER TIMEZONE
   ============================================================ */

// Current time in UK (Europe/London), regardless of where the user is
function getUKNow() {
  const now = new Date();
  const ukString = now.toLocaleString("en-GB", { timeZone: "Europe/London" });
  return new Date(ukString);
}

// Build a stable Date for the intended UK wall-clock time
function makeUKDate(year, month, day, hour = 0, minute = 0, second = 0) {
  return new Date(Date.UTC(year, month, day, hour, minute, second));
}

// Small helper to validate Date objects
function isValidDate(d) {
  return d instanceof Date && !isNaN(d.getTime());
}

function getDraftWindowTimes() {
  const nowUK = getUKNow();

  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();

  // Build a safe "today" at midnight UK
  const todayMidnight = makeUKDate(y, m, d, 0, 0, 0);

  // Subtract 24 hours to get yesterday safely
  const yesterdayMidnight = new Date(todayMidnight.getTime() - 24 * 60 * 60 * 1000);

  // Build 19:00 yesterday using the safe date
  const sevenPmYesterday = makeUKDate(
    yesterdayMidnight.getUTCFullYear(),
    yesterdayMidnight.getUTCMonth(),
    yesterdayMidnight.getUTCDate(),
    19, 0, 0
  );

  const sixPmToday = makeUKDate(y, m, d, 18, 0, 0);
  const sevenPmToday = makeUKDate(y, m, d, 19, 0, 0);

  return { sevenPmYesterday, sixPmToday, sevenPmToday };
}

/* ============================================================
   DRAFT CREDITS PANEL (GPDB VIEW)
   ============================================================ */

async function loadDraftCreditsForOwner() {
 console.log("DEBUG draftRandomFinishTime =", draftRandomFinishTime);
  try {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;

    const { data: club } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", user.id)
      .single();

    if (!club) return;

    const buyerShortName = club.ShortName;

    const { data: settings } = await supabase
      .from("global_settings")
      .select("draft_auction_enabled")
      .eq("id", 1)
      .single();

    if (!settings?.draft_auction_enabled) {
      document.getElementById("draftCreditsPanel").textContent = "";
      return;
    }

    const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();
    const credits = await getDraftCreditsForGPDB(buyerShortName);

    const { data: firsts } = await supabase
      .from("Player_Transfer_Bids")
      .select("direct_bid_id")
      .eq("bidder_club_id", buyerShortName)
      .eq("is_first_draft_bid", true)
      .gte("bid_time", sevenPmYesterday.toISOString())
      .lt("bid_time", sixPmToday.toISOString());

    const firstCount = firsts ? firsts.length : 0;
    const earned = firstCount * 2;

    // Guard draftRandomFinishTime to avoid invalid Date
    const rawJoinEnd = draftRandomFinishTime;
    const joinWindowEnd = isValidDate(rawJoinEnd) ? rawJoinEnd : sixPmToday;

    const { data: joins } = await supabase
      .from("Player_Transfer_Bids")
      .select("direct_bid_id")
      .eq("bidder_club_id", buyerShortName)
      .eq("is_draft_join", true)
      .eq("draft_join_consumed", true)
      .gte("bid_time", sevenPmYesterday.toISOString())
      .lt("bid_time", joinWindowEnd.toISOString());

    const used = joins ? new Set(joins.map(j => j.direct_bid_id)).size : 0;

    const remaining = credits;

    document.getElementById("draftCreditsPanel").innerHTML = `
      <b>Draft Credits:</b> ${remaining}<br>
      <span style="font-size:11px;color:#aaa;">
        Earned: ${earned} | Used: ${used}
      </span>
    `;
  } catch (err) {
    console.error("Error loading draft credits:", err);
  }
}

async function getDraftCreditsForGPDB(clubShortName) {
 console.log("DEBUG draftRandomFinishTime =", draftRandomFinishTime);
  const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();

  const { data: firsts } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_first_draft_bid", true)
    .gte("bid_time", sevenPmYesterday.toISOString())
    .lt("bid_time", sixPmToday.toISOString());

  // Guard draftRandomFinishTime to avoid invalid Date
  const rawJoinEnd = draftRandomFinishTime;
  const joinWindowEnd = isValidDate(rawJoinEnd) ? rawJoinEnd : sixPmToday;

  const { data: joins } = await supabase
    .from("Player_Transfer_Bids")
    .select("direct_bid_id")
    .eq("bidder_club_id", clubShortName)
    .eq("is_draft_join", true)
    .eq("draft_join_consumed", true)
    .gte("bid_time", sevenPmYesterday.toISOString())
    .lt("bid_time", joinWindowEnd.toISOString());

  const firstCount = firsts ? firsts.length : 0;
  const joinCount = joins ? new Set(joins.map(j => j.direct_bid_id)).size : 0;

  return (firstCount * 2) - joinCount;
}

/* ============================================================
   EVERYTHING ELSE MUST BE INSIDE DOMContentLoaded
   ============================================================ */

document.addEventListener("DOMContentLoaded", () => {

  /* ============================================================
     MODULE B: Column Definitions
     ============================================================ */

  const COLUMNS = [
    "Name",
    "Position",
    "Nation",
    "Age",
    "Rating",
    "Playstyle",
    "Maximum_Reserve_Price",
    "market_value",
    "Contracted_Team",
    "Season_Signed",
    "Konami_ID"
  ];

  const FILTER_EXCLUDE = [
    "Maximum_Reserve_Price",
    "market_value",
    "Konami_ID"
  ];

  const DROPDOWN_COLUMNS = [
    "Nation",
    "Position",
    "Age",
    "Rating",
    "Playstyle",
    "Contracted_Team",
    "Season_Signed"
  ];

  const POSITION_ORDER = [
    "GK", "LB", "CB", "RB",
    "DMF", "LMF", "CMF", "RMF",
    "AMF", "LWF", "SS", "RWF", "CF"
  ];

  /* ============================================================
     MODULE C: Pagination + State
     ============================================================ */

  let PAGE_SIZE = 1000;
  let TOTAL_ROWS = 0;
  let CURRENT_PAGE = 1;

  let CURRENT_FILTERS = {};

  let CURRENT_SORT_COLUMN = "Rating";
  let CURRENT_SORT_DIR = "desc";

  let MV_MIN = null;
  let MV_MAX = null;
  /* ============================================================
     MODULE D: Global Settings Loader
     ============================================================ */

  let GLOBAL_SETTINGS = null;
  let CURRENT_USER = null;
  let ACTIVE_DRAFT_PLAYERS = new Set();

  let CLUB_NAME_MAP = {};

  async function loadUser() {
    const { data: { user } } = await supabase.auth.getUser();
    CURRENT_USER = user;
  }

  async function loadGlobalSettings() {
    const { data, error } = await supabase
      .from("global_settings")
      .select("*")
      .eq("id", 1)
      .single();

    if (error || !data) {
      console.error("Failed to load global settings:", error);
      return {
        transferWindowOpen: false,
        draftAuctionEnabled: false,
        draftAuctionStartTime: null,
        draftRandomFinishTime: null
      };
    }

    // Parse and validate date fields
    let parsedStart = null;
    let parsedRandomFinish = null;

    try {
      if (data.draft_auction_start_time) {
        const tmp = new Date(data.draft_auction_start_time);
        parsedStart = isValidDate(tmp) ? tmp : null;
      }
    } catch (e) {
      parsedStart = null;
    }

    try {
      if (data.draft_random_finish_time) {
        const tmp = new Date(data.draft_random_finish_time);
        parsedRandomFinish = isValidDate(tmp) ? tmp : null;
      }
    } catch (e) {
      parsedRandomFinish = null;
    }

    return {
      transferWindowOpen: data.transfer_window_open,
      draftAuctionEnabled: data.draft_auction_enabled,
      draftAuctionStartTime: parsedStart,
      draftRandomFinishTime: parsedRandomFinish
    };
  }

  async function loadClubNames() {
    const { data, error } = await supabase
      .from("Clubs")
      .select("ShortName, Club");

    if (error || !data) {
      console.error("Failed to load club names:", error);
      CLUB_NAME_MAP = {};
      return;
    }

    CLUB_NAME_MAP = {};
    data.forEach(c => {
      if (c.ShortName) {
        CLUB_NAME_MAP[c.ShortName] = c.Club || c.ShortName;
      }
    });
  }

                          /* ============================================================
     MODULE E: Data Loading
     ============================================================ */

  async function loadTotalCount() {
    const { count } = await supabase
      .from("Players")
      .select("*", { count: "exact", head: true });

    TOTAL_ROWS = count;
  }

  function buildContractedTeamOrClause(values) {
    const hasFA = values.includes("FREE AGENT");
    const clubs = values.filter(v => v !== "FREE AGENT");

    const parts = [];

    if (clubs.length > 0) {
      const inList = clubs.join(",");
      parts.push(`Contracted_Team.in.(${inList})`);
    }

    if (hasFA) {
      parts.push("Contracted_Team.is.null", "Contracted_Team.eq.''", "Contracted_Team.eq.' '");
    }

    return parts.length ? parts.join(",") : null;
  }

  async function loadPage(page = 1) {
    CURRENT_PAGE = page;

    const from = (page - 1) * PAGE_SIZE;
    const to = from + PAGE_SIZE - 1;

    let query = supabase
      .from("Players")
      .select(COLUMNS.join(","), { count: "exact" });

    Object.entries(CURRENT_FILTERS).forEach(([col, value]) => {
      if (DROPDOWN_COLUMNS.includes(col)) {
        const values = Array.isArray(value) ? value : (value ? [value] : []);
        if (!values.length) return;

        if (col === "Contracted_Team") {
          const orClause = buildContractedTeamOrClause(values);
          if (orClause) {
            query = query.or(orClause);
          }
        } else {
          query = query.in(col, values);
        }
      } else {
        if (!value || value.trim() === "") return;
        query = query.ilike(col, `%${value}%`);
      }
    });

    if (MV_MIN !== null) query = query.gte("market_value", MV_MIN);
    if (MV_MAX !== null) query = query.lte("market_value", MV_MAX);

    if (CURRENT_SORT_COLUMN) {
      if (CURRENT_SORT_COLUMN === "Rating") {
        query = query
          .order("Rating", { ascending: false })
          .order("market_value", { ascending: false });
      } else if (CURRENT_SORT_COLUMN === "market_value") {
        query = query
          .order("market_value", { ascending: CURRENT_SORT_DIR === "asc" })
          .order("Rating", { ascending: false });
      } else if (CURRENT_SORT_COLUMN === "Position") {
        // No server-side order for Position; we'll sort client-side
      } else {
        query = query.order(CURRENT_SORT_COLUMN, {
          ascending: CURRENT_SORT_DIR === "asc"
        });
      }
    } else {
      query = query
        .order("Rating", { ascending: false })
        .order("market_value", { ascending: false });
    }

    query = query.range(from, to);

    const { data, error, count } = await query;

    if (error) {
      console.error(error);
      return;
    }

    let filtered = data;
    if (MV_MIN !== null || MV_MAX !== null) {
      filtered = data.filter(row => {
        const mv = Number(String(row.market_value).replace(/,/g, "").trim()) || 0;

        if (MV_MIN !== null && mv < MV_MIN) return false;
        if (MV_MAX !== null && mv > MV_MAX) return false;

        return true;
      });
    }

    if (CURRENT_SORT_COLUMN === "Position") {
      filtered.sort((a, b) => {
        const ai = POSITION_ORDER.indexOf(a.Position);
        const bi = POSITION_ORDER.indexOf(b.Position);
        const aIdx = ai === -1 ? 999 : ai;
        const bIdx = bi === -1 ? 999 : bi;
        return CURRENT_SORT_DIR === "asc" ? aIdx - bIdx : bIdx - aIdx;
      });
    }

    TOTAL_ROWS = count;
    renderTable(filtered);
    renderPagination();
  }

  function formatHeader(col) {
    if (col === "market_value") return "Market Value";
    if (col === "Maximum_Reserve_PPrice") return "Maximum Reserve Price";
    return col.replace(/_/g, " ");
  }

  /* ============================================================
     MODULE F: Rendering (with Bid column)
     ============================================================ */

  function renderTable(players) {
    const tableHead = document.getElementById("tableHead");
    const tableBody = document.getElementById("tableBody");

    if (!players || players.length === 0) {
      tableHead.innerHTML = "<tr><th>No data</th></tr>";
      tableBody.innerHTML = "";
      return;
    }

    tableHead.innerHTML = `
      <tr>
        <th></th>
        ${COLUMNS.filter(col => col !== "Konami_ID")
          .map(col => {
            let cls = "";
            if (CURRENT_SORT_COLUMN === col) {
              cls = CURRENT_SORT_DIR === "asc" ? "sort-asc" : "sort-desc";
            }
            return `<th data-col="${col}" class="${cls}">${formatHeader(col)}</th>`;
          })
          .join("")}
        <th>Bid</th>
      </tr>
    `;

    tableBody.innerHTML = players
      .map(player => {
        const hasClub = !!player.Contracted_Team;
        const isMyClub = player.Contracted_Team === CURRENT_USER?.user_metadata?.shortName;

        let bidCell = `<span class="locked-msg">Loading…</span>`;

        if (GLOBAL_SETTINGS) {
          if (hasClub) {
            if (!isMyClub && GLOBAL_SETTINGS.transferWindowOpen) {
              bidCell = `<button class="button make-offer-btn" data-player-id="${player.Konami_ID}">Make Offer</button>`;
            } else if (!GLOBAL_SETTINGS.transferWindowOpen) {
              bidCell = `<span class="locked-msg">Window Closed</span>`;
            } else {
              bidCell = `<span class="locked-msg">Your Player</span>`;
            }
          } else {
            const inDraft = ACTIVE_DRAFT_PLAYERS.has(String(player.Konami_ID).trim());

            if (inDraft) {
              bidCell = `<span class="locked-msg">In Draft Auction</span>`;
            } else if (GLOBAL_SETTINGS.draftAuctionEnabled) {
              const nowLocal = getUKNow();
              const { sixPmToday } = getDraftWindowTimes();

              if (draftAuctionStartTime && nowLocal < draftAuctionStartTime) {
                bidCell = `<span class="locked-msg">Draft Closed</span>`;
              } else if (nowLocal >= sixPmToday) {
                bidCell = `<span class="locked-msg">Draft Locked</span>`;
              } else {
                bidCell = `<button class="button make-offer-btn" data-player-id="${player.Konami_ID}">Make Offer</button>`;
              }
            } else {
              bidCell = `<span class="locked-msg">Draft Closed</span>`;
            }
          }
        }

        const imgURL = `https://pesdb.net/assets/img/card/b${player.Konami_ID}.png`;

        return `
          <tr data-konami-id="${player.Konami_ID}">
            <td>
              <img src="${imgURL}"
                   class="gpdb-thumb"
                   onerror="this.src='https://i.imgur.com/3s8XQ7Y.png'">
            </td>
            ${COLUMNS.filter(col => col !== "Konami_ID")
              .map(col => {
                let value = player[col];

                if (col === "market_value" && value !== null) {
                  value = `<span class="money">₿ ${Number(value).toLocaleString("en-GB")}</span>`;
                }

                if (col === "Maximum_Reserve_Price" && value !== null) {
                  value = "₿ " + Number(value).toLocaleString("en-GB");
                }

                if (col === "Contracted_Team") {
                  if (!value || String(value).trim() === "") {
                    value = "";
                  } else {
                    value = CLUB_NAME_MAP[value] || value;
                  }
                }

                return `<td>${value}</td>`;
              })
              .join("")}
            <td>${bidCell}</td>
          </tr>
        `;
      })
      .join("");
    Array.from(tableHead.querySelectorAll("th[data-col]")).forEach(th => {
      const col = th.getAttribute("data-col");
      th.onclick = () => {
        if (CURRENT_SORT_COLUMN === col) {
          CURRENT_SORT_DIR = CURRENT_SORT_DIR === "asc" ? "desc" : "asc";
        } else {
          CURRENT_SORT_COLUMN = col;
          CURRENT_SORT_DIR = "asc";
        }
        loadPage(1);
      };
    });

    Array.from(tableBody.querySelectorAll("tr")).forEach(row => {
      row.style.cursor = "pointer";
      row.addEventListener("click", e => {
        if (e.target.closest(".make-offer-btn")) return;
        const konamiId = row.getAttribute("data-konami-id");
        window.open(
          `https://pesdb.net/efootball/?id=${konamiId}`,
          "_blank",
          "noopener"
        );
      });
    });

    document.querySelectorAll(".make-offer-btn").forEach(btn => {
      btn.addEventListener("click", () => openMakeOfferModal(btn.dataset.playerId));
    });
  }

      /* ============================================================
     MODULE G: Offer Modal + Draft Helpers
     ============================================================ */

  let CURRENT_OFFER_PLAYER = null;

  function openMakeOfferModal(konamiId) {
    const row = document.querySelector(`tr[data-konami-id="${konamiId}"]`);
    if (!row) return;

    const cells = row.querySelectorAll("td");
    const img = cells[0].querySelector("img");

    const name = cells[1].textContent;
    const position = cells[2].textContent;
    const playstyle = cells[5].textContent;
    const rating = cells[4].textContent;
    const mvText = cells[7].textContent;

    const mv = Number(String(mvText).replace(/[^\d]/g, "")) || 0;

    CURRENT_OFFER_PLAYER = {
      Konami_ID: konamiId,
      Name: name,
      Position: position,
      Playstyle: playstyle,
      Rating: rating,
      market_value: mv,
      Contracted_Team: row.querySelectorAll("td")[8].textContent.trim() || null
    };

    document.getElementById("offerPlayerImg").src = img.src;
    document.getElementById("offerPlayerName").textContent = name;
    document.getElementById("offerPlayerPosition").textContent = `Position: ${position}`;
    document.getElementById("offerPlayerPlaystyle").textContent = `Playstyle: ${playstyle}`;
    document.getElementById("offerPlayerRating").textContent = `Rating: ${rating}`;
    document.getElementById("offerPlayerMV").textContent = `Market Value: ₿ ${mv.toLocaleString("en-GB")}`;

    document.getElementById("offerAmount").value = mv.toLocaleString("en-GB");
    document.getElementById("offerError").textContent = "";

    const backdrop = document.getElementById("make-offer-modal-backdrop");
    backdrop.style.display = "flex";
  }

  function closeMakeOfferModal() {
    const backdrop = document.getElementById("make-offer-modal-backdrop");
    backdrop.style.display = "none";
    CURRENT_OFFER_PLAYER = null;
  }

  document.getElementById("cancelOfferBtn").onclick = () => {
    closeMakeOfferModal();
  };

  document.getElementById("confirmOfferBtn").onclick = async () => {

    const nowLocal = getUKNow();

    const input = document.getElementById("offerAmount");
    const errorBox = document.getElementById("offerError");

    let raw = input.value.replace(/,/g, "").trim();
    let offer = Number(raw);

    if (!offer || offer <= 0) {
      errorBox.textContent = "Enter a valid positive number.";
      return;
    }

    const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
    if (offer < mv) {
      offer = mv;
      input.value = offer.toLocaleString("en-GB");
    }

    const sellerClub = CURRENT_OFFER_PLAYER.Contracted_Team;

    if (!sellerClub) {
      if (draftAuctionStartTime && nowLocal < draftAuctionStartTime) {
        errorBox.textContent = "Draft auction has not started yet.";
        return;
      }
    }

    const { data: clubRow, error: clubErr } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", CURRENT_USER.id)
      .single();

    if (clubErr || !clubRow) {
      errorBox.textContent = "Your club could not be found.";
      return;
    }

    const myClub = clubRow.ShortName;

    if (!sellerClub && !GLOBAL_SETTINGS.draftAuctionEnabled) {
      errorBox.textContent = "Draft Auction is locked. You cannot bid on free agents.";
      return;
    }

    if (sellerClub === myClub) {
      errorBox.textContent = "You cannot make an offer for your own player.";
      return;
    }

    if (sellerClub && !GLOBAL_SETTINGS.transferWindowOpen) {
      errorBox.textContent = "Transfer window is closed for contracted players.";
      return;
    }

    if (!sellerClub) {
      const result = await submitDraftBid(CURRENT_OFFER_PLAYER, offer, myClub);

      if (!result.ok) {
        errorBox.textContent = result.msg;
        return;
      }

      ACTIVE_DRAFT_PLAYERS.add(String(CURRENT_OFFER_PLAYER.Konami_ID).trim());
      closeMakeOfferModal();
      alert("Draft bid submitted!");
      loadPage(CURRENT_PAGE);
      return;
    }

    const { error } = await supabase.from("Player_Transfer_Bids").insert({
      listing_id: null,
      direct_bid_id: CURRENT_OFFER_PLAYER.Konami_ID,
      bidder_club_id: myClub,
      seller_club_id: sellerClub || null,
      bid_amount: offer,
      bid_time: new Date().toISOString(),
      is_direct: true
    });

    if (error) {
      errorBox.textContent = "Failed to submit offer.";
      console.error(error);
      return;
    }

    closeMakeOfferModal();
  };

  /* ============================================================
     DRAFT AUCTION HELPERS
     ============================================================ */

 function getDraftAuctionTimesForNewListing() {
  const nowUK = getUKNow();

  const y = nowUK.getFullYear();
  const m = nowUK.getMonth();
  const d = nowUK.getDate();

  // Start today at 19:00 UK
  const sevenPmToday = makeUKDate(y, m, d, 19, 0, 0);

  // Tomorrow at 18:50 UK
  const baseEnd = makeUKDate(y, m, d + 1, 18, 50, 0);

  // Add 0–599 random seconds
  const extraSeconds = Math.floor(Math.random() * 600);
  const end = new Date(baseEnd.getTime() + extraSeconds * 1000);

  return { start: sevenPmToday, end };
}

  async function ensureDraftListingForPlayer(player) {
    const konamiStr = String(player.Konami_ID).trim();

    const { data: existing } = await supabase
      .from("Player_Transfer_Listings")
      .select("id")
      .eq("player_id", konamiStr)
      .eq("listing_type", "draft")
      .eq("status", "active")
      .maybeSingle();

    if (existing) {
      return { ok: true, listingId: existing.id };
    }

    const { start, end } = getDraftAuctionTimesForNewListing();

    const { data: listing, error } = await supabase
      .from("Player_Transfer_Listings")
      .insert({
        player_id: konamiStr,
        seller_club_id: null,
        reserve_price: player.market_value || 0,
        listing_type: "draft",
        market_value: player.market_value || 0,
        status: "active",
        start_time: start.toISOString(),
        end_time: end.toISOString(),
        created_at: new Date().toISOString()
      })
      .select("*")
      .single();

    if (error || !listing) {
      console.error("Error creating draft listing:", error);
      return { ok: false, msg: "Error creating draft listing." };
    }

    return { ok: true, listingId: listing.id };
  }

  async function insertDraftBid(player, amount, club, isFirst, isJoin, consumeJoin, listingId) {
    const { data, error } = await supabase
      .from("Player_Transfer_Bids")
      .insert({
        listing_id: listingId,
        direct_bid_id: player.Konami_ID,
        bidder_club_id: club,
        bid_amount: amount,
        is_direct: true,
        is_first_draft_bid: isFirst,
        is_draft_join: isJoin,
        draft_join_consumed: consumeJoin,
        bid_time: new Date().toISOString()
      })
      .select("*")
      .single();

    if (error || !data) {
      console.error("Error inserting draft bid:", error);
      return { ok: false, msg: "Error submitting draft bid." };
    }

    return { ok: true, bid: data };
  }

  async function submitDraftBid(player, offerAmount, buyerShortName) {

    const nowLocal = getUKNow();

    const { sevenPmYesterday, sixPmToday } = getDraftWindowTimes();
    // Global draft start gate
    if (draftAuctionStartTime && nowLocal < draftAuctionStartTime) {
      return { ok: false, msg: "Draft auction has not started yet." };
    }

    const { data: existing } = await supabase
      .from("Player_Transfer_Bids")
      .select("bidder_club_id")
      .eq("direct_bid_id", player.Konami_ID)
      .eq("is_direct", true)
      .order("bid_time", { ascending: true });

    const isFirstBid = !existing || existing.length === 0;
    const isJoining = !isFirstBid;

    if (isFirstBid && nowLocal >= sixPmToday) {
      return {
        ok: false,
        msg: "New draft auctions are locked until the next draft window."
      };
    }

    const listingResult = await ensureDraftListingForPlayer(player);
    if (!listingResult.ok) return listingResult;

    const listingId = listingResult.listingId;

    let bidResult;

    if (isJoining) {
      const { data: priorJoin } = await supabase
        .from("Player_Transfer_Bids")
        .select("bid_id")
        .eq("direct_bid_id", player.Konami_ID)
        .eq("bidder_club_id", buyerShortName)
        .eq("is_draft_join", true);

      if (priorJoin && priorJoin.length > 0) {
        bidResult = await insertDraftBid(
          player,
          offerAmount,
          buyerShortName,
          false,
          true,
          false,
          listingId
        );
      } else {
        const credits = await getDraftCreditsForGPDB(buyerShortName);
        if (credits <= 0) {
          return { ok: false, msg: "You do not have enough draft credits to join this auction." };
        }

        bidResult = await insertDraftBid(
          player,
          offerAmount,
          buyerShortName,
          false,
          true,
          true,
          listingId
        );
      }
    } else {
      bidResult = await insertDraftBid(
        player,
        offerAmount,
        buyerShortName,
        true,
        false,
        false,
        listingId
      );
    }

    if (!bidResult.ok) return bidResult;

    return { ok: true };
  }

  async function loadActiveDraftListings() {
    const { data, error } = await supabase
      .from("Player_Transfer_Listings")
      .select("player_id")
      .eq("listing_type", "draft")
      .eq("status", "active");

    if (error) {
      console.error("Failed to load active draft listings", error);
      ACTIVE_DRAFT_PLAYERS = new Set();
      return;
    }

    ACTIVE_DRAFT_PLAYERS = new Set(
      (data || []).map(row => String(row.player_id).trim())
    );
  }

  document.querySelectorAll(".inc-btn, .dec-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      if (!CURRENT_OFFER_PLAYER) return;

      const inc = Number(btn.dataset.inc);
      const input = document.getElementById("offerAmount");

      let raw = input.value.replace(/,/g, "").trim();
      let val = Number(raw) || 0;

      val += inc;

      const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
      if (val < mv) val = mv;

      input.value = val.toLocaleString("en-GB");
    });
  });

  document.getElementById("quickBidBtn").onclick = () => {
    if (!CURRENT_OFFER_PLAYER) return;
    const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;
    document.getElementById("offerAmount").value = mv.toLocaleString("en-GB");
  };

  document.getElementById("offerAmount").addEventListener("input", e => {
    if (!CURRENT_OFFER_PLAYER) return;

    let raw = e.target.value.replace(/,/g, "").trim();
    let val = Number(raw);

    const mv = Number(CURRENT_OFFER_PLAYER.market_value) || 0;

    if (isNaN(val) || val <= 0) {
      val = mv;
    }

    if (val < mv) val = mv;

    e.target.value = val.toLocaleString("en-GB");
  });

  /* ============================================================
     MODULE H: Filters + Controls
     ============================================================ */

  function closeAllMultiFilters() {
    document.querySelectorAll(".multi-filter.open").forEach(el => {
      el.classList.remove("open");
    });
  }

  function updateMultiFilterDisplay(col) {
    const panel = document.getElementById(`filter-${col}-panel`);
    const display = document.getElementById(`filter-${col}-display`);
    if (!panel || !display) return;

    const checkboxes = panel.querySelectorAll("input[type='checkbox']");
    const selected = [];
    const labels = [];

    checkboxes.forEach(cb => {
      if (cb.checked) {
        selected.push(cb.value);
        labels.push(cb.getAttribute("data-label") || cb.value);
      }
    });

    CURRENT_FILTERS[col] = selected;

    if (selected.length === 0) {
      display.textContent = "All";
    } else if (selected.length === 1) {
      display.textContent = labels[0];
    } else {
      display.textContent = `${labels[0]} +${selected.length - 1}`;
    }

    loadPage(1);
  }

  async function populateDropdowns() {
    for (const col of DROPDOWN_COLUMNS) {
      const panel = document.getElementById(`filter-${col}-panel`);
      if (!panel) continue;

      let { data, error } = await supabase
        .from("Players")
        .select(col, { distinct: true });

      if (error || !data) {
        console.error(`Error loading distinct values for ${col}:`, error);
        continue;
      }

      let values = data
        .map(row => row[col])
        .filter(v => v !== null && v !== undefined);

      if (col === "Contracted_Team") {
        values = values.map(v => (v && String(v).trim() !== "" ? String(v).trim() : "FREE AGENT"));
      }

      let uniqueValues;

      if (col === "Season_Signed") {
        uniqueValues = [...new Set(values.map(v => Number(v)))]
          .filter(v => !isNaN(v))
          .sort((a, b) => a - b);
      } else if (col === "Age" || col === "Rating") {
        uniqueValues = [...new Set(values.map(v => Number(v)))]
          .filter(v => !isNaN(v))
          .sort((a, b) => a - b);
      } else if (col === "Position") {
        uniqueValues = [...new Set(values.map(v => String(v).trim()))]
          .filter(v => v !== "")
          .sort((a, b) => {
            const ai = POSITION_ORDER.indexOf(a);
            const bi = POSITION_ORDER.indexOf(b);
            const aIdx = ai === -1 ? 999 : ai;
            const bIdx = bi === -1 ? 999 : bi;
            return aIdx - bIdx;
          });
      } else {
        uniqueValues = [...new Set(values.map(v => String(v).trim()))]
          .filter(v => v !== "")
          .sort((a, b) => a.localeCompare(b));
      }

      if (col === "Contracted_Team") {
        uniqueValues = ["FREE AGENT", ...uniqueValues.filter(v => v !== "FREE AGENT")];
      }

      panel.innerHTML = "";

      uniqueValues.forEach(v => {
        const optionDiv = document.createElement("div");
        optionDiv.className = "multi-filter-option";

        const cb = document.createElement("input");
        cb.type = "checkbox";

        let value = v;
        let label = v;

        if (col === "Contracted_Team") {
          if (v === "FREE AGENT") {
            value = "FREE AGENT";
            label = "FREE AGENT";
          } else {
            value = v;
            label = CLUB_NAME_MAP[v] || v;
          }
        }

        cb.value = value;
        cb.setAttribute("data-label", label);

        cb.addEventListener("change", () => {
          updateMultiFilterDisplay(col);
        });

        const span = document.createElement("span");
        span.textContent = label;

        optionDiv.appendChild(cb);
        optionDiv.appendChild(span);
        panel.appendChild(optionDiv);
      });
    }
  }

  function setupFilters() {
    const filtersDiv = document.getElementById("filters");

    filtersDiv.innerHTML = COLUMNS
      .filter(col => !FILTER_EXCLUDE.includes(col))
      .map(col => {
        const label = col.replace(/_/g, " ");
        if (DROPDOWN_COLUMNS.includes(col)) {
          return `
            <div class="multi-filter" data-col="${col}">
              <div class="multi-filter-label">${label}</div>
              <div class="multi-filter-control" id="filter-${col}-display">All</div>
              <div class="multi-filter-panel" id="filter-${col}-panel"></div>
            </div>
          `;
        } else {
          return `
            <label class="text-filter">
              ${label}
              <input type="text" id="filter-${col}" placeholder="Filter ${label}">
            </label>
          `;
        }
      })
      .join("");
  }

  function setupControls() {
    const pageSizeSelect = document.getElementById("pageSizeSelect");
    pageSizeSelect.addEventListener("change", () => {
      PAGE_SIZE = Number(pageSizeSelect.value);
      loadPage(1);
    });

    const mvMinInput = document.getElementById("mv-min");
    const mvMaxInput = document.getElementById("mv-max");
    const applyMV = document.getElementById("applyMV");

    mvMinInput.style.width = "140px";
    mvMinInput.style.textAlign = "right";
    mvMaxInput.style.width = "140px";
    mvMaxInput.style.textAlign = "right";

    const parseMV = (val) => {
      const raw = val.replace(/[^\d]/g, "").trim();
      if (raw === "") return null;
      const num = Number(raw);
      return isNaN(num) ? null : num;
    };

    const formatMVInput = (inputEl) => {
      const raw = inputEl.value.replace(/[^\d]/g, "").trim();
      if (raw === "") {
        inputEl.value = "";
        return;
      }
      const num = Number(raw);
      if (!isNaN(num)) {
        inputEl.value = num.toLocaleString("en-GB");
      }
    };

    mvMinInput.addEventListener("input", () => formatMVInput(mvMinInput));
    mvMaxInput.addEventListener("input", () => formatMVInput(mvMaxInput));

    applyMV.addEventListener("click", () => {
      MV_MIN = parseMV(mvMinInput.value);
      MV_MAX = parseMV(mvMaxInput.value);
      loadPage(1);
    });

    document.getElementById("clearFiltersBtn").addEventListener("click", () => {
      CURRENT_FILTERS = {};
      MV_MIN = null;
      MV_MAX = null;
      CURRENT_SORT_COLUMN = "Rating";
      CURRENT_SORT_DIR = "desc";

      document
        .querySelectorAll("#filters input[type='text']")
        .forEach(i => (i.value = ""));

      document
        .querySelectorAll("#filters .multi-filter-panel input[type='checkbox']")
        .forEach(cb => (cb.checked = false));

      DROPDOWN_COLUMNS.forEach(col => {
        const display = document.getElementById(`filter-${col}-display`);
        if (display) display.textContent = "All";
      });

      mvMinInput.value = "";
      mvMaxInput.value = "";

      loadPage(1);
    });
  }

  /* ============================================================
     MODULE I: Pagination Rendering
     ============================================================ */

  function renderPagination() {
    const totalPages = Math.ceil(TOTAL_ROWS / PAGE_SIZE);
    const pagination = document.getElementById("pagination");

    pagination.innerHTML = "";

    for (let i = 1; i <= totalPages; i++) {
      const btn = document.createElement("button");
      btn.textContent = i;
      btn.className = "page-btn";
      if (i === CURRENT_PAGE) btn.classList.add("active");

      btn.onclick = () => loadPage(i);
      pagination.appendChild(btn);
    }
  }

  /* ============================================================
     MODULE J: Initialisation
     ============================================================ */

  async function init() {
    await loadUser();
    GLOBAL_SETTINGS = await loadGlobalSettings();
    draftAuctionStartTime = GLOBAL_SETTINGS.draftAuctionStartTime || null;
    draftRandomFinishTime = GLOBAL_SETTINGS.draftRandomFinishTime || null;

    await loadClubNames();

    setupControls();
    setupFilters();
    await populateDropdowns();
    await loadTotalCount();
    await loadActiveDraftListings();
    await loadDraftCreditsForOwner();
    loadPage(1);
  }

  init();

});
                      
