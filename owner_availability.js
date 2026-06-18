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

function populateTimezoneSelect(current) {
  const sel = document.getElementById("availTimezoneSelect");
  if (!sel) return;

  const zones = [
    "Europe/London",
    "Europe/Dublin",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Madrid",
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "Asia/Dubai",
    "Asia/Singapore",
    "Australia/Sydney",
  ];

  sel.innerHTML = zones
    .map(
      (z) =>
        `<option value="${z}"${z === current ? " selected" : ""}>${z.replace(/_/g, " ")}</option>`
    )
    .join("");

  sel.onchange = async () => {
    const status = document.getElementById("availStatus");
    const res = await setOwnerTimezone(sel.value);
    if (status) {
      status.textContent = res.ok ? "Timezone saved." : res.msg;
      status.style.color = res.ok ? "#8c8" : "#f88";
    }
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
    .avail-tz-row label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: #ccc; }
    .avail-tz-row select { max-width: 280px; padding: 6px 8px; background: #222; border: 1px solid #444; color: #ddd; border-radius: 4px; }
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
