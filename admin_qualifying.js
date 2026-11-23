import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const TICKS = [
  ["pa3", "PA3 or PA4"],
  ["advanced", "Advanced skill only"],
  ["matchroom", "Match-room settings clearly shown"],
  ["manager", "Manager clearly shown"],
  ["subtactic", "Subtactic clearly shown"],
  ["fluid", "Fluid formation clearly shown"],
  ["default_formation", "Default formations only"],
  ["squad", "Squad clearly shown"],
  ["no_individual", "No individual player instructions"],
  ["no_drag", "No dragging players on the formation"],
  ["recording", "Recording runs from the settings through to the ratings"],
];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function checklistHtml(id) {
  return TICKS.map(
    ([key, label]) =>
      `<label><input type="checkbox" data-tick="${key}" data-video="${id}"> ${escapeHtml(label)}</label>`
  ).join("");
}

const STAGE_LABEL = {
  who_you_are: "Who you are",
  friendlies: "Five friendlies",
  record: "Record friendly 5",
  with_staff: "With staff",
  waiting_list: "Waiting list",
  handpick: "Handpick",
};

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB");
}

function progressDetail(r) {
  const bits = [];
  const stage = r.stage;
  if (stage === "who_you_are") {
    if (!r.tag_done) bits.push("Tag not set");
    if (!Number(r.availability_slots)) bits.push("Times not set");
  } else if (stage === "friendlies") {
    bits.push(`${Number(r.friendly_count) || 0}/5 friendlies`);
    const due = when(r.friendly_deadline);
    if (due) bits.push(`Friendlies by ${due}`);
  } else if (stage === "record") {
    bits.push("5/5 friendlies");
    if (r.video_status === "rejected") bits.push("Last film sent back");
    const due = when(r.video_deadline);
    if (due) bits.push(`Film by ${due}`);
    if (r.upload_code) bits.push(`Code ${r.upload_code}`);
  } else if (stage === "with_staff") {
    if (r.upload_code) bits.push(`Code ${r.upload_code}`);
    bits.push("Film in for review");
  } else if (stage === "waiting_list") {
    bits.push("Approved");
  } else if (stage === "handpick") {
    if (r.handpick_club) bits.push(r.handpick_club);
    const due = when(r.handpick_due_at);
    if (due) bits.push(`Until ${due}`);
  }
  if (Number(r.reset_count) > 0) bits.push(`Restarted ${Number(r.reset_count)}`);
  return bits.join(" · ");
}

async function loadProgress() {
  const box = document.getElementById("progress");
  if (!box) return { error: null, count: 0 };
  const { data, error } = await supabase.rpc("admin_qualifying_progress");
  if (error) {
    box.innerHTML = `<p class="note">${escapeHtml(error.message)}</p>`;
    return { error, count: 0 };
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = `<p class="note">Nobody is in qualifying.</p>`;
    return { error: null, count: 0 };
  }
  box.innerHTML = `<table class="q-board">
    <thead><tr><th>Owner</th><th>Stage</th><th>Where</th></tr></thead>
    <tbody>${rows
      .map(
        (r) => `<tr>
          <td>${escapeHtml(r.owner_tag || "—")}</td>
          <td><span class="q-stage ${escapeHtml(r.stage)}">${escapeHtml(STAGE_LABEL[r.stage] || r.stage)}</span></td>
          <td>${escapeHtml(progressDetail(r))}</td>
        </tr>`
      )
      .join("")}</tbody>
  </table>`;
  return { error: null, count: rows.length };
}

async function loadQueue() {
  setStatus("status", "Loading…");
  const progress = await loadProgress();
  const { data, error } = await supabase.rpc("admin_qualifying_queue");
  const list = document.getElementById("list");
  if (error) {
    setStatus("status", error.message, false);
    list.innerHTML = "";
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    list.innerHTML = `<p class="note">No qualifying videos waiting.</p>`;
    const progressNote = progress.error
      ? ""
      : progress.count
        ? `${progress.count} in qualifying.`
        : "";
    setStatus("status", progressNote, true);
    return;
  }
  list.innerHTML = rows
    .map((r) => {
      const open = r.status === "submitted";
      const due = r.handpick_due_at
        ? new Date(r.handpick_due_at).toLocaleString("en-GB")
        : "";
      return `<article class="q-card" data-id="${r.id}">
        <h3>${escapeHtml(r.owner_tag || "New member")} · ${escapeHtml(r.upload_code)}</h3>
        <p class="note">${escapeHtml(r.status)} · ${Number(r.friendly_count) || 0} friendlies logged · ${escapeHtml(
          new Date(r.created_at).toLocaleString("en-GB")
        )}${r.handpick_club ? ` · handpick ${escapeHtml(r.handpick_club)} until ${escapeHtml(due)}` : ""}</p>
        ${
          /^https:\/\//i.test(String(r.video_url || ""))
            ? `<p><a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener">Open recording</a></p>`
            : ""
        }
        ${
          open
            ? `${checklistHtml(r.id)}
               <label>Note <input type="text" data-note="${r.id}" maxlength="400"></label>
               <div class="q-actions">
                 <button type="button" class="button" data-approve="${r.id}">Approve</button>
                 <button type="button" class="button secondary" data-reject="${r.id}">Send back</button>
               </div>`
            : `<div class="q-actions">
                 <input type="text" data-club="${r.owner_id}" maxlength="8" placeholder="Club short name" value="${escapeHtml(r.handpick_club || "")}">
                 <button type="button" class="button" data-grant="${r.owner_id}">Name this club for handpick</button>
               </div>`
        }
      </article>`;
    })
    .join("");

  list.querySelectorAll("[data-approve]").forEach((btn) => {
    btn.onclick = () => review(Number(btn.getAttribute("data-approve")), "approve");
  });
  list.querySelectorAll("[data-reject]").forEach((btn) => {
    btn.onclick = () => review(Number(btn.getAttribute("data-reject")), "reject");
  });
  list.querySelectorAll("[data-grant]").forEach((btn) => {
    btn.onclick = () => grant(btn.getAttribute("data-grant"));
  });
  const progressNote = progress.error
    ? ""
    : progress.count
      ? `${progress.count} in qualifying. `
      : "";
  setStatus("status", `${progressNote}${rows.length} recording${rows.length === 1 ? "" : "s"} on the list`, true);
}

function ticksFor(id) {
  const checklist = {};
  for (const [key] of TICKS) {
    const box = document.querySelector(`[data-tick="${key}"][data-video="${id}"]`);
    checklist[key] = Boolean(box?.checked);
  }
  return checklist;
}

async function review(id, action) {
  const note = document.querySelector(`[data-note="${id}"]`)?.value || null;
  setStatus("status", action === "approve" ? "Approving…" : "Sending back…");
  const { error } = await supabase.rpc("admin_qualifying_review", {
    p_video_id: id,
    p_action: action,
    p_checklist: ticksFor(id),
    p_note: note,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  await loadQueue();
}

async function grant(ownerId) {
  const club = document.querySelector(`[data-club="${ownerId}"]`)?.value || "";
  setStatus("status", "Naming the club…");
  const { data, error } = await supabase.rpc("admin_qualifying_grant_handpick", {
    p_owner_id: ownerId,
    p_club: club,
  });
  if (error) {
    setStatus("status", error.message, false);
    return;
  }
  setStatus("status", `${data.club_name || data.club} named for 7 days.`, true);
  await loadQueue();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  await loadQueue();
});
