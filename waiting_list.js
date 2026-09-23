import { supabase } from "./supabase_client.js";
import { initGlobal } from "./global.js";
import {
  loadOwnerSupporterMap,
  ownerTagHtml,
} from "./owner_badge.js";

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

/** Representative IANA zone when we only know the country (multi-zone countries use a primary). */
function timezoneForCountry(countryCode) {
  const cc = String(countryCode || "").trim().toUpperCase();
  if (!cc) return "";
  const map = {
    GB: "Europe/London",
    UK: "Europe/London",
    IE: "Europe/Dublin",
    PT: "Europe/Lisbon",
    ES: "Europe/Madrid",
    FR: "Europe/Paris",
    BE: "Europe/Brussels",
    NL: "Europe/Amsterdam",
    LU: "Europe/Luxembourg",
    DE: "Europe/Berlin",
    AT: "Europe/Vienna",
    CH: "Europe/Zurich",
    IT: "Europe/Rome",
    MT: "Europe/Malta",
    PL: "Europe/Warsaw",
    CZ: "Europe/Prague",
    SK: "Europe/Bratislava",
    HU: "Europe/Budapest",
    RO: "Europe/Bucharest",
    BG: "Europe/Sofia",
    GR: "Europe/Athens",
    CY: "Asia/Nicosia",
    HR: "Europe/Zagreb",
    SI: "Europe/Ljubljana",
    RS: "Europe/Belgrade",
    BA: "Europe/Sarajevo",
    MK: "Europe/Skopje",
    AL: "Europe/Tirane",
    XK: "Europe/Belgrade",
    ME: "Europe/Podgorica",
    TR: "Europe/Istanbul",
    UA: "Europe/Kyiv",
    BY: "Europe/Minsk",
    RU: "Europe/Moscow",
    NO: "Europe/Oslo",
    SE: "Europe/Stockholm",
    FI: "Europe/Helsinki",
    DK: "Europe/Copenhagen",
    IS: "Atlantic/Reykjavik",
    EE: "Europe/Tallinn",
    LV: "Europe/Riga",
    LT: "Europe/Vilnius",
    US: "America/New_York",
    CA: "America/Toronto",
    MX: "America/Mexico_City",
    BR: "America/Sao_Paulo",
    AR: "America/Argentina/Buenos_Aires",
    CL: "America/Santiago",
    CO: "America/Bogota",
    PE: "America/Lima",
    VE: "America/Caracas",
    UY: "America/Montevideo",
    AU: "Australia/Sydney",
    NZ: "Pacific/Auckland",
    JP: "Asia/Tokyo",
    KR: "Asia/Seoul",
    CN: "Asia/Shanghai",
    HK: "Asia/Hong_Kong",
    TW: "Asia/Taipei",
    SG: "Asia/Singapore",
    MY: "Asia/Kuala_Lumpur",
    TH: "Asia/Bangkok",
    VN: "Asia/Ho_Chi_Minh",
    ID: "Asia/Jakarta",
    PH: "Asia/Manila",
    IN: "Asia/Kolkata",
    PK: "Asia/Karachi",
    BD: "Asia/Dhaka",
    AE: "Asia/Dubai",
    SA: "Asia/Riyadh",
    QA: "Asia/Qatar",
    KW: "Asia/Kuwait",
    IL: "Asia/Jerusalem",
    EG: "Africa/Cairo",
    ZA: "Africa/Johannesburg",
    NG: "Africa/Lagos",
    KE: "Africa/Nairobi",
    MA: "Africa/Casablanca",
    GH: "Africa/Accra",
  };
  return map[cc] || "";
}

function resolveDisplayTimezone(row) {
  const saved = String(row?.origin_timezone || "").trim();
  if (saved) return { timeZone: saved, approx: false };
  const fromCountry = timezoneForCountry(row?.country_code);
  if (fromCountry) return { timeZone: fromCountry, approx: true };
  return { timeZone: "", approx: false };
}

function formatUkOffsetDelta(timeZone, { approx = false } = {}) {
  const target = timezoneOffsetMinutes(timeZone);
  const uk = timezoneOffsetMinutes("Europe/London");
  if (target == null || uk == null) return { text: "—", title: "" };
  const delta = target - uk;
  if (delta === 0) {
    return {
      text: approx ? "~Same" : "Same",
      title: approx
        ? `${timeZone} (from country) · same as UK`
        : `${timeZone} · same as UK`,
    };
  }
  const hours = Math.abs(delta) / 60;
  const label = Number.isInteger(hours) ? String(hours) : hours.toFixed(1).replace(/\.0$/, "");
  const signed = `${delta > 0 ? "+" : "-"}${label}h`;
  return {
    text: approx ? `~${signed}` : signed,
    title: approx
      ? `${timeZone} (approx from country) · ${signed} vs UK`
      : `${timeZone} · ${signed} vs UK`,
  };
}

