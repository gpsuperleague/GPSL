import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { getUKWallClockParts, ukLocalToInstant } from "./global.js";

primeAdminPageChrome();

const AUCTION_KINDS = new Set(["player_draft", "manager_draft", "club_auction"]);
const KIND_LABELS = {
  player_draft: "Player draft",
  manager_draft: "Manager draft",
  club_auction: "Club auction",
  challenge: "Challenge",
  announcement: "Announcement",
  deadline: "Deadline",
  other: "Other",
};
const DEFAULT_LINKS = {
  player_draft: "draftauction.html",
  manager_draft: "manager_draftauction.html",
  club_auction: "club_auction.html",
  challenge: "challenges.html",
};

let events = [];

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const pad = (n) => String(n).padStart(2, "0");

/** datetime-local value (UK wall clock) → ISO instant */
function ukInputToIso(value) {
  const m = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
  if (!m) return null;
  return ukLocalToInstant(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], 0).toISOString();
}

/** ISO instant → datetime-local value in UK wall clock */
function isoToUkInput(iso) {
  if (!iso) return "";
  const p = getUKWallClockParts(new Date(iso));
  return `${p.year}-${pad(p.month + 1)}-${pad(p.day)}T${pad(p.hour)}:${pad(p.minute)}`;
}

function formatUk(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function nextThursday1900Input() {
  const p = getUKWallClockParts(new Date());
  const today = new Date(Date.UTC(p.year, p.month, p.day));
  let add = (4 - today.getUTCDay() + 7) % 7;
  if (add === 0 && (p.hour > 19 || (p.hour === 19 && p.minute > 0))) add = 7;
  today.setUTCDate(today.getUTCDate() + add);
  return `${today.getUTCFullYear()}-${pad(today.getUTCMonth() + 1)}-${pad(today.getUTCDate())}T19:00`;
}

function syncAutoBox() {
  const kind = document.getElementById("epKind").value;
  const box = document.getElementById("epAutoBox");
  box.hidden = !AUCTION_KINDS.has(kind);
  document.getElementById("epSeedWrap").hidden = kind !== "club_auction";
}

function clearForm() {
  document.getElementById("epId").value = "";
  document.getElementById("epKind").value = "player_draft";
  document.getElementById("epTitle").value = "";
  document.getElementById("epStart").value = "";
  document.getElementById("epEnd").value = "";
  document.getElementById("epDetail").value = "";
  document.getElementById("epLink").value = "";
  document.getElementById("epVisible").checked = true;
  document.getElementById("epAuto").checked = false;
  document.getElementById("epArmHours").value = "24";
  document.getElementById("epSeed").checked = true;
  document.getElementById("epFormTitle").textContent = "Add event";
  syncAutoBox();
}

function fillForm(ev) {
  document.getElementById("epId").value = ev.id;
  document.getElementById("epKind").value = ev.kind;
  document.getElementById("epTitle").value = ev.title || "";
  document.getElementById("epStart").value = isoToUkInput(ev.starts_at);
  document.getElementById("epEnd").value = isoToUkInput(ev.ends_at);
  document.getElementById("epDetail").value = ev.detail || "";
  document.getElementById("epLink").value = ev.link_href || "";
  document.getElementById("epVisible").checked = ev.visible !== false;
  document.getElementById("epAuto").checked = !!ev.auto_start;
  document.getElementById("epArmHours").value = String(ev.arm_hours_before ?? 24);
  document.getElementById("epSeed").checked = ev.seed_club_listings !== false;
  document.getElementById("epFormTitle").textContent = `Edit event #${ev.id}`;
  syncAutoBox();
  document.getElementById("epFormTitle").scrollIntoView({ behavior: "smooth", block: "start" });
}

function statusCell(ev) {
  if (!ev.auto_start) return `<span class="ep-status">Calendar only</span>`;
  const res = ev.auto_result || {};
  if (ev.auto_status === "pending") {
    if (res.waiting) {
      return `<span class="ep-status ep-status-pending">⏳ ${escapeHtml(res.reason || "Waiting for previous auction")} — will switch on once it settles</span>`;
    }
    const armAt = new Date(new Date(ev.starts_at).getTime() - (ev.arm_hours_before || 0) * 3600_000);
    return `<span class="ep-status ep-status-pending">Auto-start pending — switches on ${escapeHtml(formatUk(armAt.toISOString()))}</span>`;
  }
  if (ev.auto_status === "armed") {
    const seed = res.seed?.inserted != null ? ` · ${res.seed.inserted} listings seeded` : res.seed?.error ? ` · seed failed: ${res.seed.error}` : "";
    return `<span class="ep-status ep-status-armed">✓ Switched on ${escapeHtml(formatUk(ev.auto_ran_at))}${escapeHtml(seed)}</span>`;
  }
  if (ev.auto_status === "failed") {
    return `<span class="ep-status ep-status-failed">✕ ${escapeHtml(res.reason || "Failed")}</span>`;
  }
  return `<span class="ep-status">${escapeHtml(ev.auto_status)}</span>`;
}

function renderList() {
  const showPast = document.getElementById("epShowPast").checked;
  const now = Date.now();
  const rows = events.filter((ev) => {
    const end = new Date(ev.ends_at || ev.starts_at).getTime();
    return showPast || end >= now - 24 * 3600_000;
  });
  const list = document.getElementById("epList");
  if (!rows.length) {
    list.innerHTML = `<p class="note">No upcoming events. Add one above.</p>`;
    return;
  }
  list.innerHTML = `
    <table class="ep-table">
      <thead><tr><th>When (UK)</th><th>Type</th><th>Event</th><th>Auto-start</th><th></th></tr></thead>
      <tbody>
        ${rows
          .map((ev) => {
            const past = new Date(ev.ends_at || ev.starts_at).getTime() < now;
            const kindCls = AUCTION_KINDS.has(ev.kind) ? "ep-kind-auction" : ev.kind === "challenge" ? "ep-kind-challenge" : "";
            const canArm = ev.auto_start && ev.auto_status !== "armed" && !past;
            return `<tr class="${past ? "ep-past" : ""}">
              <td>${escapeHtml(formatUk(ev.starts_at))}${ev.ends_at ? `<br><span class="ep-hidden-tag">→ ${escapeHtml(formatUk(ev.ends_at))}</span>` : ""}</td>
              <td><span class="ep-kind ${kindCls}">${escapeHtml(KIND_LABELS[ev.kind] || ev.kind)}</span></td>
              <td><b>${escapeHtml(ev.title)}</b>${ev.visible ? "" : ` <span class="ep-hidden-tag">(hidden from owners)</span>`}${
                ev.detail ? `<br><span class="ep-hidden-tag">${escapeHtml(ev.detail)}</span>` : ""
              }</td>
              <td>${statusCell(ev)}</td>
              <td><div class="ep-actions">
                <button type="button" class="button" data-ep-edit="${ev.id}">Edit</button>
                ${canArm ? `<button type="button" class="button" data-ep-arm="${ev.id}" style="background:#664422;">Switch on now</button>` : ""}
                <button type="button" class="button" data-ep-del="${ev.id}" style="background:#633;">Delete</button>
              </div></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  list.querySelectorAll("[data-ep-edit]").forEach((btn) => {
    btn.onclick = () => {
      const ev = events.find((e) => String(e.id) === btn.dataset.epEdit);
      if (ev) fillForm(ev);
    };
  });
  list.querySelectorAll("[data-ep-del]").forEach((btn) => {
    btn.onclick = () => deleteEvent(Number(btn.dataset.epDel));
  });
  list.querySelectorAll("[data-ep-arm]").forEach((btn) => {
    btn.onclick = () => armNow(Number(btn.dataset.epArm));
  });
}

async function loadEvents() {
  const { data, error } = await supabase
    .from("gpsl_planned_events")
    .select("*")
    .order("starts_at", { ascending: true });
  if (error) {
    setStatus("epStatus", `❌ ${error.message} — run patches/gpsl_events_planner_20260929.sql`, false);
    events = [];
  } else {
    events = data || [];
  }
  renderList();
}

async function saveEvent() {
  const kind = document.getElementById("epKind").value;
  const title = document.getElementById("epTitle").value.trim() || KIND_LABELS[kind];
  const startsIso = ukInputToIso(document.getElementById("epStart").value);
  const endsIso = ukInputToIso(document.getElementById("epEnd").value);
  if (!startsIso) {
    setStatus("epStatus", "Pick a start date and time.", false);
    return;
  }
  const auto = AUCTION_KINDS.has(kind) && document.getElementById("epAuto").checked;
  const armHours = Number(document.getElementById("epArmHours").value) || 0;
  if (auto) {
    const armAt = new Date(new Date(startsIso).getTime() - armHours * 3600_000);
    const msg =
      `Auto-start ${KIND_LABELS[kind]}\n\n` +
      `Opens: ${formatUk(startsIso)} UK\n` +
      `Switched on & announced: ${armAt <= new Date() ? "straight away" : formatUk(armAt.toISOString()) + " UK"}\n` +
      `Closes: secret time the next evening\n\nSave?`;
    if (!confirm(msg)) return;
  }
  const payload = {
    id: document.getElementById("epId").value || null,
    kind,
    title,
    starts_at: startsIso,
    ends_at: endsIso,
    detail: document.getElementById("epDetail").value,
    link_href: document.getElementById("epLink").value.trim() || DEFAULT_LINKS[kind] || "",
    visible: document.getElementById("epVisible").checked,
    auto_start: auto,
    arm_hours_before: armHours,
    seed_club_listings: document.getElementById("epSeed").checked,
  };
  setStatus("epStatus", "Saving…");
  const { data, error } = await supabase.rpc("admin_planned_event_save", { p_event: payload });
  if (error) {
    setStatus("epStatus", `❌ ${error.message}`, false);
    return;
  }
  const armed = data?.auto_status === "armed";
  setStatus(
    "epStatus",
    armed ? "✅ Saved and switched on (inside the announce window)." : "✅ Saved.",
    true
  );
  clearForm();
  await loadEvents();
}

async function deleteEvent(id) {
  const ev = events.find((e) => e.id === id);
  const armedNote =
    ev?.auto_status === "armed"
      ? "\n\nThis auction has already been switched on — deleting the event does NOT switch it off (use Admin → Transfers)."
      : "";
  if (!confirm(`Delete "${ev?.title || id}"?${armedNote}`)) return;
  const { error } = await supabase.rpc("admin_planned_event_delete", { p_id: id });
  if (error) {
    setStatus("epStatus", `❌ ${error.message}`, false);
    return;
  }
  setStatus("epStatus", "Deleted.", true);
  await loadEvents();
}

async function armNow(id) {
  const ev = events.find((e) => e.id === id);
  if (!confirm(`Switch on "${ev?.title}" now?\n\nOwners are notified straight away; bidding still opens at ${formatUk(ev?.starts_at)} UK.`)) return;
  const { data, error } = await supabase.rpc("admin_planned_event_arm_now", { p_id: id });
  if (error || !data?.ok) {
    setStatus("epStatus", `❌ ${error?.message || data?.reason || "Failed"}`, false);
  } else {
    setStatus("epStatus", `✅ ${data.armed} switched on — opens ${data.opens_uk} UK.`, true);
  }
  await loadEvents();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("epKind").addEventListener("change", () => {
    syncAutoBox();
    const kind = document.getElementById("epKind").value;
    const title = document.getElementById("epTitle");
    if (!title.value.trim() || Object.values(KIND_LABELS).includes(title.value.trim())) {
      title.value = KIND_LABELS[kind] || "";
    }
  });
  document.getElementById("epSaveBtn").onclick = saveEvent;
  document.getElementById("epClearBtn").onclick = () => {
    clearForm();
    setStatus("epStatus", "");
  };
  document.getElementById("epSuggestBtn").onclick = () => {
    document.getElementById("epStart").value = nextThursday1900Input();
  };
  document.getElementById("epShowPast").onchange = renderList;
  clearForm();
  document.getElementById("epTitle").value = KIND_LABELS.player_draft;
  await loadEvents();
});
