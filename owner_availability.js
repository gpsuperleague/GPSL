/**
 * Owner weekly availability calendar (Club Details).
 */

import {
  ISO_DOW_LABELS,
  GRID_HOURS,
  slotKey,
  slotsFromKeys,
  loadAvailabilityContext,
  saveWeeklyAvailability,
  setOwnerTimezone,
  UK_TZ,
} from "./match_scheduling.js";
import { formatUkDateRange } from "./owner_holidays.js";

let modalEl = null;
let selectedKeys = new Set();
let context = null;

function ensureModal() {
  if (modalEl) return modalEl;

  modalEl = document.createElement("div");
  modalEl.id = "availabilityModal";
  modalEl.className = "avail-modal";
  modalEl.hidden = true;
  modalEl.innerHTML = `
    <div class="avail-modal-backdrop" data-close="1"></div>
    <div class="avail-modal-panel" role="dialog" aria-labelledby="availModalTitle">
      <div class="avail-modal-head">
        <h2 id="availModalTitle">Match availability</h2>
        <button type="button" class="avail-modal-close" data-close="1" aria-label="Close">×</button>
      </div>
      <p class="avail-modal-intro">
        Mark when you are generally free to play (30-minute blocks, UK time).
        Holidays booked below overlay as unavailable. Set your display timezone for proposals.
      </p>
      <div class="avail-tz-row">
        <label>Your timezone
          <select id="availTimezoneSelect"></select>
        </label>
        <button type="button" id="availDetectTzBtn" class="small-btn secondary">Use my device timezone</button>
      </div>
      <div class="avail-grid-toolbar">
        <button type="button" id="availMarkAllBtn" class="small-btn secondary">Mark all times available</button>
        <button type="button" id="availClearAllBtn" class="small-btn secondary">Clear all</button>
      </div>
      <div id="availGrid" class="avail-grid"></div>
      <p id="availSlotCount" class="avail-slot-count"></p>
      <div class="avail-modal-actions">
        <button type="button" id="availSaveBtn" class="small-btn">Save availability</button>
        <span id="availStatus" class="account-status" role="status"></span>
      </div>
      <div id="availHolidayOverlay" class="avail-holiday-note"></div>
    </div>
  `;
  document.body.appendChild(modalEl);

  modalEl.querySelectorAll("[data-close]").forEach((el) => {
    el.addEventListener("click", () => closeAvailabilityModal());
  });

  document.getElementById("availSaveBtn").addEventListener("click", onSave);
  document.getElementById("availMarkAllBtn").addEventListener("click", markAllAvailable);
  document.getElementById("availClearAllBtn").addEventListener("click", clearAllAvailable);

  return modalEl;
}

function allSlotKeys() {
  const keys = [];
  for (const hour of GRID_HOURS) {
    for (const minute of [0, 30]) {
      for (let isoDow = 1; isoDow <= 7; isoDow++) {
        keys.push(slotKey(isoDow, hour, minute));
      }
    }
  }
  return keys;
}

function nextIsoDow(isoDow) {
  return isoDow === 7 ? 1 : isoDow + 1;
}

function markAllAvailable() {
  for (const key of allSlotKeys()) {
    selectedKeys.add(key);
  }
  renderGrid();
}

function clearAllAvailable() {
  selectedKeys.clear();
  renderGrid();
}

function copyDayToNext(isoDow) {
  const next = nextIsoDow(isoDow);
  for (const hour of GRID_HOURS) {
    for (const minute of [0, 30]) {
      const srcKey = slotKey(isoDow, hour, minute);
      const dstKey = slotKey(next, hour, minute);
      if (selectedKeys.has(srcKey)) selectedKeys.add(dstKey);
      else selectedKeys.delete(dstKey);
    }
  }
  renderGrid();
}