function renderTagRows(tbody, rows, highlightPosition, { sectioned = false } = {}) {
  tbody.innerHTML = "";
  let lastKind = null;
  for (const row of rows) {
    const kind = row.list_kind || (row.has_club ? "club_owner" : "waiting");
    if (sectioned && kind !== lastKind) {
      lastKind = kind;
      const section = document.createElement("tr");
      section.className = "wl-section";
      const label =
        kind === "club_owner"
          ? "Current owners"
          : "Waiting list";
      section.innerHTML = `<td colspan="4">${escapeHtml(label)}</td>`;
      tbody.appendChild(section);
    }
    const tr = document.createElement("tr");
    if (highlightPosition && row.position === highlightPosition) {
      tr.className = "wl-you";
    }
    const statusParts = [];
    if (row.status === "on_absence") {
      statusParts.push('<span class="wl-status-absence">(absence)</span>');
    } else if (kind === "club_owner") {
      statusParts.push('<span class="wl-status-owner">(owner)</span>');
    }
    if (row.season1_rejected) {
      statusParts.push('<span class="wl-status-rejected">(rejected Season 1)</span>');
    }
    const statusExtra = statusParts.length ? ` ${statusParts.join(" ")}` : "";
    const countryCode = String(row.country_code || "").trim().toUpperCase();
    const countryName = formatCountryName(countryCode);
    const resolved = resolveDisplayTimezone(row);
    const tzDelta = formatUkOffsetDelta(resolved.timeZone, { approx: resolved.approx });
    const tagHtml = ownerTagHtml({
      ownerId: row.owner_id,
      ownerTag: row.owner_tag || "—",
      link: !!row.owner_id,
      compact: true,
      showBadgeImage: false,
    });
    const posLabel =
      row.queue_num != null && row.queue_num !== ""
        ? `S1#${row.queue_num}`
        : row.position;
    tr.innerHTML =
      `<td>${posLabel}</td>` +
      `<td>${tagHtml}${statusExtra}</td>` +
      `<td title="${countryCode ? escapeHtml(countryCode) : ""}">${countryName ? escapeHtml(countryName) : `<span style="color:#666">—</span>`}</td>` +
      `<td title="${tzDelta.title ? escapeHtml(tzDelta.title) : ""}">${escapeHtml(tzDelta.text)}</td>`;
    tbody.appendChild(tr);
  }
}

