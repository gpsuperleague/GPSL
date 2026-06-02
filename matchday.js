import { supabase, initGlobal } from "./global.js";
import { loadLeagueFixtures, GPSL_MONTH_LABELS, fixtureInvolvesClub } from "./competition.js";
import { loadInboxMessages } from "./competition_inbox.js";

let myClubShort = null;
let upcomingFixtures = [];

function setStatus(elId, msg, isError = false) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "#f66" : "#ffcc00";
}

function selectedFixture() {
  const id = document.getElementById("fixtureSelect").value;
  if (!id) return null;
  return upcomingFixtures.find((f) => String(f.id) === id) || null;
}

function updateFixturePreview() {
  const f = selectedFixture();
  const preview = document.getElementById("fixturePreview");
  const submitBtn = document.getElementById("submitResultBtn");

  if (!f) {
    preview.textContent = "Select a fixture.";
    submitBtn.disabled = true;
    return;
  }

  const month = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;
  let extra = "";
  if (f.submission_status === "pending") {
    if (f.submitted_by_club === myClubShort) {
      const opp =
        f.home_club_short_name === myClubShort
          ? f.away_club_name
          : f.home_club_name;
      extra = ` · Awaiting confirmation from ${opp}`;
    } else {
      extra = ` · They submitted ${f.proposed_home_goals}–${f.proposed_away_goals} — use Inbox`;
    }
  }

  preview.innerHTML = `
    <b>Matchday ${f.matchday}</b> · ${month}<br>
    ${f.home_club_name} vs ${f.away_club_name}${extra}
  `;

  document.getElementById("homeLabel").textContent = f.home_club_name;
  document.getElementById("awayLabel").textContent = f.away_club_name;

  const canSubmit =
    f.status === "scheduled" &&
    !f.submission_id &&
    fixtureInvolvesClub(f, myClubShort);

  submitBtn.disabled = !canSubmit;
  if (f.submission_id && f.submitted_by_club === myClubShort) {
    setStatus("submitStatus", "Result submitted — waiting for opponent.");
  } else if (f.submission_id) {
    setStatus("submitStatus", "Opponent submitted a result — use Inbox to confirm or reject.");
  } else {
    setStatus("submitStatus", "");
  }
}

function populateFixtureSelect() {
  const sel = document.getElementById("fixtureSelect");
  sel.innerHTML = "";

  if (!upcomingFixtures.length) {
    sel.innerHTML = '<option value="">No scheduled fixtures</option>';
    updateFixturePreview();
    return;
  }

  for (const f of upcomingFixtures) {
    const opt = document.createElement("option");
    opt.value = f.id;
    const pending =
      f.submission_status === "pending" ? " · pending" : "";
    opt.textContent = `MD${f.matchday}: ${f.home_club_name} vs ${f.away_club_name}${pending}`;
    sel.appendChild(opt);
  }

  sel.onchange = updateFixturePreview;
  updateFixturePreview();
}

async function loadUpcomingFixtures() {
  const all = await loadLeagueFixtures(supabase);
  upcomingFixtures = all
    .filter(
      (f) =>
        fixtureInvolvesClub(f, myClubShort) &&
        (f.status === "scheduled" || f.submission_status === "pending")
    )
    .sort((a, b) => a.matchday - b.matchday);
}

async function submitResult() {
  const f = selectedFixture();
  if (!f) return;

  const homeGoals = Number(document.getElementById("homeGoals").value);
  const awayGoals = Number(document.getElementById("awayGoals").value);

  if (!Number.isFinite(homeGoals) || !Number.isFinite(awayGoals) || homeGoals < 0 || awayGoals < 0) {
    setStatus("submitStatus", "Enter valid scores.", true);
    return;
  }

  setStatus("submitStatus", "Submitting…");
  const { data, error } = await supabase.rpc("competition_submit_result", {
    p_fixture_id: f.id,
    p_home_goals: homeGoals,
    p_away_goals: awayGoals,
  });

  if (error) {
    setStatus("submitStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("submitStatus", `✅ Submitted (id ${data}). Opponent notified.`);
  await loadUpcomingFixtures();
  populateFixtureSelect();
  await renderInbox();
}

async function confirmSubmission(submissionId) {
  setStatus("inboxStatus", "Confirming…");
  const { error } = await supabase.rpc("competition_confirm_result", {
    p_submission_id: submissionId,
  });

  if (error) {
    setStatus("inboxStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("inboxStatus", "✅ Result confirmed — table updated.");
  await loadUpcomingFixtures();
  populateFixtureSelect();
  await renderInbox();
}

async function rejectSubmission(submissionId) {
  const reason = prompt("Reason for rejection (optional):") || null;
  setStatus("inboxStatus", "Rejecting…");
  const { error } = await supabase.rpc("competition_reject_result", {
    p_submission_id: submissionId,
    p_reason: reason,
  });

  if (error) {
    setStatus("inboxStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("inboxStatus", "Result rejected. Submitter notified.");
  await loadUpcomingFixtures();
  populateFixtureSelect();
  await renderInbox();
}

async function markRead(inboxId) {
  await supabase.rpc("competition_inbox_mark_read", { p_inbox_id: inboxId });
}

async function renderInbox() {
  const list = document.getElementById("inboxList");
  const messages = await loadInboxMessages(supabase);

  if (!messages.length) {
    list.innerHTML = '<p class="empty">No messages.</p>';
    return;
  }

  list.innerHTML = "";

  for (const msg of messages) {
    const div = document.createElement("div");
    div.className = "inbox-item" + (msg.read_at ? "" : " unread");

    div.innerHTML = `
      <h3>${msg.title}</h3>
      <p>${msg.body}</p>
      <div class="inbox-actions"></div>
    `;

    const actions = div.querySelector(".inbox-actions");

    if (msg.message_type === "result_to_confirm" && !msg.read_at) {
      const confirmBtn = document.createElement("button");
      confirmBtn.className = "button";
      confirmBtn.textContent = "Confirm";
      confirmBtn.onclick = () => confirmSubmission(msg.submission_id);

      const rejectBtn = document.createElement("button");
      rejectBtn.className = "button danger";
      rejectBtn.textContent = "Reject";
      rejectBtn.onclick = () => rejectSubmission(msg.submission_id);

      actions.appendChild(confirmBtn);
      actions.appendChild(rejectBtn);
    } else {
      const readBtn = document.createElement("button");
      readBtn.className = "button secondary";
      readBtn.textContent = msg.read_at ? "Read" : "Mark read";
      readBtn.disabled = !!msg.read_at;
      readBtn.onclick = async () => {
        await markRead(msg.id);
        await renderInbox();
      };
      actions.appendChild(readBtn);
    }

    list.appendChild(div);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent = "No club assigned to this account.";
    return;
  }

  myClubShort = club.ShortName;
  document.getElementById("pageMeta").textContent = `${club.Club} · submit scores and respond in your inbox`;

  document.getElementById("submitResultBtn").onclick = submitResult;

  await loadUpcomingFixtures();
  populateFixtureSelect();
  await renderInbox();

  if (window.location.hash === "#inbox") {
    document.getElementById("inbox").scrollIntoView({ behavior: "smooth" });
  }
});
