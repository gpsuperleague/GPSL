import { supabase, initGlobal } from "./global.js?v=20261117-qualifying-link";
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

function formatWhen(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

let state = null;
let avail = null;
let intakeMode = "pre_season";
let vacantClaim = null;

const RECORDING = [
  "PA3 or PA4",
  "Advanced skill only",
  "Match-room settings shown",
  "Manager shown",
  "Subtactic shown",
  "Fluid formation shown",
  "Squad shown",
  "No individual player instructions",
  "No dragging players on the formation",
  "Recording runs from the settings through to the ratings",
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
    const on = i < filled;
    const style = on
      ? ` style="--from:${mixGoldGreen(i / 4)};--to:${mixGoldGreen(Math.min(1, (i + 0.85) / 4))}"`
      : "";
    const film = i === 4;
    return `<span class="pip${film ? " film" : ""}"><i class="${on ? "on" : ""}"${style}></i>${
      film ? "<em>Film</em>" : ""
    }</span>`;
  }).join("");
  const tallyColor = filled ? mixGoldGreen((filled - 0.15) / 4) : "#ffcc66";
  const times = availabilityLines(avail);
  const tz = String(avail?.timezone || "").replace(/_/g, " ");
  const recordingItems = RECORDING.map((line) => `<li>${escapeHtml(line)}</li>`).join("");
  const ordered = friendlies.slice(0, 5);
  const fifth = ordered[4] || null;
  const recordReady = Boolean(fifth);
  const recordCallout = recordReady
    ? `<p class="record-target"><span>Qualifying match 5</span><b>${escapeHtml(
        fifth.scoreline || `${fifth.played_on} · ${fifth.opponent}`
      )}</b></p>`
    : `<p class="record-target"><span>Qualifying match 5</span><b>${
        count
          ? `${left} still to play. The recording stays on match 5.`
          : "This slot is the one you film. The result appears here when it is registered."
      }</b></p>`;
  const friendlyItems = Array.from({ length: 5 }, (_, i) => {
    const match = ordered[i];
    const film = i === 4;
    const head = `<span class="slot-label">Qualifying match ${i + 1}${
      film ? `<span class="record-flag">Record this</span>` : ""
    }</span>`;
    if (!match) {
      return `<li class="match-slot${film ? " film-slot" : ""}">${head}<span class="slot-empty">Waiting for the result</span></li>`;
    }
    return `<li class="match-slot${film ? " film-slot" : ""}">${head}${
      match.scoreline ? `<span class="score">${escapeHtml(match.scoreline)}</span>` : ""
    }${escapeHtml(match.played_on)} · ${escapeHtml(match.opponent)}</li>`;
  }).join("");

  const videoHref = /^https:\/\//i.test(String(s.video?.video_url || ""))
    ? String(s.video.video_url)
    : "";
  const videoLink = videoHref
    ? `<p><a href="${escapeHtml(videoHref)}" target="_blank" rel="noopener">Open recording</a></p>`
    : "";
  const friendlyDue = formatWhen(s.friendly_deadline);
  const videoDue = formatWhen(s.video_deadline);
  const restarted = Number(s.qualifying_resets) > 0;
  const friendlyDeadline = friendlyDue
    ? `<p>All five have to be registered by <b>${escapeHtml(friendlyDue)}</b>. ${
        restarted
          ? "The previous attempt ran out, so these 7 days started again."
          : "That is 7 days from the account being created."
      } Short of five, these results clear and the 7 days start again.</p>`
    : "";
  const videoDeadline =
    videoDue && !approved
      ? `<p>Post the film by <b>${escapeHtml(videoDue)}</b>. That is 72 hours after the 7-day deadline, once the five results are in. After that the five clear and you start again.</p>`
      : "";
  const code = escapeHtml(s.upload_code || "");
  const codeBlock = `<p class="friendly-sub">Your recording code</p><p class="recording-code">${code}</p>`;
  const videoBlock = approved
    ? `${codeBlock}<p>Approved. You are on the waiting list.</p>${videoLink}`
    : open
      ? `${codeBlock}<p>Staff have this code and the film. The alert is on the admin desk.</p>${videoLink}`
      : `${codeBlock}
         <p>That code is yours. Post it in <b>${escapeHtml(s.video_channel)}</b> as the label of the film link: the code in square brackets, then your YouTube or MEGA address in round brackets. The scan matches this code to you, and only from the Discord account on your profile. Staff get an alert with the film link.</p>
         ${
           rejected
             ? `<p>Last video was sent back.<br>${escapeHtml(s.video?.review_note || "")}</p><p>The five you already logged still count. The code above is the new one. Post that with the new film.</p>`
             : ""
         }`;

  const queueRows = Array.isArray(waitingList?.rows) ? waitingList.rows : [];
  const myPlace = Number(waitingList?.my_position) || 0;
  const queueTotal = Number(waitingList?.total) || queueRows.length;
  const queueItems = queueRows
    .map((row) => {
      const you = myPlace && Number(row.position) === myPlace;
      return `<li class="${you ? "you" : ""}"><span>${escapeHtml(row.position)}</span><b>${escapeHtml(
        row.owner_tag || "—"
      )}</b>${you ? "<em>You</em>" : ""}</li>`;
    })
    .join("");
  const waitingHtml = waitingList
    ? `${
        myPlace
          ? `<p class="wl-place"><b>#${myPlace}</b><span>of ${queueTotal} on the list</span></p>`
          : `<p class="wl-place"><b>${queueTotal}</b><span>waiting. You join when the recording is approved.</span></p>`
      }
      <ul class="wl-queue">${queueItems || `<li class="empty">The list is empty.</li>`}</ul>`
    : `<p>The waiting list could not be loaded.</p>`;
  const inSeason = intakeMode === "mid_season";
  const seasonTitle = s.handpick_club || inSeason ? "Handpick" : "Club auction";
  const guide = (href, label) => (approved ? `<a href="${href}">${label}</a>` : label);
  const clubs = Array.isArray(vacantClaim?.clubs) ? vacantClaim.clubs : [];
  const clubRows = clubs
    .map((c) => {
      const short = escapeHtml(c.short_name || "");
      const name = escapeHtml(c.club_name || c.short_name || "");
      const div = escapeHtml(c.division_label || c.division || "");
      return `<li class="claim-row"><span><b>${name}</b> ${short}${div ? ` · ${div}` : ""}</span><button type="button" class="button" data-claim="${short}">Take this club</button></li>`;
    })
    .join("");
  const seasonBody = s.handpick_club && !inSeason
    ? `<p>You can take <b>${escapeHtml(s.handpick_club)}</b> until ${escapeHtml(
        s.handpick_due_at
          ? new Date(s.handpick_due_at).toLocaleString("en-GB")
          : "the deadline"
      )}. After that the offer closes and you stay on the waiting list.</p>
       <ul class="req">
         <li>You keep the club's cash. The old squad is released.</li>
         <li>In ${guide("GPDB.html", "GPDB")}, tick free agents. A tick is not a signing.</li>
         <li>${guide("handpick_squad.html", "Handpick Squad")} has to be green: squad size, home-grown, under-21s, a goalkeeper, the star cap, and the cash.</li>
         <li>In ${guide("MGDB.html", "MGDB")}, tick one manager.</li>
         <li>Submit the squad and the manager together. The fees leave when staff approve.</li>
       </ul>`
    : inSeason
      ? approved
        ? `<p>Pick an empty club in a division. You keep its cash. The old squad is released, then you handpick.</p>
           ${
             clubRows
               ? `<ul class="claim-list">${clubRows}</ul>`
               : `<p>No empty club is in a division right now.</p>`
           }
           <ul class="req">
             <li>In ${guide("GPDB.html", "GPDB")}, tick free agents. Check the player is still in eFootball. A tick is not a signing.</li>
             <li>${guide("handpick_squad.html", "Handpick Squad")} has to be green: squad size, home-grown, under-21s, a goalkeeper, the star cap, and the cash.</li>
             <li>In ${guide("MGDB.html", "MGDB")}, tick one manager.</li>
             <li>Submit the squad and the manager together. The fees leave when staff approve.</li>
           </ul>`
        : `<p>When this opens, you pick an empty club that is in a division. You keep its cash. The old squad is released, then you handpick.</p>
           <ul class="req">
             <li>In GPDB, tick free agents. Check the player is still in eFootball. A tick is not a signing.</li>
             <li>Handpick Squad has to be green: squad size, home-grown, under-21s, a goalkeeper, the star cap, and the cash.</li>
             <li>In MGDB, tick one manager.</li>
             <li>Submit the squad and the manager together. Staff approve. The fees leave then.</li>
           </ul>`
      : `<p>Between seasons the door is the club auction. An admin invites you. You bid only if invited.</p>
         <ul class="req">
           <li>On ${guide("club_database.html", "Club Database")}, mark a first club and a backup.</li>
           <li>The bid pays for the club and the stadium. What is left is your balance.</li>
           <li>Squad and manager then come through the drafts.</li>
         </ul>`;

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
  const current = !step1 ? 1 : !step2 ? 2 : !submitted ? 3 : !approved ? 3 : 5;
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
        <div class="friendly-pips">${pips}</div>
        <p>Post each score in <b>${escapeHtml(s.friendly_channel)}</b>, with your tag or by tagging both owners. The fifth bar is the one you film, in the next step.</p>
        ${friendlyDeadline}
        ${
          step1 && !tagOk
            ? `<p>The tag in that line has to be letters and numbers only, 2 to 32 characters.</p>`
            : ""
        }
        <ul class="friendly-list match-slots">${friendlyItems}</ul>
        ${
          pendingItems
            ? `<p class="friendly-sub">Waiting on the other owner</p><ul class="friendly-list">${pendingItems}</ul>`
            : ""
        }
      </div>
    </section>
    <section class="${stepClass(3, submitted, false)}">
      <div class="step-head"><span class="step-no">3</span><h2>Record friendly 5</h2>${
        open && !approved
          ? `<span class="pill">With staff</span>`
          : submitted
            ? pill(true, false)
            : step2
              ? pill(false, false)
              : `<span class="pill">After 5</span>`
      }</div>
      <div class="step-body">
        ${recordCallout}
        ${videoDeadline}
        <p>10-minute match, injuries off. Staff tick these on the open recording:</p>
        <ul class="req">${recordingItems}</ul>
        ${videoBlock}
      </div>
    </section>
    <section class="${stepClass(4, approved, !approved)}">
      <div class="step-head"><span class="step-no">4</span><h2>The waiting list</h2>${approved ? `<span class="pill">On the list</span>` : `<span class="pill">After the film</span>`}</div>
      <div class="step-body">
        ${
          approved
            ? `<p>The recording is approved. This is your place. You do not pick a club from this list.</p>${waitingHtml}`
            : `<p>This opens when the recording is approved. Until then this account is not on the waiting list.</p>`
        }
      </div>
    </section>
    <section class="${stepClass(5, false, !approved)}">
      <div class="step-head"><span class="step-no">5</span><h2>${escapeHtml(seasonTitle)}</h2>${pill(false, !approved)}</div>
      <div class="step-body">
        ${seasonBody}
      </div>
    </section>
    </div>
    <section class="qual-avail">
      <h2>When you can play</h2>
      <p>Same step as the tag. Save both before the friendlies unlock.</p>
      <div id="availRoot"></div>
    </section>`;

  document.getElementById("saveTagBtn").onclick = saveTag;
  document.querySelectorAll("[data-claim]").forEach((btn) => {
    btn.onclick = () => claimClub(btn.getAttribute("data-claim"));
  });
  const youRow = document.querySelector(".wl-queue .you");
  if (youRow?.parentElement) {
    youRow.parentElement.scrollTop = Math.max(0, youRow.offsetTop - 36);
  }
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
  try {
    if (data?.video_approved) {
      const { data: list, error: listError } = await supabase.rpc("waiting_list_public");
      waitingList = listError ? null : list;
    } else {
      waitingList = null;
    }
  } catch {
    waitingList = null;
  }
  try {
    const { data: mode } = await supabase.rpc("gpsl_owner_intake_mode");
    intakeMode = mode === "mid_season" ? "mid_season" : "pre_season";
  } catch {
    intakeMode = "pre_season";
  }
  try {
    if (data?.video_approved && intakeMode === "mid_season") {
      const { data: claim, error: claimError } = await supabase.rpc("waiting_list_vacant_clubs_for_claim");
      vacantClaim = claimError ? null : claim;
    } else {
      vacantClaim = null;
    }
  } catch {
    vacantClaim = null;
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

async function claimClub(shortName) {
  const short = String(shortName || "").trim();
  if (!short) return;
  if (!window.confirm(`Take ${short}?\n\nYou become the owner. The squad is cleared for handpick.`)) return;
  setStatus(`Taking ${short}…`);
  const { data, error } = await supabase.rpc("waiting_list_claim_vacant_club", {
    p_club_short_name: short,
  });
  if (error || data?.ok === false) {
    setStatus(error?.message || data?.detail || data?.reason || "Could not take that club", false);
    return;
  }
  window.location.assign(
    data?.redirect || `handpick_squad.html?club=${encodeURIComponent(data?.club || short)}`
  );
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
