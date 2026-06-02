import { supabase, initGlobal } from "./global.js";
import {
  loadLeagueFixtures,
  GPSL_MONTH_LABELS,
  fixtureInvolvesClub,
  submitFixtureResult,
  confirmFixtureResult,
  rejectFixtureResult,
  canSubmitResult,
  LEAGUE_DIVISIONS,
} from "./competition.js";
import { loadInboxMessages } from "./competition_inbox.js";

let myClub = { short: null, name: null };
let myDivision = null;
let upcomingFixtures = [];
let allLeagueFixtures = [];

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

function setScoreInputsEnabled(enabled) {
  document.getElementById("homeGoals").disabled = !enabled;
  document.getElementById("awayGoals").disabled = !enabled;
  document.getElementById("submitResultBtn").disabled = !enabled;
}

function showNoFixturesHelp() {
  const el = document.getElementById("noFixturesHelp");
  if (!el) return;

  const mine = allLeagueFixtures.filter((f) => fixtureInvolvesClub(f, myClub));
  const scheduled = mine.filter((f) => f.status === "scheduled");

  if (upcomingFixtures.length > 0) {
    el.style.display = "none";
    return;
  }

  el.style.display = "block";
  if (!allLeagueFixtures.length) {
    el.innerHTML = `
      <b>No fixtures in the database.</b> Admin must activate the season and generate fixtures
      (GPSL Admin → League Fixtures) for each division.
    `;
  } else if (!mine.length) {
    el.innerHTML = `
      <b>Your club has no fixtures on the current season.</b>
      Check you are on an active season with your club in a division.
    `;
  } else if (!scheduled.length) {
    el.innerHTML = `
      <b>All your fixtures are already played or cancelled.</b>
      (${mine.length} total for your club.)
    `;
  } else {
    el.innerHTML = `
      <b>No fixtures ready to submit.</b> Open
      <a href="fixtures.html" style="color:#ff9900;">Fixtures</a> for your highlighted games.
    `;
  }

  setScoreInputsEnabled(false);
}

function updateFixturePreview() {
  const f = selectedFixture();
  const preview = document.getElementById("fixturePreview");

  if (!f) {
    preview.textContent = "Select a fixture from the list above.";
    setScoreInputsEnabled(false);
    return;
  }

  const month = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;
  let extra = "";
  if (f.submission_status === "pending") {
    if (
      f.submitted_by_club &&
      f.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
    ) {
      const oppName =
        (f.home_club_short_name || "").toUpperCase() === (myClub.short || "").toUpperCase()
          ? f.away_club_name
          : f.home_club_name;
      extra = ` · Awaiting confirmation from ${oppName}`;
    } else {
      extra = ` · They submitted ${f.proposed_home_goals}–${f.proposed_away_goals} — scroll to Inbox`;
    }
  }

  preview.innerHTML = `
    <b>Matchday ${f.matchday}</b> · ${month}<br>
    ${f.home_club_name} vs ${f.away_club_name}${extra}
  `;

  document.getElementById("homeLabel").textContent = f.home_club_name;
  document.getElementById("awayLabel").textContent = f.away_club_name;

  const canSubmit = canSubmitResult(f, myClub);
  setScoreInputsEnabled(canSubmit);

  if (
    f.submission_id &&
    f.submitted_by_club &&
    f.submitted_by_club.toUpperCase() === (myClub.short || "").toUpperCase()
  ) {
    setStatus("submitStatus", "Result submitted — waiting for opponent.");
  } else if (f.submission_id) {
    setStatus("submitStatus", "Opponent submitted — confirm or reject in Inbox below.");
  } else if (canSubmit) {
    setStatus("submitStatus", "Enter home and away goals, then submit.");
  } else {
    setStatus("submitStatus", "This fixture cannot accept a new result.");
  }
}

function populateFixtureSelect() {
  const sel = document.getElementById("fixtureSelect");
  sel.innerHTML = "";

  if (!upcomingFixtures.length) {
    sel.innerHTML = '<option value="">— no fixtures to submit —</option>';
    showNoFixturesHelp();
    updateFixturePreview();
    return;
  }

  document.getElementById("noFixturesHelp").style.display = "none";

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
  allLeagueFixtures = await loadLeagueFixtures(supabase, myDivision);
  upcomingFixtures = allLeagueFixtures
    .filter(
      (f) =>
        fixtureInvolvesClub(f, myClub) &&
        (f.status === "scheduled" || f.submission_status === "pending")
    )
    .sort((a, b) => a.matchday - b.matchday);
}

async function submitResult() {
  const f = selectedFixture();
  if (!f || !canSubmitResult(f, myClub)) {
    setStatus("submitStatus", "Select a fixture you can submit.", true);
    return;
  }

  const homeGoals = Number(document.getElementById("homeGoals").value);
  const awayGoals = Number(document.getElementById("awayGoals").value);

  if (!Number.isFinite(homeGoals) || !Number.isFinite(awayGoals) || homeGoals < 0 || awayGoals < 0) {
    setStatus("submitStatus", "Enter valid scores.", true);
    return;
  }

  setStatus("submitStatus", "Submitting…");
  const { error } = await submitFixtureResult(supabase, f.id, homeGoals, awayGoals);

  if (error) {
    setStatus("submitStatus", "❌ " + error.message, true);
    return;
  }

  setStatus("submitStatus", "✅ Submitted. Opponent notified — they confirm in Inbox.");
  await loadUpcomingFixtures();
  populateFixtureSelect();
  await renderInbox();
}

async function confirmSubmission(submissionId) {
  setStatus("inboxStatus", "Confirming…");
  const { error } = await confirmFixtureResult(supabase, submissionId);

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
  const { error } = await rejectFixtureResult(supabase, submissionId, reason);

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
    list.innerHTML =
      '<p class="empty">No messages. When an opponent submits a score, it appears here to confirm or reject.</p>';
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
      confirmBtn.textContent = "Confirm result";
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

function preselectFixtureFromUrl() {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("fixture");
  if (!id) return;

  const sel = document.getElementById("fixtureSelect");
  if ([...sel.options].some((o) => o.value === id)) {
    sel.value = id;
    updateFixturePreview();
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
    document.getElementById("submitPanel").style.display = "none";
    return;
  }

  myClub = { short: club.ShortName, name: club.Club };

  const { data: regs } = await supabase
    .from("competition_club_season_public")
    .select("club_short_name, club_name, division");

  const key = (myClub.short || "").trim().toUpperCase();
  const reg = (regs || []).find(
    (r) => (r.club_short_name || "").trim().toUpperCase() === key
  );
  if (reg) {
    myClub.short = reg.club_short_name;
    myClub.name = reg.club_name || myClub.name;
    if (LEAGUE_DIVISIONS.includes(reg.division)) {
      myDivision = reg.division;
    }
  }

  document.getElementById("pageMeta").textContent =
    `${club.Club} — enter scores below or on Fixtures (highlighted rows)`;

  document.getElementById("submitResultBtn").onclick = submitResult;

  await loadUpcomingFixtures();
  populateFixtureSelect();
  preselectFixtureFromUrl();
  await renderInbox();

  if (window.location.hash === "#inbox") {
    document.getElementById("inbox").scrollIntoView({ behavior: "smooth" });
  }
});
