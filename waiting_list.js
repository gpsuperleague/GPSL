import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";

export async function loadWaitingListPublic() {
  const { data, error } = await supabase.rpc("waiting_list_public");
  if (error) throw error;
  return data;
}

/**
 * Show/hide the club-auction card from the same DOM state wireDraftCountdownUI set.
 * Do not call isPageDraftCountdownActive() from a second global.js instance
 * (HTML ?v= query vs bare import) — that hid the card while the timer still ticked.
 */
function syncAuctionCountdownCard() {
  const card = document.getElementById("wlAuctionCountdownCard");
  const container = document.getElementById("draftCountdownContainer");
  if (!card) return;

  // wireDraftCountdownUI sets container display "" when active, "none" when not.
  // First tick is async — do not require #draftCountdown text yet.
  card.hidden = !container || container.style.display === "none";
}

function formatCountryName(code) {
  const cc = String(code || "").trim().toUpperCase();
  if (!cc) return "";
  try {
    const names = new Intl.DisplayNames(["en"], { type: "region" });
    return names.of(cc) || cc;
  } catch {
    return cc;
  }
}

function timezoneOffsetMinutes(timeZone) {
  const tz = String(timeZone || "").trim();
  if (!tz) return null;
  try {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: tz,
      timeZoneName: "shortOffset",
      hour: "2-digit",
      minute: "2-digit",
    }).formatToParts(new Date());
    const label = parts.find((p) => p.type === "timeZoneName")?.value || "GMT";
    const m = label.match(/GMT(?:(\+|-)(\d{1,2})(?::?(\d{2}))?)?$/i);
    if (!m) return 0;
    if (!m[1]) return 0;
    const sign = m[1] === "-" ? -1 : 1;
    return sign * (Number(m[2] || 0) * 60 + Number(m[3] || 0));
  } catch {
    return null;
  }
}

function formatUkOffsetDelta(timeZone) {
  const target = timezoneOffsetMinutes(timeZone);
  const uk = timezoneOffsetMinutes("Europe/London");
  if (target == null || uk == null) return "—";
  const delta = target - uk;
  if (delta === 0) return "Same";
  const hours = Math.abs(delta) / 60;
  const label = Number.isInteger(hours) ? String(hours) : hours.toFixed(1).replace(/\.0$/, "");
  return `${delta > 0 ? "+" : "-"}${label}h`;
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
    const countryCode = String(row.country_code || "").trim().toUpperCase();
    const countryName = formatCountryName(countryCode);
    const tzDelta = formatUkOffsetDelta(row.owner_timezone || "");
    tr.innerHTML =
      `<td>${row.position}</td>` +
      `<td>${escapeHtml(row.owner_tag || "—")}${statusExtra}</td>` +
      `<td title="${countryCode ? escapeHtml(countryCode) : ""}">${countryName ? escapeHtml(countryName) : `<span style="color:#666">—</span>`}</td>` +
      `<td>${escapeHtml(tzDelta)}</td>`;
    tbody.appendChild(tr);
  }
}

export async function initWaitingListPage() {
  window.CURRENT_PAGE = "waiting_list";
  await initGlobal();

  const body = document.getElementById("wlBody");
  const onBoardBody = document.getElementById("wlOnBoardBody");
  const myCard = document.getElementById("wlMyCard");
  const myPos = document.getElementById("wlMyPos");
  const mySummary = document.getElementById("wlMySummary");
  const onBoardIntro = document.getElementById("wlOnBoardIntro");
  const onBoardCount = document.getElementById("wlOnBoardCount");
  const waitingCount = document.getElementById("wlWaitingCount");

  // After initGlobal's wireDraftCountdownUI has painted the first tick.
  syncAuctionCountdownCard();
  // One more frame in case the first countdown tick is still settling.
  requestAnimationFrame(() => syncAuctionCountdownCard());

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
          '<tr><td colspan="4" style="color:#666">No one confirmed yet — admin ticks Test on the waiting list.</td></tr>';
      } else {
        renderTagRows(onBoardBody, onBoard, highlightOnBoard);
      }
    }

    if (!rows.length) {
      body.innerHTML =
        '<tr><td colspan="4" style="color:#666">No one on the waiting list.</td></tr>';
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

    syncAuctionCountdownCard();
  } catch (err) {
    console.error(err);
    const msg =
      err?.message && /on_board|confirmed_.*_at/i.test(String(err.message))
        ? "Could not load waiting list — run gpsl_waiting_list_on_board_public.sql in Supabase."
        : "Could not load waiting list.";
    body.innerHTML = `<tr><td colspan="4" style="color:#c66">${msg}</td></tr>`;
    if (onBoardBody) {
      onBoardBody.innerHTML = `<tr><td colspan="4" style="color:#c66">${msg}</td></tr>`;
    }
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
