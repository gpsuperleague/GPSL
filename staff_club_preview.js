/**
 * Staff (Admin/Mod) club preview helpers — shared pattern with finances.
 * URL: ?club=SHORT  · sessionStorage key per feature.
 */
import {
  supabase,
  isGpslAdminUser,
  fetchIsGpslModUser,
} from "./global.js";

export async function canStaffPreviewClub(user) {
  if (!user) return false;
  if (isGpslAdminUser(user)) return true;
  return (await fetchIsGpslModUser(true)) === true;
}

/**
 * @param {object} user
 * @param {string} sessionKey e.g. gpsl_admin_squad_club
 */
export async function resolveStaffClubContext(user, sessionKey) {
  const params = new URLSearchParams(window.location.search);
  const clubParam = (params.get("club") || "").trim().toUpperCase() || null;

  const { data: owned } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  const ownedShort = owned?.ShortName || null;
  const staff = await canStaffPreviewClub(user);

  if (staff) {
    const saved =
      (sessionStorage.getItem(sessionKey) || "").trim().toUpperCase() || null;
    const shortName = clubParam || ownedShort || saved || null;

    if (!shortName) {
      return {
        shortName: null,
        clubLabel: null,
        adminPreview: true,
        needsAdminPicker: true,
        staffPicker: true,
        ownedShort,
        ownedLabel: owned?.Club || null,
      };
    }

    if (clubParam || !ownedShort) {
      sessionStorage.setItem(sessionKey, shortName);
    }

    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("Club")
      .eq("ShortName", shortName)
      .maybeSingle();

    const viewingOwn = ownedShort && shortName === ownedShort && !clubParam;

    return {
      shortName,
      clubLabel: clubRow?.Club || shortName,
      adminPreview: !viewingOwn,
      staffPicker: true,
      ownedShort,
      ownedLabel: owned?.Club || null,
    };
  }

  if (ownedShort) {
    return {
      shortName: ownedShort,
      clubLabel: owned.Club,
      adminPreview: false,
      staffPicker: false,
      ownedShort,
      ownedLabel: owned.Club,
    };
  }

  return {
    shortName: null,
    clubLabel: null,
    adminPreview: false,
    noClub: true,
    staffPicker: false,
  };
}

/**
 * @param {object} opts
 * @param {string} opts.sessionKey
 * @param {string} [opts.hostId]
 * @param {string} [opts.label]
 * @param {string} [opts.hint]
 * @param {string} [opts.selectId]
 * @param {string|null} [opts.selectedShort]
 * @param {string|null} [opts.ownedShort]
 * @param {string|null} [opts.ownedLabel]
 */
export async function mountStaffClubPicker(opts = {}) {
  const {
    sessionKey,
    hostId = "staffClubPickerHost",
    label: labelText = "Preview club: ",
    hint:
      hintText = "Admin/Mod only — pick any club to view (read-only when not your club).",
    selectId = "staffClubSelect",
    selectedShort = null,
    ownedShort = null,
    ownedLabel = null,
  } = opts;

  if (!sessionKey) return null;

  const host =
    document.getElementById(hostId) || document.getElementById("pageMeta");
  if (!host) return null;

  const { data: clubs, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error || !clubs?.length) {
    host.textContent = "Staff preview — could not load club list.";
    return null;
  }

  host.replaceChildren();

  const wrap = document.createElement("div");
  wrap.className = "staff-club-picker";
  wrap.style.cssText =
    "margin:12px 20px 0;padding:10px 12px;background:#222;border:1px solid #444;border-radius:6px;font-size:13px;";

  const label = document.createElement("label");
  label.htmlFor = selectId;
  label.textContent = labelText;
  label.style.marginRight = "8px";

  const select = document.createElement("select");
  select.id = selectId;
  select.style.cssText =
    "padding:6px 8px;background:#111;border:1px solid #555;color:#ddd;border-radius:4px;min-width:260px;max-width:100%;";

  if (ownedShort) {
    const ownOpt = document.createElement("option");
    ownOpt.value = "__own__";
    ownOpt.textContent = `My club — ${ownedLabel || ownedShort} (${ownedShort})`;
    select.appendChild(ownOpt);
  }

  for (const c of clubs) {
    const opt = document.createElement("option");
    opt.value = c.ShortName;
    opt.textContent = `${c.Club || c.ShortName} (${c.ShortName})`;
    select.appendChild(opt);
  }

  const params = new URLSearchParams(window.location.search);
  const clubParam = (params.get("club") || "").trim().toUpperCase() || null;
  const preferred =
    (selectedShort || "").toUpperCase() ||
    clubParam ||
    (sessionStorage.getItem(sessionKey) || "").toUpperCase() ||
    null;

  if (!clubParam && ownedShort && (!preferred || preferred === ownedShort)) {
    select.value = "__own__";
  } else if (preferred && [...select.options].some((o) => o.value === preferred)) {
    select.value = preferred;
  } else if (ownedShort) {
    select.value = "__own__";
  }

  const hint = document.createElement("div");
  hint.style.cssText = "margin-top:6px;color:#888;font-size:12px;line-height:1.35;";
  hint.textContent = hintText;

  wrap.appendChild(label);
  wrap.appendChild(select);
  wrap.appendChild(hint);
  host.appendChild(wrap);

  select.addEventListener("change", () => {
    const url = new URL(window.location.href);
    if (select.value === "__own__") {
      sessionStorage.removeItem(sessionKey);
      url.searchParams.delete("club");
    } else {
      sessionStorage.setItem(sessionKey, select.value);
      url.searchParams.set("club", select.value);
    }
    window.location.href = url.toString();
  });

  return select;
}
