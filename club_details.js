// Club Details page

import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  loadCurrentSeason,
  loadActiveSeasonRegistrations,
  divisionForClub,
} from "./competition.js";

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
