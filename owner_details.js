// Owner Details page — login, Discord tag, badge, availability, holidays

import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { loadCurrentSeason } from "./competition.js";
import {
  HOLIDAY_DAYS_PER_SEASON,
  loadOwnerHolidays,
  bookOwnerHoliday,
  cancelOwnerHoliday,
  amendOwnerHoliday,
  holidayRowToDateInputs,
  formatUkDateRange,
  holidayStatusLabel,
  inclusiveDayCountFromDates,
} from "./owner_holidays.js?v=20261019-supporter-holiday";
import { wireAvailabilityPanel } from "./owner_availability.js?v=20260930-world-tz";
import {
  ownerBadgePublicUrl,
  ownerBadgeStoragePath,
  ownerProfileHref,
  removeStaleOwnerBadges,
} from "./owner_badge.js?v=20261020-badge-cache";
import {
  applyClubDashboardTheme,
  loadClubDashboardTheme,
} from "./club_theme_common.js";

const MAX_OWNER_TAG_LEN = 64;

const TRANSLATE_LANGUAGES = [
  ["AR", "العربية — Arabic"],
  ["BG", "Български — Bulgarian"],
  ["CS", "Čeština — Czech"],
  ["DA", "Dansk — Danish"],
  ["DE", "Deutsch — German"],
  ["EL", "Ελληνικά — Greek"],
  ["ES", "Español — Spanish"],
  ["ET", "Eesti — Estonian"],
  ["FI", "Suomi — Finnish"],
  ["FR", "Français — French"],
  ["HU", "Magyar — Hungarian"],
  ["ID", "Bahasa Indonesia — Indonesian"],
  ["IT", "Italiano — Italian"],
  ["JA", "日本語 — Japanese"],
  ["KO", "한국어 — Korean"],
  ["LT", "Lietuvių — Lithuanian"],
  ["LV", "Latviešu — Latvian"],
  ["NB", "Norsk — Norwegian"],
  ["NL", "Nederlands — Dutch"],
  ["PL", "Polski — Polish"],
  ["PT-BR", "Português (Brasil) — Portuguese (Brazil)"],
  ["PT-PT", "Português (Portugal) — Portuguese (Portugal)"],
  ["RO", "Română — Romanian"],
  ["RU", "Русский — Russian"],
  ["SK", "Slovenčina — Slovak"],
  ["SL", "Slovenščina — Slovenian"],
  ["SV", "Svenska — Swedish"],
  ["TR", "Türkçe — Turkish"],
  ["UK", "Українська — Ukrainian"],
  ["ZH", "中文 (简体) — Chinese (Simplified)"],
];

function setLanguageHint(message, isError = false) {
  const el = document.getElementById("ownerLanguageHint");
  if (!el) return;
  el.textContent = message || "";
  el.style.color = isError ? "#ff6b6b" : "#8bc34a";
}

