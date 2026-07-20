// Owner Details page — login, Discord tag, badge, availability, holidays

import { supabase, initGlobal } from "./global.js";
import { loadCurrentSeason } from "./competition.js";
import {
  HOLIDAY_DAYS_PER_SEASON,
  loadOwnerHolidays,
  bookOwnerHoliday,
  cancelOwnerHoliday,
  formatUkDateRange,
  holidayStatusLabel,
  inclusiveDayCountFromDates,
} from "./owner_holidays.js";
import { wireAvailabilityPanel } from "./owner_availability.js";
import { ownerBadgePublicUrl, ownerProfileHref } from "./owner_badge.js";
import {
  applyClubDashboardTheme,
  loadClubDashboardTheme,
} from "./club_theme_common.js";

const MAX_OWNER_TAG_LEN = 64;

function normalizeOwnerTagInput(raw) {
  return String(raw ?? "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, MAX_OWNER_TAG_LEN);
}

function setBtnVisible(btn, visible) {
  if (!btn) return;
  btn.classList.toggle("is-hidden", !visible);
}

function setOwnerTagMode(els, mode) {
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

function initOwnerTagField(els, storedTag) {
  const locked = Boolean(storedTag && String(storedTag).trim());
  els.input.value = locked ? String(storedTag).trim() : "";
  setOwnerTagMode(els, locked ? "locked" : "empty");
}

async function saveOwnerTag(tag) {
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

function setOwnerBadgeHint(message, isError = false) {
  const el = document.getElementById("ownerBadgeHint");
  if (!el) return;
  el.textContent = message || "";
  el.classList.toggle("owner-tag-hint--error", isError);
}

let ownerBadgeObjectUrl = null;

function clearOwnerBadgeObjectUrl() {
  if (ownerBadgeObjectUrl) {
    URL.revokeObjectURL(ownerBadgeObjectUrl);
    ownerBadgeObjectUrl = null;
  }
}

/** @param {string|null} badgePathOrUrl storage path, full http(s) URL, or null */
function renderOwnerBadgePreview(badgePathOrUrl, tag) {
  const img = document.getElementById("ownerBadgePreview");
  const fallback = document.getElementById("ownerBadgeFallback");
  if (!img || !fallback) return;

  const raw = badgePathOrUrl ? String(badgePathOrUrl) : "";
  const url =
    raw.startsWith("blob:") || raw.startsWith("http")
      ? raw
      : ownerBadgePublicUrl(raw || null);

  if (url) {
    img.src = url;
    img.alt = tag || "Owner badge";
    img.hidden = false;
    fallback.hidden = true;
    return;
  }

  img.removeAttribute("src");
  img.hidden = true;
  fallback.hidden = false;
  fallback.textContent = String(tag || "?").slice(0, 2).toUpperCase();
}

async function loadOwnerBadgeState(userId, tag) {
  const link = document.getElementById("ownerProfileLink");
  if (link && userId) {
    link.href = ownerProfileHref(userId);
  }

  const { data, error } = await supabase
    .from("gpsl_owner_profile_public")
    .select("badge_path, owner_tag")
    .eq("owner_id", userId)
    .maybeSingle();

  if (error) {
    if (/gpsl_owner_profile_public|badge_path/i.test(error.message || "")) {
      setOwnerBadgeHint(
        "Run supabase/sql/patches/owner_profile_and_badge.sql to enable profile badges.",
        true
      );
    }
    renderOwnerBadgePreview(null, tag);
    return;
  }

  renderOwnerBadgePreview(data?.badge_path, data?.owner_tag || tag);
}

function wireOwnerBadgeField(userId, getTag) {
  const uploadBtn = document.getElementById("ownerBadgeUploadBtn");
  const clearBtn = document.getElementById("ownerBadgeClearBtn");
  const fileInput = document.getElementById("ownerBadgeFile");
  if (!uploadBtn || !clearBtn || !fileInput) return;

  fileInput.addEventListener("change", () => {
    const file = fileInput.files?.[0];
    if (!file) {
      setOwnerBadgeHint("No badge yet — choose a file, then Save badge.");
      return;
    }
    if (file.size > 1024 * 1024) {
      setOwnerBadgeHint("Max 1 MB — pick a smaller image.", true);
      fileInput.value = "";
      return;
    }
    clearOwnerBadgeObjectUrl();
    ownerBadgeObjectUrl = URL.createObjectURL(file);
    renderOwnerBadgePreview(ownerBadgeObjectUrl, getTag());
    setOwnerBadgeHint(`Selected “${file.name}”. Click Save badge to apply it.`);
  });

  uploadBtn.addEventListener("click", async () => {
    const file = fileInput.files?.[0];
    if (!file) {
      setOwnerBadgeHint("Choose a file first, then click Save badge.", true);
      return;
    }
    if (file.size > 1024 * 1024) {
      setOwnerBadgeHint("Max 1 MB.", true);
      return;
    }

    uploadBtn.disabled = true;
    setOwnerBadgeHint("Saving badge…");

    const { error: ensureErr } = await supabase.rpc("owner_registry_ensure_self");
    if (ensureErr) {
      uploadBtn.disabled = false;
      setOwnerBadgeHint(
        /owner_registry_ensure_self/i.test(ensureErr.message || "")
          ? "Run supabase/sql/patches/owner_profile_and_badge.sql first."
          : ensureErr.message,
        true
      );
      return;
    }

    const ext = (file.name.split(".").pop() || "png")
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "");
    const path = `${userId}/badge.${ext || "png"}`;
    const { error: upErr } = await supabase.storage
      .from("owner-badges")
      .upload(path, file, { upsert: true, contentType: file.type || "image/png" });

    if (upErr) {
      uploadBtn.disabled = false;
      setOwnerBadgeHint(
        /bucket|not found|row-level security|policy/i.test(upErr.message || "")
          ? `${upErr.message} — run owner_profile_and_badge.sql (creates owner-badges bucket).`
          : upErr.message,
        true
      );
      return;
    }

    const { error } = await supabase.rpc("owner_registry_set_badge_path", {
      p_path: path,
    });
    uploadBtn.disabled = false;

    if (error) {
      setOwnerBadgeHint(error.message, true);
      return;
    }

    clearOwnerBadgeObjectUrl();
    fileInput.value = "";
    setOwnerBadgeHint("Badge saved — this is now your owner profile icon.");
    renderOwnerBadgePreview(path, getTag());
  });

  clearBtn.addEventListener("click", async () => {
    clearBtn.disabled = true;
    setOwnerBadgeHint("Removing badge…");
    const { error } = await supabase.rpc("owner_registry_set_badge_path", {
      p_path: null,
    });
    clearBtn.disabled = false;
    if (error) {
      setOwnerBadgeHint(error.message, true);
      return;
    }
    clearOwnerBadgeObjectUrl();
    fileInput.value = "";
    setOwnerBadgeHint("Badge removed.");
    renderOwnerBadgePreview(null, getTag());
  });
}

async function loadOwnerClub(userId) {
  return supabase
    .from("Clubs")
    .select("ShortName, owner")
    .eq("owner_id", userId)
    .maybeSingle();
}

function showLoadError(message) {
  const el = document.getElementById("ownerDetailsError");
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
        status === "Active"
          ? "holiday-status holiday-status--active"
          : "holiday-status";
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

function accountEmailRedirectUrl() {
  return new URL("owner_details.html", window.location.href).href;
}

function wireAccountExpandToggles() {
  const emailBtn = document.getElementById("toggleEmailChangeBtn");
  const passwordBtn = document.getElementById("togglePasswordChangeBtn");
  const emailPanel = document.getElementById("accountEmailChange");
  const passwordPanel = document.getElementById("accountPasswordChange");

  const toggle = (panel, btn, otherPanel, otherBtn) => {
    if (!panel || !btn) return;
    const show = panel.hidden;
    panel.hidden = !show;
    btn.setAttribute("aria-expanded", show ? "true" : "false");
    if (show) {
      if (otherPanel) otherPanel.hidden = true;
      if (otherBtn) otherBtn.setAttribute("aria-expanded", "false");
      panel.querySelector("input")?.focus();
    }
  };

  emailBtn?.addEventListener("click", () =>
    toggle(emailPanel, emailBtn, passwordPanel, passwordBtn)
  );
  passwordBtn?.addEventListener("click", () =>
    toggle(passwordPanel, passwordBtn, emailPanel, emailBtn)
  );
}

function wireAccountSettings(user) {
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

  wireAccountExpandToggles();

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
    const { error } = await supabase.auth.updateUser(
      { email: newEmail },
      { emailRedirectTo: accountEmailRedirectUrl() }
    );
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
    const { error } = await supabase.auth.updateUser({
      password: newPassword,
      current_password: currentPassword,
    });
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

function wireHolidayExpandToggle() {
  const btn = document.getElementById("toggleHolidayBookingBtn");
  const panel = document.getElementById("holidayBookingExpand");
  btn?.addEventListener("click", () => {
    if (!panel) return;
    const show = panel.hidden;
    panel.hidden = !show;
    btn.setAttribute("aria-expanded", show ? "true" : "false");
    if (show) {
      document.getElementById("holidayStartDate")?.focus();
    }
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

async function initOwnerDetailsPage() {
  await initGlobal();

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
    const img = document.getElementById("ownerBadgePreview");
    if (img && !img.hidden && img.src) {
      img.alt = tag || "Owner badge";
    } else {
      renderOwnerBadgePreview(null, tag);
    }
  });
  wireOwnerBadgeField(user.id, () => storedTag || ownerEls.input.value);

  const { data: club, error } = await loadOwnerClub(user.id);

  if (error) {
    console.error("Owner Details club load:", error);
    showLoadError(
      `Could not load owner details (${error.message}). Check Supabase Clubs access.`
    );
    return;
  }

  if (!club?.ShortName) {
    showLoadError(
      "No club is linked to your account. Ask an admin to link your club under Owner administration."
    );
    return;
  }

  storedTag = club.owner?.trim() || null;
  initOwnerTagField(ownerEls, storedTag);
  await loadOwnerBadgeState(user.id, storedTag);

  try {
    const theme = await loadClubDashboardTheme(supabase, club.ShortName);
    applyClubDashboardTheme(theme, { pageKey: "owner_details" });
  } catch (err) {
    console.warn("Owner Details theme:", err);
  }

  wireHolidayBooking();
  wireHolidayExpandToggle();
  wireAvailabilityPanel();
  await refreshHolidaySection();
}

initOwnerDetailsPage().catch((err) => {
  console.error(err);
  showLoadError(err?.message || "Could not load owner details.");
});
