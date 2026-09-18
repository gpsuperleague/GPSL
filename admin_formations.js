import { initAdminPage, setStatus as setChromeStatus, supabase } from "./admin_common.js";
import { GPSL_POSITIONS } from "./gpsl_formations.js";

let formations = [];
let positions = [...GPSL_POSITIONS];
let selectedId = null;

function setStatus(msg, ok = true) {
  const el = document.getElementById("status");
  if (el) {
    el.textContent = msg || "";
    el.classList.toggle("err", !ok);
  }
  setChromeStatus("status", msg || "", ok);
}

function emptySlots() {
  const keys = ["GK", "LB", "CB1", "CB2", "RB", "LMF", "CMF", "RMF", "LWF", "CF", "RWF"];
  const defaults = ["GK", "LB", "CB", "CB", "RB", "CMF", "CMF", "CMF", "LWF", "CF", "RWF"];
  const xs = [50, 12, 36, 64, 88, 16, 50, 84, 22, 50, 78];
  const ys = [86, 68, 72, 72, 68, 48, 52, 48, 22, 12, 22];
  return keys.map((slot_key, i) => ({
    slot_key,
    default_position: defaults[i],
    x: xs[i],
    y: ys[i],
    sort_order: i,
    allow_relabel: true,
    allowed_positions: [defaults[i]],
  }));
}

function selectedFormation() {
  return formations.find((f) => f.id === selectedId) || null;
}