export async function initWaitingListPage() {
  window.CURRENT_PAGE = "waiting_list";
  await initGlobal();
  await loadOwnerSupporterMap().catch(() => {});

  const body = document.getElementById("wlBody");
  const onBoardBody = document.getElementById("wlOnBoardBody");
  const season1ConfirmedBody = document.getElementById("wlSeason1ConfirmedBody");
  const myCard = document.getElementById("wlMyCard");
  const myPos = document.getElementById("wlMyPos");
  const mySummary = document.getElementById("wlMySummary");
  const onBoardIntro = document.getElementById("wlOnBoardIntro");
  const onBoardCount = document.getElementById("wlOnBoardCount");
  const waitingCount = document.getElementById("wlWaitingCount");
  const season1ConfirmedCount = document.getElementById("wlSeason1ConfirmedCount");

  // After initGlobal's wireDraftCountdownUI has painted the first tick.
  syncAuctionCountdownCard();
  // One more frame in case the first countdown tick is still settling.
  requestAnimationFrame(() => syncAuctionCountdownCard());

  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");
    const list = await loadWaitingListPublic();
    const rows = list?.rows || [];
    const onBoard = list?.on_board || [];
    const season1Confirmed = list?.season1_confirmed || [];
    const highlightWaiting =
      self?.is_member && list?.my_position ? list.my_position : null;
    const highlightOnBoard = list?.my_on_board_position || null;
    const highlightSeason1 = list?.my_season1_confirmed_position || null;

    if (onBoardIntro) {
      onBoardIntro.textContent =
        "Owners invited to join the club auction, in invite order.";
    }
    if (season1ConfirmedCount) {
      season1ConfirmedCount.textContent = `(${
        list?.season1_confirmed_total ?? season1Confirmed.length
      })`;
    }
    if (onBoardCount) {
      onBoardCount.textContent = `(${list?.on_board_total ?? onBoard.length})`;
    }
    if (waitingCount) {
      waitingCount.textContent = `(${list?.total ?? rows.length})`;
    }

    if (season1ConfirmedBody) {
      if (!season1Confirmed.length) {
        season1ConfirmedBody.innerHTML =
          '<tr><td colspan="4" style="color:#666">No one confirmed for Season 1 yet.</td></tr>';
      } else {
        renderTagRows(season1ConfirmedBody, season1Confirmed, highlightSeason1);
      }
    }

    if (onBoardBody) {
      if (!onBoard.length) {
        onBoardBody.innerHTML =
          '<tr><td colspan="4" style="color:#666">No one invited yet — admin ticks Auction on the waiting list.</td></tr>';
      } else {
        renderTagRows(onBoardBody, onBoard, highlightOnBoard);
      }
    }

    if (!rows.length) {
      body.innerHTML =
        '<tr><td colspan="4" style="color:#666">No one on the waiting list.</td></tr>';
    } else {
      renderTagRows(body, rows, highlightWaiting, { sectioned: true });
    }

    if (
      self?.is_member &&
      (list?.my_season1_confirmed_position ||
        list?.my_on_board_position ||
        list?.my_position)
    ) {
      myCard.hidden = false;
      if (list.my_season1_confirmed_position) {
        myPos.textContent = `#${list.my_season1_confirmed_position} of ${
          list.season1_confirmed_total || season1Confirmed.length
        } confirmed`;
        mySummary.textContent = "You are confirmed for Season 1.";
      } else if (list.my_on_board_position) {
        myPos.textContent = `#${list.my_on_board_position} of ${list.on_board_total || onBoard.length} invited`;
        mySummary.textContent = "You are invited to the club auction.";
      } else {
        const me = rows.find((r) => r.position === list.my_position);
        const isOwner = me?.list_kind === "club_owner" || !!me?.has_club;
        myPos.textContent = `#${list.my_position} of ${list.total || rows.length} on the board`;
        if (me?.season1_rejected) {
          mySummary.textContent =
            "You declined Season 1 and are listed at the bottom of the waiting list.";
        } else {
          mySummary.textContent = isOwner
            ? "You are a current club owner on the season board."
            : list.my_position === 1
              ? "You are next in line when a club slot opens."
              : `${list.my_position - 1} member(s) ahead of you.`;
        }
        // Soft reminder: interest + backup required before auction
        if (!isOwner && !me?.season1_rejected) {
          mySummary.innerHTML +=
            ' Also mark <a href="club_database.html" style="color:#e8c84a;">1 interest + 1 backup</a> on Club Database before you are invited.';
        }
      }
    }

    // Season 1 invite respond card (waiting-list room)
    try {
      const { data: s1 } = await supabase.rpc("owner_season1_invite_get_mine");
      let s1Card = document.getElementById("wlSeason1Card");
      if (s1?.has_invite) {
        if (!s1Card) {
          s1Card = document.createElement("div");
          s1Card.id = "wlSeason1Card";
          s1Card.className = "wl-card";
          s1Card.innerHTML = `
            <h1 id="season1">Season 1 invite</h1>
            <p id="wlSeason1Summary"></p>
            <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:10px">
              <button type="button" class="button" id="wlSeason1Accept">Accept</button>
              <button type="button" class="button" id="wlSeason1Decline" style="background:#844">Decline</button>
            </div>
            <p id="wlSeason1Status" style="color:#fc6;margin-top:10px"></p>`;
          const wrap = document.querySelector(".wl-wrap");
          const my = document.getElementById("wlMyCard");
          if (wrap) wrap.insertBefore(s1Card, my?.nextSibling || wrap.firstChild);
        }
        s1Card.hidden = false;
        const sum = document.getElementById("wlSeason1Summary");
        const st = document.getElementById("wlSeason1Status");
        const s1info = s1.season1 || {};
        if (sum) {
          sum.textContent = `You are invited to Season 1 (queue #${
            s1info.queue_num ?? "—"
          }). Deadline: ${s1info.deadline_label || "48 hours from offer"}.`;
        }
        const accept = document.getElementById("wlSeason1Accept");
        const decline = document.getElementById("wlSeason1Decline");
        const respond = async (decision) => {
          if (decision === "decline" && !confirm("Decline your Season 1 invite?")) {
            return;
          }
          if (accept) accept.disabled = true;
          if (decline) decline.disabled = true;
          if (st) st.textContent = decision === "accept" ? "Accepting…" : "Declining…";
          const { error } = await supabase.rpc("owner_season1_invite_respond", {
            p_decision: decision,
          });
          if (error) {
            if (st) st.textContent = "❌ " + error.message;
            if (accept) accept.disabled = false;
            if (decline) decline.disabled = false;
            return;
          }
          if (st) {
            st.textContent =
              decision === "accept" ? "✅ Accepted for Season 1." : "Declined.";
          }
          if (accept) accept.hidden = true;
          if (decline) decline.hidden = true;
        };
        if (accept) accept.onclick = () => respond("accept");
        if (decline) decline.onclick = () => respond("decline");
      } else if (s1Card) {
        s1Card.hidden = true;
      }
    } catch (e) {
      console.warn("season1 invite card", e);
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
