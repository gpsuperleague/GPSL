// Club Details page — owner Discord tag (Clubs.Owner)

import { formatNationLabel } from "./squad_rules.js";

const MAX_OWNER_TAG_LEN = 64;

export function normalizeOwnerTagInput(raw) {
  return String(raw ?? "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, MAX_OWNER_TAG_LEN);
}

/**
 * @param {object} els — { input, editBtn, saveBtn, hint }
 * @param {string|null} storedTag — Clubs.Owner
 */
export function initOwnerTagField(els, storedTag) {
  const locked = Boolean(storedTag && String(storedTag).trim());
  els.input.value = locked ? String(storedTag).trim() : "";
  setOwnerTagMode(els, locked ? "locked" : "empty");
}

export function setOwnerTagMode(els, mode) {
  const { input, editBtn, saveBtn, hint } = els;

  if (mode === "empty") {
    input.disabled = false;
    input.placeholder = "Discord username";
    editBtn.style.display = "none";
    saveBtn.style.display = "inline-block";
    hint.textContent =
      "Matches your Discord name. Save to lock it in — use Edit later to change.";
    return;
  }

  if (mode === "locked") {
    input.disabled = true;
    editBtn.style.display = "inline-block";
    saveBtn.style.display = "none";
    hint.textContent = "Locked in. Click Edit to change, then Save.";
    return;
  }

  if (mode === "editing") {
    input.disabled = false;
    editBtn.style.display = "none";
    saveBtn.style.display = "inline-block";
    hint.textContent = "Save to confirm your updated Discord tag.";
  }
}

export async function saveOwnerTag(supabase, tag) {
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

export function wireOwnerTagField(supabase, els, getStoredTag, onSaved) {
  els.editBtn.addEventListener("click", () => {
    setOwnerTagMode(els, "editing");
    els.input.focus();
    els.input.select();
  });

  els.saveBtn.addEventListener("click", async () => {
    els.saveBtn.disabled = true;
    const result = await saveOwnerTag(supabase, els.input.value);
    els.saveBtn.disabled = false;

    if (!result.ok) {
      els.hint.textContent = result.msg;
      els.hint.classList.add("owner-tag-hint--error");
      return;
    }

    els.hint.classList.remove("owner-tag-hint--error");
    els.input.value = result.tag;
    setOwnerTagMode(els, "locked");
    onSaved?.(result.tag);
  });
}

export function formatClubNationDisplay(nation) {
  if (!nation || !String(nation).trim()) return "—";
  return formatNationLabel(nation);
}
