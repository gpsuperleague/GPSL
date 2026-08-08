import { supabase } from "./supabase_client.js";
import { isPageDraftCountdownActive } from "./global.js";

export async function loadWaitingListPublic() {
  const { data, error } = await supabase.rpc("waiting_list_public");
  if (error) throw error;
  return data;
}

function syncAuctionCountdownCard() {
  const card = document.getElementById("wlAuctionCountdownCard");
  if (!card) return;
  // Same #draftCountdown wiring as awaiting_club / club_auction — hide the card when no schedule.
  card.hidden = !isPageDraftCountdownActive();
}

function renderTagRows(tbody, rows, highlightPosition) {
  tbody.innerHTML = "";
  for (const row of rows) {
    const tr = document.createElement("tr");
    if (highlightPosition && row.position === highlightPosition) {
      tr.className = "wl-you";
    }
    const statusExtra =
      row.status === "on_absence"
        ? ' <span class="wl-status-absence">(absence)</span>'
        : "";
    tr.innerHTML =
      `<td>${row.position}</td>` +
      `<td>${escapeHtml(row.owner_tag || "—")}${statusExtra}</td>`;
    tbody.appendChild(tr);
  }
}

export async function initWaitingListPage() {
  const body = document.getElementById("wlBody");
  const onBoardBody = document.getElementById("wlOnBoardBody");
  const myCard = document.getElementById("wlMyCard");
  const myPos = document.getElementById("wlMyPos");
  const mySummary = document.getElementById("wlMySummary");
  const onBoardIntro = document.getElementById("wlOnBoardIntro");
  const onBoardCount = document.getElementById("wlOnBoardCount");
  const waitingCount = document.getElementById("wlWaitingCount");

  syncAuctionCountdownCard();

  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");
    const list = await loadWaitingListPublic();
    const rows = list?.rows || [];
    const onBoard = list?.on_board || [];
    const highlightWaiting =
      self?.is_member && list?.my_position ? list.my_position : null;
    const highlightOnBoard = list?.my_on_board_position || null;

    if (onBoardIntro) {
      onBoardIntro.textContent =
        "Owners confirmed for the test season, in the order they joined.";
    }
    if (onBoardCount) {
      onBoardCount.textContent = `(${list?.on_board_total ?? onBoard.length})`;
    }
    if (waitingCount) {
      waitingCount.textContent = `(${list?.total ?? rows.length})`;
    }

    if (onBoardBody) {
      if (!onBoard.length) {
        onBoardBody.innerHTML =
          '<tr><td colspan="2" style="color:#666">No one confirmed yet — admin ticks Test on the waiting list.</td></tr>';
      } else {
        renderTagRows(onBoardBody, onBoard, highlightOnBoard);
      }
    }

    if (!rows.length) {
      body.innerHTML =
        '<tr><td colspan="2" style="color:#666">No one on the waiting list.</td></tr>';
    } else {
      renderTagRows(body, rows, highlightWaiting);
    }

    if (self?.is_member && (list?.my_on_board_position || list?.my_position)) {
      myCard.hidden = false;
      if (list.my_on_board_position) {
        myPos.textContent = `#${list.my_on_board_position} of ${list.on_board_total || onBoard.length} on board`;
        mySummary.textContent =
          "You are confirmed for the test season (I'm on board).";
      } else {
        myPos.textContent = `#${list.my_position} of ${list.total || rows.length} on the waiting list`;
        mySummary.textContent =
          list.my_position === 1
            ? "You are next in line when a club slot opens."
            : `${list.my_position - 1} member(s) ahead of you.`;
      }
    }
  } catch (err) {
    console.error(err);
    const msg =
      err?.message && /on_board|confirmed_.*_at/i.test(String(err.message))
        ? "Could not load waiting list — run gpsl_waiting_list_on_board_public.sql in Supabase."
        : "Could not load waiting list.";
    body.innerHTML = `<tr><td colspan="2" style="color:#c66">${msg}</td></tr>`;
    if (onBoardBody) {
      onBoardBody.innerHTML = `<tr><td colspan="2" style="color:#c66">${msg}</td></tr>`;
    }
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