function escapeAttr(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

function posChecksHtml(defaultPos, selected) {
  const def = String(defaultPos || "").toUpperCase();
  const allowed = new Set((selected || []).map((p) => String(p).toUpperCase()));
  allowed.add(def);
  return `<div class="fm-pos-grid">${positions
    .filter((p) => (def === "GK" ? p === "GK" : p !== "GK"))
    .map(
      (p) =>
        `<label><input type="checkbox" data-pos="${p}" ${
          allowed.has(p) ? "checked" : ""
        } ${p === def ? "disabled" : ""}>${p}</label>`
    )
    .join("")}</div>`;
}

function renderList() {
  const ul = document.getElementById("formationList");
  if (!ul) return;
  ul.innerHTML = "";
  const sorted = [...formations].sort(
    (a, b) =>
      (a.sort_order ?? 0) - (b.sort_order ?? 0) ||
      String(a.name).localeCompare(String(b.name))
  );
  for (const f of sorted) {
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.type = "button";
    if (f.id === selectedId) btn.classList.add("active");
    if (!f.is_enabled) btn.classList.add("off");
    btn.textContent = `${f.code} — ${f.name}${f.is_enabled ? "" : " (off)"}`;
    btn.addEventListener("click", () => {
      selectedId = f.id;
      fillEditor(f);
      renderList();
    });
    li.appendChild(btn);
    ul.appendChild(li);
  }
}

function renderSlots(slots) {
  const body = document.getElementById("slotsBody");
  if (!body) return;
  const rows = slots?.length ? slots : emptySlots();
  body.innerHTML = rows
    .map((s, idx) => {
      const def = s.default_position || "CMF";
      return `<tr data-idx="${idx}">
        <td><input class="slot-key" value="${escapeAttr(
          s.slot_key || ""
        )}" style="width:70px"></td>
        <td>
          <select class="slot-default">
            ${positions
              .map(
                (p) =>
                  `<option value="${p}" ${p === def ? "selected" : ""}>${p}</option>`
              )
              .join("")}
          </select>
        </td>
        <td><input class="slot-x" type="number" min="0" max="100" step="0.1" value="${Number(
          s.x ?? 50
        )}"></td>
        <td><input class="slot-y" type="number" min="0" max="100" step="0.1" value="${Number(
          s.y ?? 50
        )}"></td>
        <td style="text-align:center"><input class="slot-allow" type="checkbox" ${
          s.allow_relabel ? "checked" : ""
        }></td>
        <td class="slot-allowed">${posChecksHtml(def, s.allowed_positions)}</td>
      </tr>`;
    })
    .join("");

  body.querySelectorAll(".slot-default").forEach((sel) => {
    sel.addEventListener("change", () => {
      const tr = sel.closest("tr");
      const box = tr?.querySelector(".slot-allowed");
      if (box) box.innerHTML = posChecksHtml(sel.value, [sel.value]);
    });
  });
}

function fillEditor(f) {
  document.getElementById("code").value = f?.code || "";
  document.getElementById("name").value = f?.name || "";
  document.getElementById("group_label").value = f?.group_label || "Back-4";
  document.getElementById("sort_order").value =
    f?.sort_order != null ? f.sort_order : 0;
  document.getElementById("is_enabled").checked = f?.is_enabled !== false;
  document.getElementById("description").value = f?.description || "";
  renderSlots(f?.slots || emptySlots());
}

function readSlotsFromDom() {
  return [...document.querySelectorAll("#slotsBody tr")].map((tr, i) => {
    const def = tr.querySelector(".slot-default")?.value || "CMF";
    const allow = !!tr.querySelector(".slot-allow")?.checked;
    const extras = [
      ...tr.querySelectorAll(".slot-allowed input[data-pos]:checked"),
    ]
      .map((el) => el.getAttribute("data-pos"))
      .filter((p) => p && p !== def);
    const allowed = [def, ...extras];
    return {
      slot_key: (tr.querySelector(".slot-key")?.value || `S${i}`).trim(),
      default_position: def,
      x: Number(tr.querySelector(".slot-x")?.value || 50),
      y: Number(tr.querySelector(".slot-y")?.value || 50),
      sort_order: i,
      allow_relabel: allow,
      allowed_positions: allow ? allowed : [def],
    };
  });
}

function countCfSs(slots) {
  return slots.filter((s) =>
    ["CF", "SS"].includes(String(s.default_position || "").toUpperCase())
  ).length;
}

async function loadAll() {
  setStatus("Loading formations…");
  const { data, error } = await supabase.rpc("gpsl_formations_list", {
    p_enabled_only: false,
  });
  if (error) {
    setStatus(
      `Could not load catalogue. Run gpsl_formations_catalogue_20260918.sql — ${error.message}`,
      false
    );
    return;
  }
  formations = data?.formations || [];
  positions = Array.isArray(data?.positions) ? data.positions : [...GPSL_POSITIONS];
  const s = data?.settings || {};
  document.getElementById("catalogue_live").checked = !!s.catalogue_live;
  document.getElementById("enforce_mirroring").checked = !!s.enforce_mirroring;
  document.getElementById("max_cf_ss").value =
    s.max_cf_ss != null ? s.max_cf_ss : 2;

  if (!selectedId && formations[0]) selectedId = formations[0].id;
  if (selectedId && !formations.some((f) => f.id === selectedId)) {
    selectedId = formations[0]?.id || null;
  }
  renderList();
  fillEditor(selectedFormation() || { slots: emptySlots() });
  setStatus(
    `Loaded ${formations.length} formation(s). Catalogue live: ${
      s.catalogue_live ? "yes" : "no"
    }.`
  );
}

async function saveSettings() {
  const { error } = await supabase.rpc("gpsl_formation_set_settings", {
    p_catalogue_live: document.getElementById("catalogue_live").checked,
    p_enforce_mirroring: document.getElementById("enforce_mirroring").checked,
    p_max_cf_ss: Number(document.getElementById("max_cf_ss").value || 2),
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus("Settings saved.");
  await loadAll();
}

async function saveFormation({ asNew = false } = {}) {
  const slots = readSlotsFromDom();
  if (slots.length !== 11) {
    setStatus("Need exactly 11 slots.", false);
    return;
  }
  const maxCf = Number(document.getElementById("max_cf_ss").value || 2);
  if (countCfSs(slots) > maxCf) {
    setStatus("CF + SS combined exceeds the league max (no CF/CF/SS).", false);
    return;
  }
  const code = document.getElementById("code").value.trim();
  const name = document.getElementById("name").value.trim();
  if (!code || !name) {
    setStatus("Code and name are required.", false);
    return;
  }

  setStatus("Saving…");
  const { data, error } = await supabase.rpc("gpsl_formation_upsert", {
    p_code: code,
    p_name: name,
    p_description: document.getElementById("description").value.trim(),
    p_group_label: document.getElementById("group_label").value.trim() || "General",
    p_is_enabled: document.getElementById("is_enabled").checked,
    p_sort_order: Number(document.getElementById("sort_order").value || 0),
    p_slots: slots,
    p_source: "admin",
    p_id: asNew ? null : selectedId,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  selectedId = data || selectedId;
  setStatus("Formation saved.");
  await loadAll();
}

async function deleteFormation() {
  if (!selectedId) {
    setStatus("Nothing selected.", false);
    return;
  }
  if (!confirm("Delete this formation?")) return;
  const { error } = await supabase.rpc("gpsl_formation_delete", {
    p_id: selectedId,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  selectedId = null;
  setStatus("Deleted.");
  await loadAll();
}

function newFormation() {
  selectedId = null;
  fillEditor({
    code: "",
    name: "",
    group_label: "Back-4",
    sort_order: (formations.length + 1) * 10,
    is_enabled: true,
    description: "",
    slots: emptySlots(),
  });
  renderList();
  setStatus("New formation — set code/name, adjust slots, then Save.");
}

function duplicateFormation() {
  const f = selectedFormation();
  if (!f) {
    setStatus("Select a formation to duplicate.", false);
    return;
  }
  selectedId = null;
  fillEditor({
    ...f,
    id: null,
    code: `${f.code}-copy`,
    name: `${f.name} (copy)`,
  });
  renderList();
  setStatus("Duplicated in editor — change the code and Save.");
}

await initAdminPage();
document.getElementById("reloadBtn")?.addEventListener("click", () => loadAll());
document.getElementById("newBtn")?.addEventListener("click", newFormation);
document.getElementById("saveBtn")?.addEventListener("click", () => saveFormation());
document.getElementById("dupBtn")?.addEventListener("click", duplicateFormation);
document.getElementById("deleteBtn")?.addEventListener("click", deleteFormation);
document.getElementById("saveSettingsBtn")?.addEventListener("click", saveSettings);
await loadAll();
