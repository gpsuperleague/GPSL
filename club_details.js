// Club Details page

import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
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

function renderChallengeGrid(progress, loadError) {
  const grid = document.getElementById("challengeGrid");
  if (!grid) return;

  if (loadError) {
    grid.innerHTML = `<p class="subsidy-meta">${loadError}</p>`;
    return;
  }

  const items = progress?.challenges || [];
  if (!items.length) {
    grid.innerHTML = "<p class=\"subsidy-meta\">No active challenges this season.</p>";
    return;
  }

  grid.innerHTML = items
    .map((c) => {
      const done = c.awarded || Number(c.current_value) >= Number(c.target_value);
      const status = c.awarded
        ? "Awarded"
        : c.expired
          ? "Expired"
          : done
            ? "Complete"
            : `${c.current_value ?? 0} / ${c.target_value}`;
      return `
        <div class="subsidy-card">
          <h3>${c.title}</h3>
          <p class="subsidy-status">${status}</p>
          <p class="subsidy-meta">${c.window_phase} window · ${formatMoney(Number(c.prize_amount || 0))}</p>
        </div>
      `;
    })
    .join("");
}

function formatDivisionLabel(division) {
  if (!division) return "—";
  if (division === "superleague") return "Super League";
  if (division === "championship_a") return "Championship A";
  if (division === "championship_b") return "Championship B";
  return division;
}

function formatManagerTarget(row) {
  if (!row?.target_label) return "—";
  if (row.target_kind === "max_position" && row.target_value) {
    return `${row.target_label} (finish ≤ ${row.target_value})`;
  }
  return row.target_label;
}

function formatTargetProgress(row) {
  if (row.target_met === true) return "On course ✓";
  if (row.target_met === false) return "Off course ✗";
  if (row.season_position != null) return `Position ${row.season_position} (pending evaluation)`;
  return "Season in progress";
}

async function loadManagerSection(clubShortName) {
  const statusEl = document.getElementById("managerStatus");
  const hintEl = document.getElementById("managerHint");
  const listBtn = document.getElementById("listManagerBtn");
  const sackBtn = document.getElementById("sackManagerBtn");

  const { data, error } = await supabase
    .from("manager_club_status_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .maybeSingle();

  if (error) {
    const msg = String(error.message || "");
    if (statusEl) {
      statusEl.textContent = msg.includes("manager_club_status")
        ? "Run supabase/sql/patches/managers_system.sql to enable managers."
        : msg;
    }
    return;
  }

  if (!data?.manager_id) {
    if (statusEl) {
      statusEl.innerHTML =
        'No manager signed. <a href="MGDB.html" style="color:#ff9900;">Browse MGDB</a> or the manager transfer market.';
    }
    setBtnVisible(listBtn, false);
    setBtnVisible(sackBtn, false);
    return;
  }

  if (statusEl) {
    statusEl.innerHTML = `
      <dl style="display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0;font-size:14px;">
        <dt>Manager</dt><dd><b>${data.manager_name}</b> (rating ${data.manager_rating})</dd>
        <dt>Market value</dt><dd>${formatMoney(Number(data.market_value || 0))}</dd>
        <dt>Contract</dt><dd>${data.contract_seasons_remaining ?? 0} season(s) remaining</dd>
        <dt>Weekly wage</dt><dd>${formatMoney(Number(data.weekly_wage || 0))}</dd>
        <dt>Division</dt><dd>${formatDivisionLabel(data.division)}</dd>
        <dt>Target</dt><dd>${formatManagerTarget(data)}</dd>
        <dt>Progress</dt><dd>${formatTargetProgress(data)}</dd>
        <dt>Sack allowance</dt><dd>${data.manager_sacks_remaining ? "Available this season" : "Used"}</dd>
      </dl>
    `;
  }

  setBtnVisible(listBtn, true);
  setBtnVisible(sackBtn, Boolean(data.manager_sacks_remaining));

  if (listBtn) listBtn.dataset.managerId = String(data.manager_id);
  if (sackBtn) {
    sackBtn.dataset.clubShort = clubShortName;
    sackBtn.disabled = !data.manager_sacks_remaining;
  }
}

async function loadChallengeProgress(clubShortName) {
  const { data, error } = await supabase.rpc("competition_challenge_club_progress", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("competition_challenge_club_progress") || msg.includes("function")) {
      renderChallengeGrid(
        null,
        "Run supabase/sql/competition_challenges.sql to enable challenge tracking."
      );
      return;
    }
    renderChallengeGrid(null, msg || "Could not load challenges.");
    return;
  }

  renderChallengeGrid(data, null);
}

function setAccountStatus(el, message, isError = false) {
  if (!el) return;
  el.textContent = message || "";
  el.classList.toggle("is-error", isError);
}

async function verifyCurrentPassword(email, password) {
  if (!email || !password) {
    return { ok: false, msg: "Enter your current password." };
  }

  const { error } = await supabase.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    return { ok: false, msg: "Current password is incorrect." };
  }

  return { ok: true };
}

