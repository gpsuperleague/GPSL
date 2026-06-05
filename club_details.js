// Club Details page

import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  loadCurrentSeason,
  loadActiveSeasonRegistrations,
  divisionForClub,
} from "./competition.js";
import {
  HOLIDAY_DAYS_PER_SEASON,
  loadOwnerHolidays,
  bookOwnerHoliday,
  cancelOwnerHoliday,
  formatUkDateRange,
  holidayStatusLabel,
  inclusiveDayCountFromDates,
} from "./owner_holidays.js";

const MAX_OWNER_TAG_LEN = 64;

const CLUB_SELECT_BASE =
  "ShortName, Club, Stadium, Capacity, Nation";
const CLUB_SELECT_WITH_OWNER = `${CLUB_SELECT_BASE}, owner`;

function formatNationLabel(value) {
  if (value == null || !String(value).trim()) return "";
  const spaced = String(value)
    .trim()
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return spaced
    .split(" ")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(" ");
}

export function normalizeOwnerTagInput(raw) {
  return String(raw ?? "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, MAX_OWNER_TAG_LEN);
}

function setBtnVisible(btn, visible) {
  if (!btn) return;
  btn.classList.toggle("is-hidden", !visible);
}

export function setOwnerTagMode(els, mode) {
  const { input, editBtn, saveBtn, hint } = els;

  if (mode === "empty") {
    input.disabled = false;
    input.placeholder = "Discord username";
    setBtnVisible(editBtn, false);
    setBtnVisible(saveBtn, true);
    hint.textContent =
      "Matches your Discord name. Save to lock it in — use Edit later to change.";
    hint.classList.remove("owner-tag-hint--error");
    return;
  }

  if (mode === "locked") {
    input.disabled = true;
    setBtnVisible(editBtn, true);
    setBtnVisible(saveBtn, false);
    hint.textContent = "Locked in. Click Edit to change, then Save.";
    hint.classList.remove("owner-tag-hint--error");
    return;
  }

  if (mode === "editing") {
    input.disabled = false;
    setBtnVisible(editBtn, false);
    setBtnVisible(saveBtn, true);
    hint.textContent = "Save to confirm your updated Discord tag.";
    hint.classList.remove("owner-tag-hint--error");
  }
}

export function initOwnerTagField(els, storedTag) {
  const locked = Boolean(storedTag && String(storedTag).trim());
  els.input.value = locked ? String(storedTag).trim() : "";
  setOwnerTagMode(els, locked ? "locked" : "empty");
}

export async function saveOwnerTag(tag) {
  const value = normalizeOwnerTagInput(tag);
  if (!value) {
    return { ok: false, msg: "Enter your Discord tag before saving." };
  }

  const { error } = await supabase.rpc("club_owner_set_tag", { p_tag: value });
  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("club_owner_set_tag") || msg.includes("function")) {
      return {
        ok: false,
        msg: "Could not save tag. Run supabase/sql/club_owner_tag.sql in Supabase.",
      };
    }
    return { ok: false, msg: msg || "Could not save owner tag." };
  }

  return { ok: true, tag: value };
}

function wireOwnerTagField(els, onSaved) {
  els.editBtn.addEventListener("click", () => {
    setOwnerTagMode(els, "editing");
    els.input.focus();
    els.input.select();
  });

  els.saveBtn.addEventListener("click", async () => {
    els.saveBtn.disabled = true;
    const result = await saveOwnerTag(els.input.value);
    els.saveBtn.disabled = false;

    if (!result.ok) {
      els.hint.textContent = result.msg;
      els.hint.classList.add("owner-tag-hint--error");
      return;
    }

    els.input.value = result.tag;
    setOwnerTagMode(els, "locked");
    onSaved?.(result.tag);
  });
}

async function loadOwnerClub(userId) {
  return supabase
    .from("Clubs")
    .select(CLUB_SELECT_WITH_OWNER)
    .eq("owner_id", userId)
    .maybeSingle();
}

function showLoadError(message) {
  const el = document.getElementById("clubDetailsError");
  if (el) {
    el.textContent = message;
    el.hidden = false;
  }
}

function setHolidayHint(message, isError = false) {
  const el = document.getElementById("holidayHint");
  if (!el) return;
  el.textContent = message || "";
  el.classList.toggle("owner-tag-hint--error", isError);
}

function renderHolidayList(holidays) {
  const list = document.getElementById("holidayList");
  if (!list) return;

  if (!holidays.length) {
    list.innerHTML =
      '<p class="holiday-empty">No holidays booked this season.</p>';
    return;
  }

  list.innerHTML = holidays
    .map((h) => {
      const status = holidayStatusLabel(h);
      const statusClass =
        status === "Active" ? "holiday-status holiday-status--active" : "holiday-status";
      const cancelBtn = h.is_upcoming
        ? `<button type="button" class="small-btn holiday-cancel-btn" data-id="${h.id}">Cancel</button>`
        : "";
      return `
        <div class="holiday-item">
          <div class="holiday-item-dates">
            <b>${formatUkDateRange(h.starts_at, h.ends_at)}</b>
            <span class="holiday-item-meta"> · ${h.day_count} day${h.day_count === 1 ? "" : "s"}</span>
          </div>
          <span class="${statusClass}">${status}</span>
          ${cancelBtn}
        </div>
      `;
    })
    .join("");

  list.querySelectorAll(".holiday-cancel-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.dataset.id);
      btn.disabled = true;
      const result = await cancelOwnerHoliday(id);
      btn.disabled = false;
      if (!result.ok) {
        setHolidayHint(result.msg, true);
        return;
      }
      setHolidayHint("Holiday cancelled.");
      await refreshHolidaySection();
    });
  });
}

