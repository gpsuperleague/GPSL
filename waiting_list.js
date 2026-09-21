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
    const statusExtra =
      row.status === "on_absence"
        ? ' <span class="wl-status-absence">(absence)</span>'
        : kind === "club_owner"
          ? ' <span class="wl-status-owner">(owner)</span>'
          : "";
    const countryCode = String(row.country_code || "").trim().toUpperCase();
    const countryName = formatCountryName(countryCode);
    const resolved = resolveDisplayTimezone(row);
    const tzDelta = formatUkOffsetDelta(resolved.timeZone, { approx: resolved.approx });
    tr.innerHTML =
      `<td>${row.position}</td>` +
      `<td>${escapeHtml(row.owner_tag || "—")}${statusExtra}</td>` +
      `<td title="${countryCode ? escapeHtml(countryCode) : ""}">${countryName ? escapeHtml(countryName) : `<span style="color:#666">—</span>`}</td>` +
      `<td title="${tzDelta.title ? escapeHtml(tzDelta.title) : ""}">${escapeHtml(tzDelta.text)}</td>`;
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
        "Owners invited to join the club auction, in invite order.";
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

    if (self?.is_member && (list?.my_on_board_position || list?.my_position)) {
      myCard.hidden = false;
      if (list.my_on_board_position) {
        myPos.textContent = `#${list.my_on_board_position} of ${list.on_board_total || onBoard.length} invited`;
        mySummary.textContent =
          "You are invited to the club auction (I'm on board).";
      } else {
        const me = rows.find((r) => r.position === list.my_position);
        const isOwner = me?.list_kind === "club_owner" || !!me?.has_club;
        myPos.textContent = `#${list.my_position} of ${list.total || rows.length} on the board`;
        mySummary.textContent = isOwner
          ? "You are a current club owner on the season board."
          : list.my_position === 1
            ? "You are next in line when a club slot opens."
            : `${list.my_position - 1} member(s) ahead of you.`;
        // Soft reminder: interest + backup required before auction
        if (!isOwner) {
          mySummary.innerHTML +=
            ' Also mark <a href="club_database.html" style="color:#e8c84a;">1 interest + 1 backup</a> on Club Database before you are invited.';
        }
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
