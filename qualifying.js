import { supabase, initGlobal } from "./global.js?v=20261117-qualifying-gate";
import { getAuthUser } from "./supabase_client.js";
import { mountAvailabilityPanel } from "./owner_availability.js?v=20260930-world-tz";
import {
  ISO_DOW_LABELS,
  loadOnboardingAvailabilityContext,
  saveOnboardingWeeklyAvailability,
  setOnboardingTimezone,
} from "./match_scheduling.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let state = null;
let avail = null;

const RECORDING = [
  "10-minute match, injuries off.",
  "PA3 or PA4 before kick-off. PA1 and PA2 are not allowed. Advanced skill only.",
  "Match-room settings, manager, subtactic, and squad on screen.",
  "Player instructions on screen, and left blank.",
  "Sub tactic and Fluid are a default formation, set before the match. Do not drag players.",
  "Scoreboard and HUD on for the whole match. After the whistle, the ratings and player of the match.",
];

function mixGoldGreen(t) {
  const clamped = Math.max(0, Math.min(1, t));
  const from = [255, 153, 0];
  const to = [62, 207, 110];
  const rgb = from.map((v, i) => Math.round(v + (to[i] - v) * clamped));
  return `rgb(${rgb.join(",")})`;
}

function clock(mins) {
  const h = Math.floor(mins / 60) % 24;
  const m = mins % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

function availabilityLines(ctx) {
  const slots = Array.isArray(ctx?.weekly_slots) ? ctx.weekly_slots : [];
  if (!slots.length) return [];
  const byDay = new Map();
  for (const slot of slots) {
    const dow = Number(slot.iso_dow);
    const start = Number(slot.hour) * 60 + Number(slot.minute);
    if (!dow || Number.isNaN(start)) continue;
    if (!byDay.has(dow)) byDay.set(dow, []);
    byDay.get(dow).push(start);
  }
  const days = [];
  for (let dow = 1; dow <= 7; dow++) {
    const starts = (byDay.get(dow) || []).sort((a, b) => a - b);
    if (!starts.length) continue;
    const ranges = [];
    let from = starts[0];
    let to = starts[0];
    for (let i = 1; i < starts.length; i++) {
      if (starts[i] === to + 30) to = starts[i];
      else {
        ranges.push([from, to + 30]);
        from = to = starts[i];
      }
    }
    ranges.push([from, to + 30]);
    const text = ranges
      .map(([start, end]) => {
        const endLabel = end >= 24 * 60 ? "midnight" : clock(end);
        return `${clock(start)}–${endLabel}`;
      })
      .join(", ");
    days.push({ dow, text });
  }
  const groups = [];
  for (const day of days) {
    const prev = groups[groups.length - 1];
    if (prev && prev.text === day.text && prev.end === day.dow - 1) prev.end = day.dow;
    else groups.push({ start: day.dow, end: day.dow, text: day.text });
  }
  return groups.map((group) => {
    const start = ISO_DOW_LABELS[group.start - 1];
    const end = ISO_DOW_LABELS[group.end - 1];
    const label = group.start === group.end ? start : `${start}–${end}`;
    return `${label} ${group.text}`;
  });
}

function pill(done, locked) {
  if (done) return `<span class="pill">Done</span>`;
  if (locked) return `<span class="pill">Locked</span>`;
  return `<span class="pill">To do</span>`;
}

function render(s) {
  const step1 = Boolean(s.step1_done);
  const step2 = Boolean(s.friendlies_done);
  const approved = Boolean(s.video_approved);
  const open = Boolean(s.video_open);
  const rejected = s.video?.status === "rejected";
  const friendlies = Array.isArray(s.friendlies) ? s.friendlies : [];
  const count = Number(s.friendly_count) || 0;

  const left = Math.max(0, 5 - count);
  const filled = Math.min(count, 5);
  const pips = Array.from({ length: 5 }, (_, i) => {
    if (i >= filled) return `<i></i>`;
    const from = mixGoldGreen(i / 4);
    const to = mixGoldGreen(Math.min(1, (i + 0.85) / 4));
    return `<i class="on" style="--from:${from};--to:${to}"></i>`;
  }).join("");
  const tallyColor = filled ? mixGoldGreen((filled - 0.15) / 4) : "#ffcc66";
  const times = availabilityLines(avail);
  const tz = String(avail?.timezone || "").replace(/_/g, " ");
  const recordingItems = RECORDING.map((line) => `<li>${escapeHtml(line)}</li>`).join("");
  const friendlyItems = friendlies.length
    ? [...friendlies]
        .reverse()
        .map(
          (f) =>
            `<li>${
              f.scoreline
                ? `<span class="score">${escapeHtml(f.scoreline)}</span>`
                : ""
            }${escapeHtml(f.played_on)} · ${escapeHtml(f.opponent)}</li>`
        )
        .join("")
    : `<li class="empty">No results captured yet.</li>`;

  const videoBlock = !step2
    ? ""
    : open
      ? `<p>Code <span class="code">${escapeHtml(s.upload_code)}</span> is with staff. They are ticking the matchday card.</p>`
      : approved
        ? `<p>Approved. You are on the waiting list.</p>`
        : `<p>Film the latest friendly. Put <span class="code">${escapeHtml(s.upload_code)}</span> in the filename and post it in <b>${escapeHtml(s.video_channel)}</b>.</p>
           ${
             rejected
               ? `<p>Last video was sent back.<br>${escapeHtml(s.video?.review_note || "")}</p><p>Play another friendly, log it, and send a new recording with the new code. The five you already logged still count.</p>`
               : ""
           }`;

  const door = !approved
    ? ""
    : s.handpick_club
      ? `<p>You can take <b>${escapeHtml(s.handpick_club)}</b> until ${escapeHtml(
          s.handpick_due_at
            ? new Date(s.handpick_due_at).toLocaleString("en-GB")
            : "the deadline"
        )}. After that the offer closes and you stay on the waiting list.</p>
         <ul class="req">
           <li>You keep the club's cash. The old squad is released.</li>
           <li>In <a href="GPDB.html">GPDB</a>, tick free agents. A tick is not a signing.</li>
           <li><a href="handpick_squad.html">Handpick Squad</a> has to be green.</li>
           <li>In <a href="MGDB.html">MGDB</a>, tick one manager.</li>
           <li>Submit the squad and the manager together. The fees leave when staff approve.</li>
         </ul>`
      : `<p>You are on the waiting list. You do not pick a club.</p>
         <p>An admin will invite you to the club auction, or name the one club you can handpick. A named club stays open for 7 days.</p>
         <p><a href="waiting_list.html">Waiting list</a></p>`;

  const tagShown = String(s.owner_tag || "YOURTAG");
  const tagOk = /^[A-Za-z0-9]{2,32}$/.test(tagShown);
  const pending = Array.isArray(s.pending) ? s.pending : [];
  const pendingItems = pending
    .map(
      (p) =>
        `<li><span class="score">${escapeHtml(p.scoreline || "")}</span></li>`
    )
    .join("");
  const submitted = open || approved;
  const current = !step1 ? 1 : !step2 ? 2 : !submitted ? 3 : !approved ? 4 : 5;
  const stepClass = (n, done, locked) =>
    `step${done ? " done" : ""}${locked ? " locked" : ""}${current === n && !done ? " current" : ""}`;

  document.getElementById("steps").innerHTML = `
    <div class="qual-steps">
    <section class="${stepClass(1, step1, false)}">
      <div class="step-head"><span class="step-no">1</span><h2>Who you are</h2>${pill(step1, false)}</div>
      <div class="step-body">
        <p>Set the tag people will see, and the days and times you can play. Both are required before the friendlies unlock.</p>
        <label>Owner tag
          <input id="tagInput" type="text" maxlength="32" value="${escapeHtml(s.owner_tag || "")}">
        </label>
        ${
          times.length
            ? `<p class="friendly-sub">When you can play${tz ? ` · ${escapeHtml(tz)}` : ""}</p>
               <ul class="avail-summary">${times.map((line) => `<li>${escapeHtml(line)}</li>`).join("")}</ul>`
            : `<p>Times are not saved yet. Set them in the panel under this row.</p>`
        }
      </div>
      <div class="step-actions"><button type="button" class="button" id="saveTagBtn">Save tag</button></div>
    </section>
    <section class="${stepClass(2, step2, !step1)}">
      <div class="step-head"><span class="step-no">2</span><h2>Five friendlies</h2>${pill(step2, !step1)}</div>
      <div class="step-body">
        <div class="friendly-tally" aria-label="${count} registered, ${left} ${left === 1 ? "fixture" : "fixtures"} left">
          <div><b style="color:${tallyColor}">${count}</b><span>registered</span></div>
          <div><b>${left}</b><span>${left === 1 ? "fixture left" : "fixtures left"}</span></div>
        </div>
        <div class="friendly-pips" aria-hidden="true">${pips}</div>
        <p>Post the score in <b>${escapeHtml(s.friendly_channel)}</b> as <span class="code">${escapeHtml(tagShown)} 2 - 1 OTHERTAG</span>, or by tagging the two owners. The other owner posts the same score. It counts when the two posts match.</p>
        ${
          step1 && !tagOk
            ? `<p>The tag in that line has to be letters and numbers only, 2 to 32 characters.</p>`
            : ""
        }
        <p class="friendly-sub">Results</p>
        <ul class="friendly-list">${friendlyItems}</ul>
        ${
          pendingItems
            ? `<p class="friendly-sub">Waiting on the other owner</p><ul class="friendly-list">${pendingItems}</ul>`
            : ""
        }
      </div>
    </section>
    <section class="${stepClass(3, submitted, !step2)}">
      <div class="step-head"><span class="step-no">3</span><h2>Film the latest</h2>${pill(submitted, !step2)}</div>
      <div class="step-body">
        <p>Staff watch the latest friendly only. The other four are not reviewed.</p>
        ${videoBlock}
      </div>
      ${
        step2 && !open && !approved
          ? `<div class="step-actions"><button type="button" class="button" id="submitVideoBtn">I have uploaded this code</button></div>`
          : ""
      }
    </section>
    <section class="${stepClass(4, approved, !step2)}">
      <div class="step-head"><span class="step-no">4</span><h2>The recording</h2>${open && !approved ? `<span class="pill">With staff</span>` : pill(approved, !step2)}</div>
      <div class="step-body">
        <p>Start before the match-room settings and stop after the player ratings.</p>
        <ul class="req">${recordingItems}</ul>
      </div>
    </section>
    <section class="${stepClass(5, approved, !approved)}">
      <div class="step-head"><span class="step-no">5</span><h2>The waiting list</h2>${approved ? `<span class="pill">On the list</span>` : pill(false, !approved)}</div>
      <div class="step-body">
        ${
          approved
            ? door
            : `<p>An approved video puts you on the waiting list. You do not pick a club.</p>
               <p>An admin then opens one door: an invite to the club auction, or one named club to handpick. A named club stays open for 7 days.</p>`
        }
      </div>
    </section>
    </div>
    <section class="qual-avail">
      <h2>When you can play</h2>
      <p>Same step as the tag. Save both before the friendlies unlock.</p>
      <div id="availRoot"></div>
    </section>`;

  document.getElementById("saveTagBtn").onclick = saveTag;
  document.getElementById("submitVideoBtn")?.addEventListener("click", submitVideo);
  mountAvailability();
}

function setStatus(text, ok) {
  const el = document.getElementById("status");
  el.textContent = text || "";
  el.style.color = ok === false ? "#f88" : "#9c9";
}

async function refresh() {
  const { data, error } = await supabase.rpc("owner_qualifying_state");
  if (error) {
    setStatus(error.message, false);
    return;
  }
  state = data;
  try {
    avail = await loadOnboardingAvailabilityContext();
  } catch {
    avail = null;
  }
  if (!data?.subject) {
    document.getElementById("steps").innerHTML =
      `<p>This account joined before qualifying. Use the waiting list.</p><p><a href="waiting_list.html">Waiting list</a></p>`;
    return;
  }
  if (data.video_approved === false && data.subject) {
    /* stay */
  }
  render(data);
}

async function saveTag() {
  const tag = document.getElementById("tagInput")?.value?.trim();
  if (!tag) {
    setStatus("Enter a tag.", false);
    return;
  }
  setStatus("Saving tag…");
  const { error } = await supabase.rpc("owner_registry_set_tag", { p_tag: tag });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus("Tag saved.", true);
  await refresh();
}

async function submitVideo() {
  setStatus("Sending the video to staff…");
  const { error } = await supabase.rpc("owner_qualifying_submit_video");
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus("Staff have the video.", true);
  await refresh();
}

async function mountAvailability() {
  const root = document.getElementById("availRoot");
  if (!root) return;
  await mountAvailabilityPanel(root, {
    loadContext: loadOnboardingAvailabilityContext,
    saveWeekly: async (slots) => {
      const tzSel = document.getElementById("availTimezoneSelect");
      if (tzSel?.value) await setOnboardingTimezone(tzSel.value);
      const res = await saveOnboardingWeeklyAvailability(slots);
      if (res.ok) await refresh();
      return res;
    },
    setTimezone: async (timezone) => {
      const res = await setOnboardingTimezone(timezone);
      if (res.ok) await refresh();
      return res;
    },
    showHolidays: false,
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  await refresh();
});