/** Used only when the browser can't list IANA zones (Intl.supportedValuesOf). */
const FALLBACK_TIMEZONES = [
  "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin",
  "Europe/Madrid", "Europe/Rome", "Europe/Amsterdam", "Europe/Brussels", "Europe/Stockholm",
  "Europe/Oslo", "Europe/Copenhagen", "Europe/Warsaw", "Europe/Prague", "Europe/Vienna",
  "Europe/Zurich", "Europe/Budapest", "Europe/Belgrade", "Europe/Zagreb", "Europe/Athens",
  "Europe/Bucharest", "Europe/Sofia", "Europe/Helsinki", "Europe/Kiev", "Europe/Istanbul",
  "Europe/Moscow", "Atlantic/Reykjavik", "Atlantic/Azores", "Atlantic/Canary",
  "Africa/Casablanca", "Africa/Lagos", "Africa/Accra", "Africa/Abidjan", "Africa/Dakar",
  "Africa/Algiers", "Africa/Tunis", "Africa/Cairo", "Africa/Johannesburg", "Africa/Nairobi",
  "Africa/Addis_Ababa", "Africa/Kinshasa", "Africa/Luanda",
  "America/St_Johns", "America/Halifax", "America/New_York", "America/Toronto",
  "America/Chicago", "America/Mexico_City", "America/Denver", "America/Phoenix",
  "America/Los_Angeles", "America/Vancouver", "America/Anchorage", "Pacific/Honolulu",
  "America/Puerto_Rico", "America/Jamaica", "America/Panama", "America/Bogota",
  "America/Lima", "America/Caracas", "America/La_Paz", "America/Santiago",
  "America/Asuncion", "America/Montevideo", "America/Argentina/Buenos_Aires",
  "America/Sao_Paulo", "America/Guayaquil",
  "Asia/Jerusalem", "Asia/Beirut", "Asia/Amman", "Asia/Baghdad", "Asia/Riyadh",
  "Asia/Qatar", "Asia/Dubai", "Asia/Tehran", "Asia/Kabul", "Asia/Karachi",
  "Asia/Tashkent", "Asia/Kolkata", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Yangon",
  "Asia/Bangkok", "Asia/Jakarta", "Asia/Ho_Chi_Minh", "Asia/Kuala_Lumpur",
  "Asia/Singapore", "Asia/Manila", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Taipei",
  "Asia/Seoul", "Asia/Tokyo", "Indian/Maldives", "Indian/Mauritius",
  "Australia/Perth", "Australia/Darwin", "Australia/Adelaide", "Australia/Brisbane",
  "Australia/Sydney", "Australia/Melbourne", "Australia/Hobart",
  "Pacific/Guam", "Pacific/Port_Moresby", "Pacific/Noumea", "Pacific/Auckland",
  "Pacific/Fiji", "Pacific/Tongatapu", "Pacific/Apia", "Pacific/Kiritimati", "UTC",
];

const TZ_REGIONS = [
  ["Europe", "Europe"],
  ["Africa", "Africa"],
  ["America", "Americas"],
  ["Atlantic", "Atlantic"],
  ["Asia", "Asia & Middle East"],
  ["Indian", "Indian Ocean"],
  ["Australia", "Australia"],
  ["Pacific", "Pacific"],
];

function tzOffsetMinutes(timeZone, at = new Date()) {
  try {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    }).formatToParts(at);
    const get = (t) => Number(parts.find((p) => p.type === t)?.value);
    const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour") % 24, get("minute"));
    return Math.round((asUtc - Date.UTC(
      at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate(), at.getUTCHours(), at.getUTCMinutes()
    )) / 60000);
  } catch {
    return null;
  }
}