async function wireOwnerLanguage() {
  const select = document.getElementById("ownerLanguageSelect");
  const dmBox = document.getElementById("ownerLanguageDm");
  const saveBtn = document.getElementById("saveOwnerLanguageBtn");
  if (!select || !dmBox || !saveBtn) return;

  select.innerHTML = [
    `<option value="">English (no translation)</option>`,
    ...TRANSLATE_LANGUAGES.map(([code, label]) => `<option value="${code}">${label}</option>`),
  ].join("");

  const syncDmBox = () => {
    dmBox.disabled = !select.value;
  };
  select.addEventListener("change", syncDmBox);

  const { data, error } = await supabase.rpc("my_owner_language_get");
  if (error) {
    console.warn("my_owner_language_get:", error);
    setLanguageHint("Translation settings unavailable right now.", true);
    saveBtn.disabled = true;
    return;
  }
  select.value = data?.language || "";
  dmBox.checked = data?.dm_announcements !== false;
  syncDmBox();

  saveBtn.addEventListener("click", async () => {
    saveBtn.disabled = true;
    setLanguageHint("Saving…");
    const { data: res, error: saveErr } = await supabase.rpc("my_owner_language_set", {
      p_language: select.value || null,
      p_dm_announcements: dmBox.checked,
    });
    saveBtn.disabled = false;
    if (saveErr || res?.ok === false) {
      setLanguageHint(`Could not save (${saveErr?.message || res?.reason || "error"}).`, true);
      return;
    }
    setLanguageHint(
      select.value
        ? "Saved. In Discord: right-click a message → Apps → Translate."
        : "Saved — translation off."
    );
  });
}

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
function renderOwnerBadgePreview(badgePathOrUrl, tag, { cacheBust } = {}) {
  const img = document.getElementById("ownerBadgePreview");
  const fallback = document.getElementById("ownerBadgeFallback");
  if (!img || !fallback) return;

  const raw = badgePathOrUrl ? String(badgePathOrUrl) : "";
  const url =
    raw.startsWith("blob:") || raw.startsWith("http")
      ? raw
      : ownerBadgePublicUrl(raw || null, {
          cacheBust: cacheBust ?? Date.now(),
        });

  if (url) {
    // Force a fetch even when the path string is unchanged.
    img.removeAttribute("src");
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


let ownerCanSetBadge = false;

async function refreshOwnerSupporterBadgeGate() {
  ownerCanSetBadge = false;
  const { data, error } = await supabase.rpc("owner_registry_get_self");
  if (error) {
    console.warn("owner_registry_get_self (badge gate):", error);
  } else {
    ownerCanSetBadge =
      data?.can_set_profile_image === true || data?.supporter_active === true;
  }

  const uploadBtn = document.getElementById("ownerBadgeUploadBtn");
  const clearBtn = document.getElementById("ownerBadgeClearBtn");
  const fileInput = document.getElementById("ownerBadgeFile");
  const controls = document.querySelector(".owner-badge-controls");
  if (fileInput) fileInput.disabled = !ownerCanSetBadge;
  if (uploadBtn) uploadBtn.disabled = !ownerCanSetBadge;
  // Allow remove even when lapsed so owners can clear a stored badge.
  if (clearBtn) clearBtn.disabled = false;
  if (controls) controls.classList.toggle("owner-badge-controls--locked", !ownerCanSetBadge);
  if (fileInput) fileInput.hidden = !ownerCanSetBadge;
  if (uploadBtn) uploadBtn.hidden = !ownerCanSetBadge;
  if (!ownerCanSetBadge) {
    setOwnerBadgeHint(
      "Profile badge is a Ko-fi Supporter perk. Non-supporters cannot upload a new image."
    );
  }
  return ownerCanSetBadge;
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
    if (!ownerCanSetBadge) {
      setOwnerBadgeHint("Profile image is a Ko-fi Supporter perk.", true);
      return;
    }
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

    const path = ownerBadgeStoragePath(userId, file.name);
    if (!path) {
      uploadBtn.disabled = false;
      setOwnerBadgeHint("Could not build badge path.", true);
      return;
    }
    const { error: upErr } = await supabase.storage
      .from("owner-badges")
      .upload(path, file, {
        upsert: false,
        contentType: file.type || "image/png",
        cacheControl: "3600",
      });

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

    void removeStaleOwnerBadges(userId, path);
    clearOwnerBadgeObjectUrl();
    fileInput.value = "";
    setOwnerBadgeHint("Badge saved — this is now your owner profile icon.");
    renderOwnerBadgePreview(path, getTag(), { cacheBust: Date.now() });
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

let holidayEditingId = null;

function setHolidayHint(message, isError = false) {
  const el = document.getElementById("holidayHint");
  if (!el) return;
  el.textContent = message || "";
  el.classList.toggle("owner-tag-hint--error", isError);
}

function clearHolidayEditMode() {
  holidayEditingId = null;
  const bookBtn = document.getElementById("bookHolidayBtn");
  const cancelEditBtn = document.getElementById("cancelHolidayEditBtn");
  if (bookBtn) bookBtn.textContent = "Book holiday";
  if (cancelEditBtn) cancelEditBtn.hidden = true;
  const start = document.getElementById("holidayStartDate");
  const end = document.getElementById("holidayEndDate");
  if (start) start.value = "";
  if (end) end.value = "";
  updateHolidayDayPreview();
}

function beginHolidayEdit(row) {
  holidayEditingId = row.id;
  const { startDate, endDate } = holidayRowToDateInputs(row);
  const start = document.getElementById("holidayStartDate");
  const end = document.getElementById("holidayEndDate");
  if (start) start.value = startDate;
  if (end) end.value = endDate;
  const bookBtn = document.getElementById("bookHolidayBtn");
  const cancelEditBtn = document.getElementById("cancelHolidayEditBtn");
  if (bookBtn) bookBtn.textContent = "Save changes";
  if (cancelEditBtn) cancelEditBtn.hidden = false;
  updateHolidayDayPreview();
  setHolidayHint("Editing upcoming holiday — change dates and save, or cancel edit.");
  document.getElementById("holidayBookingExpand")?.removeAttribute("hidden");
  document
    .getElementById("toggleHolidayBookingBtn")
    ?.setAttribute("aria-expanded", "true");
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
      const paused = h.is_effective === false || h.needs_supporter === true;
      const status = paused ? "Paused (supporter)" : holidayStatusLabel(h);
      const statusClass = paused
        ? "holiday-status holiday-status--paused"
        : status === "Active"
          ? "holiday-status holiday-status--active"
          : "holiday-status";
      const actions = h.is_upcoming
        ? `<span style="display:flex;gap:6px;">
            <button type="button" class="small-btn holiday-amend-btn" data-id="${h.id}">Amend</button>
            <button type="button" class="small-btn holiday-cancel-btn" data-id="${h.id}">Cancel</button>
          </span>`
        : `<span class="holiday-item-meta">${
            paused
              ? "Over 14-day base — renew supporter to keep active"
              : h.is_active
                ? "Active — ask admin to change"
                : "Ended — ask admin to change"
          }</span>`;
      return `
        <div class="holiday-item${paused ? " holiday-item--paused" : ""}">
          <div class="holiday-item-dates">
            <b>${formatUkDateRange(h.starts_at, h.ends_at)}</b>
            <span class="holiday-item-meta"> · ${h.day_count} day${h.day_count === 1 ? "" : "s"}</span>
          </div>
          <span class="${statusClass}">${status}</span>
          ${actions}
        </div>
      `;
    })
    .join("");

  list.querySelectorAll(".holiday-cancel-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.dataset.id);
      if (!window.confirm("Cancel this holiday booking?")) return;
      btn.disabled = true;
      const result = await cancelOwnerHoliday(id);
      btn.disabled = false;
      if (!result.ok) {
        setHolidayHint(result.msg, true);
        return;
      }
      if (holidayEditingId === id) clearHolidayEditMode();
      setHolidayHint("Holiday cancelled.");
      await refreshHolidaySection();
    });
  });

  list.querySelectorAll(".holiday-amend-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = Number(btn.dataset.id);
      const row = holidays.find((h) => Number(h.id) === id);
      if (row) beginHolidayEdit(row);
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

  const { holidays, daysUsed, daysRemaining, maxDays, supporterActive } =
    await loadOwnerHolidays();
  if (quotaEl) {
    const max = maxDays || HOLIDAY_DAYS_PER_SEASON;
    const perk = supporterActive ? " (supporter)" : "";
    quotaEl.textContent = `${daysUsed} of ${max} days used this season${perk} · ${daysRemaining} remaining`;
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

function setMatchSystemHint(msg, isError = false) {
  const el = document.getElementById("matchSystemHint");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("is-error", isError);
}

function setSeasonAbsenceHint(msg, isError = false) {
  const el = document.getElementById("seasonAbsenceHint");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("is-error", isError);
}

function matchSystemIsOn(el) {
  if (!el) return true;
  return el.getAttribute("aria-checked") !== "false";
}

function setMatchSystemSwitch(el, on, { morph = false } = {}) {
  if (!el) return;
  const next = on !== false;
  const prev = matchSystemIsOn(el);
  el.setAttribute("aria-checked", next ? "true" : "false");
  if (morph && prev !== next) {
    el.classList.add("is-morphing");
    window.setTimeout(() => el.classList.remove("is-morphing"), 550);
  }
  const caption = document.getElementById("matchSystemCaption");
  if (caption) {
    caption.classList.toggle("is-on", next);
    caption.classList.toggle("is-off", !next);
    caption.innerHTML = next
      ? "<strong>GPSL arranging</strong>Propose / reply deadlines and arrangement fines apply."
      : "<strong>Manual black box</strong>Off-site arrange only vs other OFF clubs — month lock = mutual forfeit + ₿2.5m.";
  }
}

function paintMatchSystemChrome(on, { morph = false } = {}) {
  const cell = document.getElementById("matchSystemCell");
  const pill = document.getElementById("matchSystemPill");
  const pillText = document.getElementById("matchSystemPillText");
  if (cell) {
    cell.classList.toggle("is-ms-on", on);
    cell.classList.toggle("is-ms-off", !on);
    if (morph) {
      cell.classList.remove("is-ms-morph");
      // restart animation
      void cell.offsetWidth;
      cell.classList.add("is-ms-morph");
      window.setTimeout(() => cell.classList.remove("is-ms-morph"), 700);
    }
  }
  if (pill) {
    pill.classList.toggle("is-on", on);
    pill.classList.toggle("is-off", !on);
  }
  if (pillText) pillText.textContent = on ? "ON" : "OFF";
}

async function refreshMatchSystemSection({ morph = false } = {}) {
  const note = document.getElementById("matchSystemNote");
  const pillText = document.getElementById("matchSystemPillText");
  const chk = document.getElementById("matchSystemOnChk");
  const saveBtn = document.getElementById("saveMatchSystemBtn");
  const { data, error } = await supabase.rpc("owner_match_system_status");
  if (error) {
    if (note) {
      note.textContent =
        error.message?.includes("owner_match_system") ||
        error.message?.includes("function")
          ? "Unavailable — admin must run gpsl_match_system_toggle_20261020.sql."
          : error.message;
    }
    if (pillText) pillText.textContent = "?";
    saveBtn && (saveBtn.hidden = true);
    return;
  }

  const on = data?.effective_gpsl_system_on !== false;
  const half = data?.editable_half;
  const canEdit = Boolean(half);
  const windowNote = canEdit
    ? half === "h1"
      ? "July window — editing Aug–Dec."
      : "December window — editing Jan onward."
    : "Locked until next July / December window.";
  if (note) {
    note.textContent = `${
      on ? "GPSL arranging — propose / reply / fines." : "Manual / Discord black box."
    } ${windowNote}`;
  }
  paintMatchSystemChrome(on, { morph });

  if (chk) {
    const editOn =
      half === "h2"
        ? data?.h2_gpsl_system_on !== false
        : data?.h1_gpsl_system_on !== false;
    setMatchSystemSwitch(chk, canEdit ? editOn : on, { morph });
    chk.disabled = !canEdit;
  }
  if (saveBtn) saveBtn.hidden = !canEdit;
  setMatchSystemHint(
    canEdit
      ? half === "h1"
        ? "Saving applies for August–December fixtures."
        : "Saving applies from January onward (Aug–Dec unchanged)."
      : "Preference is locked mid-half. Next change windows: July (Aug–Dec) and December (Jan–end)."
  );
}

function wireMatchSystem() {
  const toggle = document.getElementById("toggleMatchSystemBtn");
  const panel = document.getElementById("matchSystemExpand");
  const chk = document.getElementById("matchSystemOnChk");
  toggle?.addEventListener("click", () => {
    if (!panel) return;
    const show = panel.hidden;
    panel.hidden = !show;
    toggle.setAttribute("aria-expanded", show ? "true" : "false");
  });

  chk?.addEventListener("click", () => {
    if (chk.disabled) return;
    const next = !matchSystemIsOn(chk);
    setMatchSystemSwitch(chk, next, { morph: true });
  });

  document.getElementById("saveMatchSystemBtn")?.addEventListener("click", async () => {
    const switchEl = document.getElementById("matchSystemOnChk");
    const turningOff = switchEl && !matchSystemIsOn(switchEl);
    if (
      turningOff &&
      !confirm(
        "Turn GPSL match system OFF?\n\nAgainst other OFF clubs you arrange fully off-site (no propose deadlines). Still unplayed at month lock → mutual forfeit (0 pts each) + ₿2.5m each. Cups: both go out."
      )
    ) {
      setMatchSystemSwitch(switchEl, true, { morph: true });
      return;
    }
    const { data, error } = await supabase.rpc("owner_match_system_set", {
      p_gpsl_system_on: switchEl ? matchSystemIsOn(switchEl) : true,
      p_half: null,
    });
    if (error) {
      setMatchSystemHint(error.message, true);
      return;
    }
    setMatchSystemHint(
      data?.saved_on === false
        ? "Saved — GPSL match system OFF for this window."
        : "Saved — GPSL match system ON for this window."
    );
    await refreshMatchSystemSection({ morph: true });
  });
}

async function refreshSeasonAbsenceSection() {
  const summary = document.getElementById("seasonAbsenceSummary");
  const reqBtn = document.getElementById("requestSeasonAbsenceBtn");
  const retBtn = document.getElementById("returnSeasonAbsenceBtn");
  const { data, error } = await supabase.rpc("owner_club_season_absence_status");
  if (error) {
    if (summary) {
      summary.textContent =
        error.message?.includes("owner_club_season_absence") ||
        error.message?.includes("function")
          ? "Season absence unavailable — admin must run club_season_absence_20261017.sql."
          : error.message;
    }
    reqBtn && (reqBtn.hidden = true);
    retBtn && (retBtn.hidden = true);
    return;
  }

  const cur = data?.current;
  const elig = data?.eligibility;
  if (cur?.status === "active") {
    if (summary) summary.textContent = "Active — finances frozen; fixtures awarded.";
    reqBtn && (reqBtn.hidden = true);
    retBtn && (retBtn.hidden = false);
    setSeasonAbsenceHint("You can return early to unfreeze remaining fixtures.");
  } else if (cur?.status === "requested") {
    if (summary) summary.textContent = "Request pending admin approval.";
    reqBtn && (reqBtn.hidden = true);
    retBtn && (retBtn.hidden = true);
    setSeasonAbsenceHint("Admin will activate from Season Management → Season absence.");
  } else if (elig?.eligible) {
    if (summary) {
      summary.textContent = `Eligible (1 in 4 · window ${elig.window_from}–${elig.window_to}).`;
    }
    reqBtn && (reqBtn.hidden = false);
    retBtn && (retBtn.hidden = true);
    setSeasonAbsenceHint("");
  } else {
    if (summary) {
      summary.textContent = elig?.ok
        ? `Not eligible this window (already used ${elig.used_in_window || 0} in seasons ${elig.window_from}–${elig.window_to}).`
        : "Not available.";
    }
    reqBtn && (reqBtn.hidden = true);
    retBtn && (retBtn.hidden = true);
  }
}

function wireSeasonAbsence() {
  const toggle = document.getElementById("toggleSeasonAbsenceBtn");
  const panel = document.getElementById("seasonAbsenceExpand");
  toggle?.addEventListener("click", () => {
    if (!panel) return;
    const show = panel.hidden;
    panel.hidden = !show;
    toggle.setAttribute("aria-expanded", show ? "true" : "false");
  });

  document.getElementById("requestSeasonAbsenceBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Request season absence?\n\nIf approved: manager released for MV, finances/loans freeze, fixtures awarded. Max 1 season in 4."
      )
    ) {
      return;
    }
    const note = prompt("Optional note for admin") || null;
    const { error } = await supabase.rpc("owner_club_season_absence_request", {
      p_note: note,
    });
    if (error) {
      setSeasonAbsenceHint(error.message, true);
      return;
    }
    setSeasonAbsenceHint("Request submitted — waiting for admin approval.");
    await refreshSeasonAbsenceSection();
  });

  document.getElementById("returnSeasonAbsenceBtn")?.addEventListener("click", async () => {
    if (
      !confirm(
        "Return early from season absence?\n\nAwarded fixtures stay. Remaining fixtures become live. Finances/loans unfreeze from now (no catch-up)."
      )
    ) {
      return;
    }
    const { error } = await supabase.rpc("club_season_absence_return", {
      p_club_short_name: null,
    });
    if (error) {
      setSeasonAbsenceHint(error.message, true);
      return;
    }
    setSeasonAbsenceHint("Season absence ended.");
    await refreshSeasonAbsenceSection();
  });
}

