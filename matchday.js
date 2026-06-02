import { supabase, initGlobal } from "./global.js";
import {
  loadLeagueFixtures,
  loadCupFixtures,
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
let squadPlayers = [];

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
  const statsPanel = document.getElementById("playerStatsPanel");
  if (statsPanel) statsPanel.style.display = enabled ? "block" : "none";
}

function myTeamGoalsForFixture(fixture, homeGoals, awayGoals) {
  if (!fixture || !myClub.short) return 0;
  const home =
    (fixture.home_club_short_name || "").toUpperCase() ===
    (myClub.short || "").toUpperCase();
  return home ? homeGoals : awayGoals;
}

function ratingOptionsHtml(selected) {
  let html = '<option value="">—</option>';
  for (let i = 1; i <= 10; i += 0.5) {
    const v = i % 1 === 0 ? String(i) : i.toFixed(1);
    const sel = selected != null && Number(selected) === i ? " selected" : "";
    html += `<option value="${v}"${sel}>${v}</option>`;
  }
  return html;
}

async function loadSquadPlayers() {
  if (!myClub.short) {
    squadPlayers = [];
    return;
  }
  const { data, error } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Rating")
    .eq("Contracted_Team", myClub.short)
    .order("Name");

  if (error) {
    console.error("loadSquadPlayers:", error);
    squadPlayers = [];
    return;
  }
  squadPlayers = data || [];
}

function renderPlayerStatsTable() {
  const tbody = document.getElementById("playerStatsBody");
  if (!tbody) return;

  tbody.innerHTML = "";
  if (!squadPlayers.length) {
    tbody.innerHTML =
      '<tr><td colspan="6" style="color:#888;">No squad players found.</td></tr>';
    return;
  }

  for (const p of squadPlayers) {
    const id = String(p.Konami_ID);
    const tr = document.createElement("tr");
    tr.dataset.statPlayer = id;
    tr.innerHTML = `
      <td class="name">${p.Name} <span style="color:#666;">${p.Position || ""}</span></td>
      <td><input type="checkbox" class="stat-played"></td>
      <td><input type="number" class="stat-goals" min="0" max="20" value="0"></td>
      <td><input type="number" class="stat-assists" min="0" max="20" value="0"></td>
      <td><select class="stat-rating">${ratingOptionsHtml(null)}</select></td>
      <td><input type="radio" name="potm" class="stat-potm" value="${id}"></td>
    `;
    tbody.appendChild(tr);
  }
}

function collectPlayerStats() {
  const rows = document.querySelectorAll("#playerStatsBody tr[data-stat-player]");
  const out = [];
  for (const tr of rows) {
    const player_id = tr.dataset.statPlayer;
    const appeared = tr.querySelector(".stat-played")?.checked ?? false;
    const goals = Number(tr.querySelector(".stat-goals")?.value) || 0;
    const assists = Number(tr.querySelector(".stat-assists")?.value) || 0;
    const ratingRaw = tr.querySelector(".stat-rating")?.value;
    const rating = ratingRaw ? Number(ratingRaw) : null;
    const potm = tr.querySelector(".stat-potm")?.checked ?? false;

    if (!appeared && goals === 0 && assists === 0 && rating == null && !potm) {
      continue;
    }

    out.push({
      player_id,
      appeared,
      goals,
      assists,
      rating: rating != null && !Number.isNaN(rating) ? rating : null,
      potm,
    });
  }
  return out;
}

function validatePlayerStats(fixture, homeGoals, awayGoals, playerStats) {
  const expected = myTeamGoalsForFixture(fixture, homeGoals, awayGoals);
  let teamGoals = 0;
  let potmCount = 0;

  for (const row of playerStats) {
    teamGoals += row.goals || 0;
    if (row.potm) potmCount += 1;
    if (row.rating != null && (row.rating < 1 || row.rating > 10)) {
      return "Ratings must be between 1 and 10.";
    }
    if (!row.appeared && (row.goals > 0 || row.assists > 0)) {
      return "Players with goals or assists must be marked as played.";
    }
  }

  if (potmCount > 1) return "Only one Player of the Match allowed.";
  if (teamGoals > 0 && teamGoals !== expected) {
    return `Player goals (${teamGoals}) must match your team score (${expected}).`;
  }
  return null;
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
    const label =
      f.competition_type === "cup"
        ? `${(f.cup_code || "cup").toUpperCase()} R${f.cup_round}M${f.cup_match}`
        : `MD${f.matchday}`;
    opt.textContent = `${label}: ${f.home_club_name} vs ${f.away_club_name}${pending}`;
    sel.appendChild(opt);
  }

  sel.onchange = updateFixturePreview;
  updateFixturePreview();
}

async function loadUpcomingFixtures() {
  const league = await loadLeagueFixtures(supabase, myDivision);
  const cups = await loadCupFixtures(supabase);
  allLeagueFixtures = [...league, ...cups];
  upcomingFixtures = allLeagueFixtures
    .filter(
      (f) =>
        fixtureInvolvesClub(f, myClub) &&
        (f.status === "scheduled" || f.submission_status === "pending")
    )
    .sort((a, b) => {
      if (a.competition_type !== b.competition_type) {
        return a.competition_type === "cup" ? -1 : 1;
      }
      if (a.competition_type === "cup") {
        return (
          (a.cup_code || "").localeCompare(b.cup_code || "") ||
          (a.cup_round || 0) - (b.cup_round || 0) ||
          (a.cup_match || 0) - (b.cup_match || 0)
        );
      }
      return a.matchday - b.matchday;
    });
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

  if (f.competition_type === "cup" && homeGoals === awayGoals) {
    setStatus("submitStatus", "Cup matches need a winner — no draws.", true);
    return;
  }

  const playerStats = collectPlayerStats();
  const statsErr = validatePlayerStats(f, homeGoals, awayGoals, playerStats);
  if (statsErr) {
    setStatus("submitStatus", statsErr, true);
    return;
  }

  setStatus("submitStatus", "Submitting…");
  const { error } = await submitFixtureResult(
    supabase,
    f.id,
    homeGoals,
    awayGoals,
    playerStats
  );

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

  const { data: club, error: clubErr } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (clubErr) {
    console.error("Club lookup:", clubErr);
  }

  if (!club?.ShortName) {
    document.getElementById("pageMeta").innerHTML =
      "No club linked to this account. In Supabase → <b>Clubs</b>, set <b>owner_id</b> " +
      "to this user&apos;s id for the club you are playing as — required to confirm results in Inbox.";
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

  await loadSquadPlayers();
  renderPlayerStatsTable();

  await loadUpcomingFixtures();
  populateFixtureSelect();
  preselectFixtureFromUrl();
  await renderInbox();

  if (window.location.hash === "#inbox") {
    document.getElementById("inbox").scrollIntoView({ behavior: "smooth" });
  }
});
