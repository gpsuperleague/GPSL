import { supabase, initGlobal } from "./global.js?v=20261117-qualifying-gate";
import { getAuthUser } from "./supabase_client.js";
import { mountAvailabilityPanel } from "./owner_availability.js?v=20260930-world-tz";
import {
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
  const pips = Array.from({ length: 5 }, (_, i) =>
    `<i class="${i < Math.min(count, 5) ? "on" : ""}"></i>`
  ).join("");
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
         <p><a href="waiting_list.html">Waiting list</a> · <a href="handpick_squad.html">Handpick squad</a></p>`
      : `<p>You are on the waiting list. An admin will invite you to the club auction, or name the one club you can handpick.</p>
         <p>When a door opens you will use <a href="club_database.html">Club Database</a>, <a href="GPDB.html">GPDB</a>, <a href="MGDB.html">MGDB</a>, and either the auction or Handpick.</p>
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
  const current = !step1 ? 1 : !step2 ? 2 : !approved ? 3 : 4;
  const stepClass = (n, done, locked) =>
    `step${done ? " done" : ""}${locked ? " locked" : ""}${current === n && !done ? " current" : ""}`;

  document.getElementById("steps").innerHTML = `
    <div class="qual-steps">
    <section class="${stepClass(1, step1, false)}">
      <div class="step-head"><span class="step-no">1</span><h2>Who you are</h2>${pill(step1, false)}</div>
      <div class="step-body">
        <p>Set the tag people will see. The times you can play sit in the panel under this row. Both are required before the friendlies unlock.</p>
        <label>Owner tag
          <input id="tagInput" type="text" maxlength="32" value="${escapeHtml(s.owner_tag || "")}">
        </label>
      </div>
      <div class="step-actions"><button type="button" class="button" id="saveTagBtn">Save tag</button></div>
    </section>
    <section class="${stepClass(2, step2, !step1)}">
      <div class="step-head"><span class="step-no">2</span><h2>Five friendlies</h2>${pill(step2, !step1)}</div>
      <div class="step-body">
        <div class="friendly-tally" aria-label="${count} registered, ${left} ${left === 1 ? "fixture" : "fixtures"} left">
          <div><b>${count}</b><span>registered</span></div>
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
    <section class="${stepClass(3, approved, !step2)}">
      <div class="step-head"><span class="step-no">3</span><h2>One recording</h2>${pill(approved, !step2)}</div>
      <div class="step-body">
        <p>The fifth match is the one staff watch. The other four are not reviewed. The card is PA3 or PA4, advanced skill, match-room settings, manager, subtactic, squad, no individual player instructions, no dragging a formation, and the recording running from the settings through to the ratings.</p>
        ${videoBlock}
      </div>
      ${
        step2 && !open && !approved
          ? `<div class="step-actions"><button type="button" class="button" id="submitVideoBtn">I have uploaded this code</button></div>`
          : ""
      }
    </section>
    <section class="${stepClass(4, approved, !approved)}">
      <div class="step-head"><span class="step-no">4</span><h2>Your club</h2>${pill(approved, !approved)}</div>
      <div class="step-body">
        ${
          approved
            ? door
            : `<p>An approved video puts you on the waiting list. It does not give you a club. Auction and handpick each need an admin tick.</p>`
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