function formatUtcOffset(mins) {
  if (mins == null) return "UTC?";
  const sign = mins < 0 ? "−" : "+";
  const abs = Math.abs(mins);
  return `UTC${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
}

function worldTimezones() {
  let zones = [];
  try {
    if (typeof Intl.supportedValuesOf === "function") zones = Intl.supportedValuesOf("timeZone");
  } catch {
    zones = [];
  }
  if (!zones.length) zones = FALLBACK_TIMEZONES;
  return zones;
}

export function detectDeviceTimezone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
  } catch {
    return null;
  }
}

function timezoneOptionsHtml(current) {
  const zones = new Set(worldTimezones());
  if (current) zones.add(current);
  zones.add("Europe/London");

  const groups = new Map(TZ_REGIONS.map(([, label]) => [label, []]));
  groups.set("Other", []);
  for (const z of zones) {
    const prefix = z.split("/")[0];
    const region = TZ_REGIONS.find(([p]) => p === prefix)?.[1] || "Other";
    const offset = tzOffsetMinutes(z);
    const place = z.includes("/") ? z.split("/").slice(1).join(" / ") : z;
    groups.get(region).push({
      z,
      offset,
      label: `${place.replace(/_/g, " ")} (${formatUtcOffset(offset)})`,
    });
  }

  let html = "";
  for (const [label, items] of groups) {
    if (!items.length) continue;
    items.sort((a, b) => (a.offset ?? 0) - (b.offset ?? 0) || a.label.localeCompare(b.label));
    html += `<optgroup label="${label}">`;
    html += items
      .map(
        (it) =>
          `<option value="${it.z}"${it.z === current ? " selected" : ""}>${it.label}</option>`
      )
      .join("");
    html += `</optgroup>`;
  }
  return html;
}

function populateTimezoneSelect(current) {
  const sel = document.getElementById("availTimezoneSelect");
  if (!sel) return;

  sel.innerHTML = timezoneOptionsHtml(current || UK_TZ);
  wireDetectTimezoneButton(sel);

  sel.onchange = async () => {
    const status = document.getElementById("availStatus");
    const res = await setOwnerTimezone(sel.value);
    if (status) {
      status.textContent = res.ok ? "Timezone saved." : res.msg;
      status.style.color = res.ok ? "#8c8" : "#f88";
    }
  };
}

function wireDetectTimezoneButton(sel) {
  const btn = document.getElementById("availDetectTzBtn");
  if (!btn || !sel) return;
  const detected = detectDeviceTimezone();
  if (!detected) {
    btn.hidden = true;
    return;
  }
  btn.title = `Detected: ${detected.replace(/_/g, " ")} (${formatUtcOffset(tzOffsetMinutes(detected))})`;
  btn.onclick = () => {
    if (![...sel.options].some((o) => o.value === detected)) {
      sel.innerHTML = timezoneOptionsHtml(detected);
    }
    sel.value = detected;
    sel.dispatchEvent(new Event("change"));
  };
}

function renderGrid() {
  const grid = document.getElementById("availGrid");
  if (!grid) return;

  let html = '<div class="avail-grid-corner"></div>';
  for (let d = 1; d <= 7; d++) {
    const next = nextIsoDow(d);
    html += `<div class="avail-grid-dow">
      <span>${ISO_DOW_LABELS[d - 1]}</span>
      <button type="button" class="avail-copy-day" data-dow="${d}" title="Copy ${ISO_DOW_LABELS[d - 1]} to ${ISO_DOW_LABELS[next - 1]}">→ ${ISO_DOW_LABELS[next - 1]}</button>
    </div>`;
  }

  for (const hour of GRID_HOURS) {
    for (const minute of [0, 30]) {
      html += `<div class="avail-grid-time">${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}</div>`;
      for (let isoDow = 1; isoDow <= 7; isoDow++) {
        const key = slotKey(isoDow, hour, minute);
        const on = selectedKeys.has(key);
        html += `<button type="button" class="avail-cell${on ? " on" : ""}" data-key="${key}" title="${ISO_DOW_LABELS[isoDow - 1]} ${hour}:${String(minute).padStart(2, "0")}"></button>`;
      }
    }
  }

  grid.innerHTML = html;
  grid.querySelectorAll(".avail-copy-day").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      copyDayToNext(Number(btn.dataset.dow));
    });
  });
  grid.querySelectorAll(".avail-cell").forEach((btn) => {
    btn.addEventListener("click", () => {
      const key = btn.dataset.key;
      if (selectedKeys.has(key)) selectedKeys.delete(key);
      else selectedKeys.add(key);
      btn.classList.toggle("on", selectedKeys.has(key));
      updateSlotCount();
    });
  });
  updateSlotCount();
}

function updateSlotCount() {
  const el = document.getElementById("availSlotCount");
  if (el) {
    el.textContent = `${selectedKeys.size} block${selectedKeys.size === 1 ? "" : "s"} selected`;
  }
}

function renderHolidayNote() {
  const el = document.getElementById("availHolidayOverlay");
  if (!el || !context) return;

  const holidays = context.holidays || [];
  if (!holidays.length) {
    el.innerHTML =
      '<p class="avail-holiday-empty">No holidays booked — use Holiday booking below when you need time away.</p>';
    return;
  }

  el.innerHTML =
    "<h3>Holidays (unavailable)</h3><ul>" +
    holidays
      .map(
        (h) =>
          `<li>${formatUkDateRange(h.starts_at, h.ends_at)} (${h.day_count} day${h.day_count === 1 ? "" : "s"})</li>`
      )
      .join("") +
    "</ul>";
}

async function onSave() {
  const status = document.getElementById("availStatus");
  const btn = document.getElementById("availSaveBtn");
  if (btn) btn.disabled = true;

  const slots = slotsFromKeys([...selectedKeys]);
  const res = await saveWeeklyAvailability(slots);

  if (status) {
    status.textContent = res.ok ? "Availability saved." : res.msg;
    status.style.color = res.ok ? "#8c8" : "#f88";
  }
  if (btn) btn.disabled = false;
}

export async function openAvailabilityModal() {
  ensureModal();
  const status = document.getElementById("availStatus");
  if (status) status.textContent = "";

  try {
    context = await loadAvailabilityContext();
  } catch (err) {
    if (status) {
      status.textContent =
        err.message?.includes("club_availability_context")
          ? "Run supabase/sql/patches/match_scheduling_phase1.sql in Supabase."
          : err.message || "Could not load availability.";
      status.style.color = "#f88";
    }
    context = { weekly_slots: [], holidays: [], timezone: UK_TZ };
  }

  selectedKeys = new Set(
    (context.weekly_slots || []).map((s) => slotKey(s.iso_dow, s.hour, s.minute))
  );

  populateTimezoneSelect(context.timezone || UK_TZ);
  renderGrid();
  renderHolidayNote();

  modalEl.hidden = false;
  document.body.classList.add("avail-modal-open");
}

export function closeAvailabilityModal() {
  if (modalEl) {
    modalEl.hidden = true;
    document.body.classList.remove("avail-modal-open");
  }
}

export function injectAvailabilityStyles() {
  if (document.getElementById("avail-modal-styles")) return;
  const style = document.createElement("style");
  style.id = "avail-modal-styles";
  style.textContent = `
    .avail-modal { position: fixed; inset: 0; z-index: 9000; display: flex; align-items: center; justify-content: center; padding: 16px; }
    .avail-modal[hidden] { display: none !important; }
    .avail-modal-backdrop { position: absolute; inset: 0; background: rgba(0,0,0,.75); }
    .avail-modal-panel { position: relative; background: #1a1a1a; border: 1px solid #444; border-radius: 10px; max-width: 960px; width: 100%; max-height: 90vh; overflow: auto; padding: 18px 20px 24px; }
    .avail-modal-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
    .avail-modal-head h2 { color: #ff9900; margin: 0; font-size: 20px; }
    .avail-modal-close { background: none; border: none; color: #aaa; font-size: 28px; cursor: pointer; line-height: 1; }
    .avail-modal-intro { color: #aaa; font-size: 13px; line-height: 1.45; margin: 10px 0 14px; }
    .avail-tz-row { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 10px; }
    .avail-tz-row label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: #ccc; }
    .avail-tz-row select { max-width: 320px; padding: 6px 8px; background: #222; border: 1px solid #444; color: #ddd; border-radius: 4px; }
    .avail-grid-toolbar { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 4px; }
    .avail-grid-toolbar .secondary { background: #333; color: #ddd; border: 1px solid #555; }
    .avail-grid { display: grid; grid-template-columns: 52px repeat(7, 1fr); gap: 2px; margin: 14px 0 8px; user-select: none; }
    .avail-grid-corner { }
    .avail-grid-dow { display: flex; flex-direction: column; align-items: center; gap: 3px; font-size: 11px; color: #ff9900; font-weight: bold; padding: 4px 0; }
    .avail-copy-day {
      font-size: 9px; font-weight: normal; color: #888; background: none; border: 1px solid #444;
      border-radius: 3px; padding: 1px 4px; cursor: pointer; line-height: 1.3;
    }
    .avail-copy-day:hover { color: #ff9900; border-color: #666; }
    .avail-grid-time { font-size: 10px; color: #666; text-align: right; padding: 2px 4px 0 0; line-height: 28px; }
    .avail-cell { height: 28px; min-width: 0; border: 1px solid #333; background: #111; border-radius: 3px; cursor: pointer; padding: 0; }
    .avail-cell.on { background: #3d3200; border-color: #ff9900; }
    .avail-cell:hover { border-color: #666; }
    .avail-slot-count { font-size: 12px; color: #888; margin: 0 0 12px; }
    .avail-modal-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
    .avail-holiday-note { margin-top: 16px; border-top: 1px solid #333; padding-top: 12px; }
    .avail-holiday-note h3 { font-size: 14px; color: #ff9900; margin: 0 0 8px; }
    .avail-holiday-note ul { margin: 0; padding-left: 18px; color: #aaa; font-size: 13px; }
    .avail-holiday-empty { color: #666; font-size: 13px; margin: 0; }
    body.avail-modal-open { overflow: hidden; }
  `;
  document.head.appendChild(style);
}

export function wireAvailabilityPanel() {
  injectAvailabilityStyles();
  const btn = document.getElementById("editAvailabilityBtn");
  if (btn) {
    btn.addEventListener("click", () => openAvailabilityModal());
  }
}

/**
 * Inline availability editor (admin or embedded pages).
 * @param {HTMLElement} container
 * @param {{
 *   loadContext: () => Promise<object>,
 *   saveWeekly: (slots: object[]) => Promise<{ ok: boolean, msg?: string }>,
 *   setTimezone: (tz: string) => Promise<{ ok: boolean, msg?: string }>,
 *   showHolidays?: boolean,
 * }} options
 */
export async function mountAvailabilityPanel(container, options) {
  if (!container || !options?.loadContext || !options?.saveWeekly || !options?.setTimezone) {
    return;
  }

  injectAvailabilityStyles();

  container.innerHTML = `
    <p class="avail-modal-intro">
      Mark when this club is generally free to play (30-minute blocks, UK time).
      Holidays booked by the owner overlay as unavailable.
    </p>
    <div class="avail-tz-row">
      <label>Your timezone
        <select id="availTimezoneSelect"></select>
      </label>
      <button type="button" id="availDetectTzBtn" class="small-btn secondary">Use my device timezone</button>
    </div>
    <div class="avail-grid-toolbar">
      <button type="button" id="availMarkAllBtn" class="small-btn secondary">Mark all times available</button>
      <button type="button" id="availClearAllBtn" class="small-btn secondary">Clear all</button>
    </div>
    <div id="availGrid" class="avail-grid"></div>
    <p id="availSlotCount" class="avail-slot-count"></p>
    <div class="avail-modal-actions">
      <button type="button" id="availSaveBtn" class="small-btn">Save availability</button>
      <span id="availStatus" class="account-status" role="status"></span>
    </div>
    <div id="availHolidayOverlay" class="avail-holiday-note"></div>
  `;

  const statusEl = () => document.getElementById("availStatus");
  const saveBtn = document.getElementById("availSaveBtn");
  const markAllBtn = document.getElementById("availMarkAllBtn");
  const clearAllBtn = document.getElementById("availClearAllBtn");
  const holidayEl = document.getElementById("availHolidayOverlay");

  if (markAllBtn) markAllBtn.onclick = markAllAvailable;
  if (clearAllBtn) clearAllBtn.onclick = clearAllAvailable;

  if (saveBtn) {
    saveBtn.onclick = async () => {
      saveBtn.disabled = true;
      const slots = slotsFromKeys([...selectedKeys]);
      const res = await options.saveWeekly(slots);
      const status = statusEl();
      if (status) {
        status.textContent = res.ok ? "Availability saved." : res.msg;
        status.style.color = res.ok ? "#8c8" : "#f88";
      }
      saveBtn.disabled = false;
    };
  }

  if (holidayEl && options.showHolidays === false) {
    holidayEl.hidden = true;
  }

  try {
    context = await options.loadContext();
  } catch (err) {
    const status = statusEl();
    if (status) {
      status.textContent =
        err.message?.includes("admin_club_availability")
          ? "Run supabase/sql/patches/admin_club_availability.sql in Supabase."
          : err.message || "Could not load availability.";
      status.style.color = "#f88";
    }
    context = { weekly_slots: [], holidays: [], timezone: UK_TZ };
  }

  selectedKeys = new Set(
    (context.weekly_slots || []).map((s) => slotKey(s.iso_dow, s.hour, s.minute))
  );

  populateTimezoneSelect(context.timezone || UK_TZ);
  const tzSel = document.getElementById("availTimezoneSelect");
  if (tzSel) {
    tzSel.onchange = async () => {
      const res = await options.setTimezone(tzSel.value);
      const status = statusEl();
      if (status) {
        status.textContent = res.ok ? "Timezone saved." : res.msg;
        status.style.color = res.ok ? "#8c8" : "#f88";
      }
    };
  }
  renderGrid();
  if (options.showHolidays !== false) renderHolidayNote();
}