function wireAccountSettings(user) {
  const emailEl = document.getElementById("accountEmail");
  const newEmailInput = document.getElementById("newEmailInput");
  const emailCurrentPassword = document.getElementById("emailCurrentPassword");
  const changeEmailBtn = document.getElementById("changeEmailBtn");
  const emailChangeStatus = document.getElementById("emailChangeStatus");

  const currentPasswordInput = document.getElementById("currentPasswordInput");
  const newPasswordInput = document.getElementById("newPasswordInput");
  const confirmPasswordInput = document.getElementById("confirmPasswordInput");
  const changePasswordBtn = document.getElementById("changePasswordBtn");
  const passwordChangeStatus = document.getElementById("passwordChangeStatus");

  const loginEmail = user?.email || "";

  changeEmailBtn?.addEventListener("click", async () => {
    const newEmail = newEmailInput?.value.trim().toLowerCase() || "";
    const currentPassword = emailCurrentPassword?.value || "";

    setAccountStatus(emailChangeStatus, "");

    if (!newEmail) {
      setAccountStatus(emailChangeStatus, "Enter a new email address.", true);
      return;
    }

    if (newEmail === loginEmail.toLowerCase()) {
      setAccountStatus(emailChangeStatus, "That is already your login email.", true);
      return;
    }

    const verified = await verifyCurrentPassword(loginEmail, currentPassword);
    if (!verified.ok) {
      setAccountStatus(emailChangeStatus, verified.msg, true);
      return;
    }

    changeEmailBtn.disabled = true;
    const { error } = await supabase.auth.updateUser({ email: newEmail });
    changeEmailBtn.disabled = false;

    if (error) {
      setAccountStatus(emailChangeStatus, error.message || "Could not update email.", true);
      return;
    }

    if (newEmailInput) newEmailInput.value = "";
    if (emailCurrentPassword) emailCurrentPassword.value = "";
    setAccountStatus(
      emailChangeStatus,
      `Confirmation sent to ${newEmail}. Click the link in that email to finish the change.`
    );
  });

  changePasswordBtn?.addEventListener("click", async () => {
    const currentPassword = currentPasswordInput?.value || "";
    const newPassword = newPasswordInput?.value || "";
    const confirmPassword = confirmPasswordInput?.value || "";

    setAccountStatus(passwordChangeStatus, "");

    if (!newPassword || newPassword.length < 6) {
      setAccountStatus(
        passwordChangeStatus,
        "New password must be at least 6 characters.",
        true
      );
      return;
    }

    if (newPassword !== confirmPassword) {
      setAccountStatus(passwordChangeStatus, "New passwords do not match.", true);
      return;
    }

    if (newPassword === currentPassword) {
      setAccountStatus(
        passwordChangeStatus,
        "Choose a different password from your current one.",
        true
      );
      return;
    }

    const verified = await verifyCurrentPassword(loginEmail, currentPassword);
    if (!verified.ok) {
      setAccountStatus(passwordChangeStatus, verified.msg, true);
      return;
    }

    changePasswordBtn.disabled = true;
    const { error } = await supabase.auth.updateUser({ password: newPassword });
    changePasswordBtn.disabled = false;

    if (error) {
      setAccountStatus(
        passwordChangeStatus,
        error.message || "Could not update password.",
        true
      );
      return;
    }

    if (currentPasswordInput) currentPasswordInput.value = "";
    if (newPasswordInput) newPasswordInput.value = "";
    if (confirmPasswordInput) confirmPasswordInput.value = "";
    setAccountStatus(passwordChangeStatus, "Password updated successfully.");
  });
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
  wireAccountSettings(user);

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

  await loadChallengeProgress(club.ShortName);
  await loadManagerSection(club.ShortName);

  wireHolidayBooking();
  wireManagerActions();
  await refreshHolidaySection();
}

function wireManagerActions() {
  const listBtn = document.getElementById("listManagerBtn");
  const sackBtn = document.getElementById("sackManagerBtn");
  const hintEl = document.getElementById("managerHint");

  if (listBtn && !listBtn.dataset.wired) {
    listBtn.dataset.wired = "1";
    listBtn.addEventListener("click", async () => {
      const managerId = Number(listBtn.dataset.managerId);
      if (!managerId) return;
      listBtn.disabled = true;
      const { error } = await supabase.rpc("manager_list_for_transfer", {
        p_manager_id: managerId,
      });
      listBtn.disabled = false;
      if (error) {
        if (hintEl) hintEl.textContent = error.message;
        return;
      }
      if (hintEl) hintEl.textContent = "Manager listed — see Manager Transfer Market.";
    });
  }

  if (sackBtn && !sackBtn.dataset.wired) {
    sackBtn.dataset.wired = "1";
    sackBtn.addEventListener("click", async () => {
      if (!confirm("Sack manager? You receive half market value and cannot sack again this season.")) {
        return;
      }
      const clubShort = sackBtn.dataset.clubShort;
      sackBtn.disabled = true;
      const { error } = await supabase.rpc("manager_sack");
      sackBtn.disabled = false;
      if (error) {
        if (hintEl) hintEl.textContent = error.message;
        return;
      }
      if (hintEl) hintEl.textContent = "Manager sacked.";
      if (clubShort) await loadManagerSection(clubShort);
    });
  }
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
