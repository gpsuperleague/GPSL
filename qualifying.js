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

  const friendlyItems = friendlies
    .map(
      (f) =>
        `<li>${escapeHtml(f.played_on)} · ${escapeHtml(f.opponent)}</li>`
    )
    .join("");

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
           }
           <button type="button" class="button" id="submitVideoBtn">I have uploaded this code</button>`;

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

  document.getElementById("steps").innerHTML = `
    <section class="step ${step1 ? "done" : ""}">
      ${pill(step1, false)}
      <h2>1. Who you are</h2>
      <p>Set the tag people will see, and the times you can play. Both are required before the friendlies unlock.</p>
      <label>Owner tag
        <input id="tagInput" type="text" maxlength="32" value="${escapeHtml(s.owner_tag || "")}">
      </label>
      <button type="button" class="button" id="saveTagBtn">Save tag</button>
      <div id="availRoot" style="margin-top:14px"></div>
    </section>
    <section class="step ${!step1 ? "locked" : ""} ${step2 ? "done" : ""}">
      ${pill(step2, !step1)}
      <h2>2. Five friendlies</h2>
      <p>Play them in <b>${escapeHtml(s.friendly_channel)}</b>. Practice side only: any players, PA3 or PA4, and the matchday rules. These games do not touch the league. Log each one here. ${count} of 5 logged.</p>
      <ul class="friendly-list">${friendlyItems}</ul>
      ${
        step1 && !approved
          ? `<div class="row">
              <label>Day played<input id="playedOn" type="date"></label>
              <label>Who you played<input id="opponent" type="text" maxlength="80" placeholder="Practice side"></label>
              <button type="button" class="button" id="logFriendlyBtn">Log friendly</button>
            </div>`
          : ""
      }
    </section>
    <section class="step ${!step2 ? "locked" : ""} ${approved ? "done" : ""}">
      ${pill(approved, !step2)}
      <h2>3. One recording</h2>
      <p>The fifth match is the one staff watch. The other four are not reviewed. The card is PA3 or PA4, advanced skill, match-room settings, manager, subtactic, squad, no individual player instructions, no dragging a formation, and the recording running from the settings through to the ratings.</p>
      ${videoBlock}
    </section>
    <section class="step ${!approved ? "locked" : "done"}">
      ${pill(approved, !approved)}
      <h2>4. A club, when an admin opens one</h2>
      ${
        approved
          ? door
          : `<p>An approved video puts you on the waiting list. It does not give you a club. Auction and handpick each need an admin tick.</p>`
      }
    </section>`;

  document.getElementById("saveTagBtn").onclick = saveTag;
  document.getElementById("logFriendlyBtn")?.addEventListener("click", logFriendly);
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

async function logFriendly() {
  const played = document.getElementById("playedOn")?.value;
  const opponent = document.getElementById("opponent")?.value || "";
  setStatus("Logging friendly…");
  const { error } = await supabase.rpc("owner_qualifying_log_friendly", {
    p_played_on: played || null,
    p_opponent: opponent,
  });
  if (error) {
    setStatus(error.message, false);
    return;
  }
  setStatus("Friendly logged.", true);
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