function updateHolidayDayPreview() {
  const start = document.getElementById("holidayStartDate")?.value;
  const end = document.getElementById("holidayEndDate")?.value;
  const preview = document.getElementById("holidayDayPreview");
  if (!preview) return;

  if (!start || !end) {
    preview.textContent = "";
    return;
  }

  const days = inclusiveDayCountFromDates(start, end);
  if (days <= 0) {
    preview.textContent = "End date must be on or after start.";
    return;
  }

  preview.textContent = `${days} day${days === 1 ? "" : "s"} in this booking`;
}

async function refreshHolidaySection() {
  const quotaEl = document.getElementById("holidayQuota");
  const season = await loadCurrentSeason(supabase);

  if (!season) {
    if (quotaEl) quotaEl.textContent = "No active season — holidays unavailable.";
    renderHolidayList([]);
    return;
  }

  const { holidays, daysUsed, daysRemaining } = await loadOwnerHolidays();
  if (quotaEl) {
    quotaEl.textContent = `${daysUsed} of ${HOLIDAY_DAYS_PER_SEASON} days used this season · ${daysRemaining} remaining`;
  }
  renderHolidayList(holidays);
}

function wireHolidayBooking() {
  const startInput = document.getElementById("holidayStartDate");
  const endInput = document.getElementById("holidayEndDate");
  const bookBtn = document.getElementById("bookHolidayBtn");

  const onDateChange = () => updateHolidayDayPreview();
  startInput?.addEventListener("change", onDateChange);
  endInput?.addEventListener("change", onDateChange);

  bookBtn?.addEventListener("click", async () => {
    const start = startInput?.value;
    const end = endInput?.value;

    if (!start || !end) {
      setHolidayHint("Choose start and end dates.", true);
      return;
    }

    bookBtn.disabled = true;
    const result = await bookOwnerHoliday(start, end);
    bookBtn.disabled = false;

    if (!result.ok) {
      const msg = result.msg || "";
      if (msg.includes("club_holiday_book") || msg.includes("function")) {
        setHolidayHint(
          "Holiday booking unavailable. Run supabase/sql/club_owner_holidays.sql in Supabase.",
          true
        );
      } else {
        setHolidayHint(msg, true);
      }
      return;
    }

    if (startInput) startInput.value = "";
    if (endInput) endInput.value = "";
    updateHolidayDayPreview();
    setHolidayHint("Holiday booked — overlapping match months unlock for early play.");
    await refreshHolidaySection();
  });
}

async function initClubDetailsPage() {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const emailEl = document.getElementById("accountEmail");
  if (emailEl) emailEl.textContent = user.email || "—";

  const ownerEls = {
    input: document.getElementById("ownerInput"),
    editBtn: document.getElementById("editOwnerTagBtn"),
    saveBtn: document.getElementById("saveOwnerBtn"),
    hint: document.getElementById("ownerTagHint"),
  };

  let storedTag = null;
  initOwnerTagField(ownerEls, null);
  wireOwnerTagField(ownerEls, (tag) => {
    storedTag = tag;
  });

  const { data: club, error } = await loadOwnerClub(user.id);

  if (error) {
    console.error("Club Details club load:", error);
    showLoadError(
      `Could not load club details (${error.message}). Check Supabase Clubs access.`
    );
    return;
  }

  if (!club?.ShortName) {
    showLoadError(
      "No club is linked to your account. Ask an admin to link your club under Owner administration."
    );
    return;
  }

  document.getElementById("clubName").textContent =
    fullClubName(club.ShortName) || club.Club || club.ShortName;
  document.getElementById("shortName").textContent = club.ShortName;
  document.getElementById("stadiumName").textContent = club.Stadium || "—";
  document.getElementById("stadiumCapacity").textContent =
    club.Capacity != null && club.Capacity !== ""
      ? String(club.Capacity)
      : "—";
  document.getElementById("clubNation").textContent = club.Nation
    ? formatNationLabel(club.Nation)
    : "—";

  storedTag = club.owner?.trim() || null;
  initOwnerTagField(ownerEls, storedTag);

  const divEl = document.getElementById("compDivision");
  try {
    const season = await loadCurrentSeason(supabase);
    if (season) {
      const regs = await loadActiveSeasonRegistrations(supabase);
      const div = divisionForClub(regs, club.ShortName);
      divEl.textContent = div ? `${div} (current season)` : "Not registered";
    } else {
      divEl.textContent = "No active season";
    }
  } catch (err) {
    console.warn("Club Details division:", err);
    divEl.textContent = "—";
  }

  wireHolidayBooking();
  await refreshHolidaySection();
}

document.addEventListener("DOMContentLoaded", () => {
  initClubDetailsPage().catch((err) => {
    console.error("Club Details init failed:", err);
    showLoadError(
      err?.message ||
        "Club Details failed to load. Try a hard refresh (Ctrl+F5)."
    );
  });
});