function wireHolidayBooking() {
  const startInput = document.getElementById("holidayStartDate");
  const endInput = document.getElementById("holidayEndDate");
  const bookBtn = document.getElementById("bookHolidayBtn");
  const cancelEditBtn = document.getElementById("cancelHolidayEditBtn");

  const onDateChange = () => updateHolidayDayPreview();
  startInput?.addEventListener("change", onDateChange);
  endInput?.addEventListener("change", onDateChange);

  cancelEditBtn?.addEventListener("click", () => {
    clearHolidayEditMode();
    setHolidayHint("Edit cancelled.");
  });

  bookBtn?.addEventListener("click", async () => {
    const start = startInput?.value;
    const end = endInput?.value;

    if (!start || !end) {
      setHolidayHint("Choose start and end dates.", true);
      return;
    }

    bookBtn.disabled = true;
    const editingId = holidayEditingId;
    const result = editingId
      ? await amendOwnerHoliday(editingId, start, end)
      : await bookOwnerHoliday(start, end);
    bookBtn.disabled = false;

    if (!result.ok) {
      const msg = result.msg || "";
      if (
        msg.includes("club_holiday_book") ||
        msg.includes("club_holiday_amend") ||
        msg.includes("function")
      ) {
        setHolidayHint(
          "Holiday update unavailable. Run supabase/sql/patches/club_holiday_amend_and_admin.sql in Supabase.",
          true
        );
      } else {
        setHolidayHint(msg, true);
      }
      return;
    }

    clearHolidayEditMode();
    setHolidayHint(
      editingId
        ? "Holiday updated."
        : "Holiday booked — overlapping match months unlock for early arrange/play (min 24 squad)."
    );
    await refreshHolidaySection();
  });
}

async function initOwnerDetailsPage() {
  initGpslInfoTips();
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
  await refreshOwnerSupporterBadgeGate();
  await wireOwnerLanguage();

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
  wireMatchSystem();
  wireSeasonAbsence();
  wireAvailabilityPanel();
  await refreshHolidaySection();
  await refreshMatchSystemSection();
  await refreshSeasonAbsenceSection();
}

initOwnerDetailsPage().catch((err) => {
  console.error(err);
  showLoadError(err?.message || "Could not load owner details.");
});
