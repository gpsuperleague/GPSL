import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS } from "./competition.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  loadScheduleContext,
  proposeKickoff,
  acceptProposal,
  checkInToFixture,
  voluntaryRescheduleDrop,
  emergencyDrop,
  formatKickoffPair,
  UK_TZ,
} from "./match_scheduling.js";

let ctx = null;
let fixtureId = null;
let selectedKickoff = null;
let myClub = { short: null };

function setStatus(msg, isError = false) {
  const el = document.getElementById("scheduleStatus");
  if (el) {
    el.textContent = msg || "";
    el.style.color = isError ? "#f88" : "#8c8";
  }
}

function parseFixtureId() {
  const q = new URLSearchParams(window.location.search);
  const raw = q.get("fixture");
  const id = raw ? Number(raw) : NaN;
  return Number.isFinite(id) && id > 0 ? id : null;
}

function fixtureTitle(f) {
  const home = fullClubName(f.home_club_short_name);
  const away = fullClubName(f.away_club_short_name);
  return `${home} vs ${away}`;
}

function renderAgreedPanel(root, f, sch) {
  const homeTz = ctx.home_timezone || UK_TZ;
  const awayTz = ctx.away_timezone || UK_TZ;
  const ci = ctx.checkin || {};
  const al = ctx.allowances || {};
  const homeName = fullClubName(f.home_club_short_name);
  const awayName = fullClubName(f.away_club_short_name);

  const checkinStatus = `Home (${homeName}): ${ci.home_checked_in ? "checked in ✓" : "waiting…"} · Away (${awayName}): ${ci.away_checked_in ? "checked in ✓" : "waiting…"}`;

  root.innerHTML = `
    <div class="panel">
      <div class="fixture-head">${fixtureTitle(f)}</div>
      <p class="status-agreed"><b>Kick-off agreed:</b> ${formatKickoffPair(sch.agreed_kickoff_at, homeTz, awayTz)}</p>
      <p class="meta">${checkinStatus}</p>
      <p class="meta">Check-in opens at kick-off for <b>10 minutes</b>. Both must check in before Match Day unlocks for the 30-minute block.</p>
      <p class="meta">Emergency drops remaining this season: <b>${al.emergency_drops_remaining ?? "—"}</b>/2 · Reschedule this GPSL month: <b>${al.reschedule_used_this_month ? "used" : "available"}</b></p>
      <div class="actions">
        ${ci.can_check_in ? '<button type="button" id="checkInBtn" class="button">Check in now</button>' : ""}
        ${ci.can_play ? `<a href="matchday.html?fixture=${f.id}" class="button" style="text-decoration:none;display:inline-block;">Enter result on Match Day</a>` : ""}
        ${al.can_voluntary_drop ? '<button type="button" id="voluntaryDropBtn" class="button secondary">Drop & reschedule (24h+ notice)</button>' : ""}
        ${al.can_emergency_drop ? '<button type="button" id="emergencyDropBtn" class="button secondary">Emergency drop (&lt;24h)</button>' : ""}
      </div>
    </div>
  `;

  const checkInBtn = document.getElementById("checkInBtn");
  if (checkInBtn) {
    checkInBtn.onclick = async () => {
      checkInBtn.disabled = true;
      setStatus("Checking in…");
      const res = await checkInToFixture(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        checkInBtn.disabled = false;
        return;
      }
      setStatus("Checked in.");
      await reload();
    };
  }

  const volBtn = document.getElementById("voluntaryDropBtn");
  if (volBtn) {
    volBtn.onclick = async () => {
      if (!confirm("Drop the agreed time and return to scheduling? Uses your 1 reschedule for this GPSL month.")) return;
      volBtn.disabled = true;
      const res = await voluntaryRescheduleDrop(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        volBtn.disabled = false;
        return;
      }
      setStatus("Returned to scheduling — propose a new time.");
      await reload();
    };
  }

  const emBtn = document.getElementById("emergencyDropBtn");
  if (emBtn) {
    emBtn.onclick = async () => {
      const left = al.emergency_drops_remaining ?? 0;
      if (
        !confirm(
          `Emergency drop (<24h before kick-off)? Uses 1 of ${left} remaining this season.`
        )
      ) {
        return;
      }
      emBtn.disabled = true;
      const res = await emergencyDrop(fixtureId);
      if (!res.ok) {
        setStatus(res.msg, true);
        emBtn.disabled = false;
        return;
      }
      setStatus("Emergency drop recorded — reschedule on this page.");
      await reload();
    };
  }
}

function render() {
  const root = document.getElementById("scheduleRoot");
  const meta = document.getElementById("scheduleMeta");
  const discord = document.getElementById("discordHint");

  if (!ctx || !root) return;

  const f = ctx.fixture;
  const sch = ctx.schedule;
  const pending = ctx.pending_proposal;
  const monthLabel = GPSL_MONTH_LABELS[f.gpsl_month] || f.gpsl_month;

  if (meta) {
    meta.textContent = `${monthLabel} · ${f.competition_type} · Your role: ${ctx.my_role}`;
  }

  if (discord) {
    discord.hidden = !sch.discord_hint_shown;
  }

  if (f.status === "played" || f.is_forfeit) {
    root.innerHTML = `
      <div class="panel">
        <div class="fixture-head">${fixtureTitle(f)}</div>
        <p class="status-agreed">${f.is_forfeit ? "<b>Forfeit</b> — result recorded." : "<b>Played</b>."}</p>
        <div class="actions">
          <a href="fixtures.html" class="button secondary" style="text-decoration:none;display:inline-block;">Fixtures</a>
        </div>
      </div>
    `;
    return;
  }

  if (sch.status === "agreed" && sch.agreed_kickoff_at) {
    renderAgreedPanel(root, f, sch);
    return;
  }

  const slots = ctx.intersection_slots || [];
  const homeTz = ctx.home_timezone || UK_TZ;
  const awayTz = ctx.away_timezone || UK_TZ;

  let pendingHtml = "";
  if (pending) {
    const fromOpponent = pending.proposed_by_club_short_name !== myClub.short;
    pendingHtml = `
      <div class="panel">
        <h2>Pending proposal</h2>
        <p class="status-pending">
          <b>${fullClubName(pending.proposed_by_club_short_name)}</b> proposed
          ${formatKickoffPair(pending.kickoff_at, homeTz, awayTz)}
        </p>
        ${
          fromOpponent && ctx.can_respond
            ? `<div class="actions">
                <button type="button" id="acceptBtn" class="button">Accept this time</button>
              </div>`
            : "<p class=\"meta\">Waiting for your opponent to respond.</p>"
        }
      </div>
    `;
  }

  const canPick = ctx.can_propose_first || ctx.can_respond;

  const proposeLabel = ctx.can_propose_first
    ? "Propose kick-off"
    : ctx.can_respond
      ? "Counter-propose"
      : "Suggest another time";

  root.innerHTML = `
    <div class="panel">
      <div class="fixture-head">${fixtureTitle(f)}</div>
      <p class="meta">
        Home proposes first. Pick a 30-minute block where <b>both</b> clubs are available
        (${slots.length} mutual slot${slots.length === 1 ? "" : "s"} in this GPSL month).
        Proposals: home ${sch.home_proposal_count}/2 · away ${sch.away_proposal_count}/2.
      </p>
      ${
        !slots.length
          ? '<p class="meta" style="color:#f88;">No mutual slots — update your availability on <a href="club_details.html" style="color:#ff9900;">Club Details</a> and ask your opponent to do the same.</p>'
          : ""
      }
    </div>
    ${pendingHtml}
    <div class="panel">
      <h2>Mutual slots</h2>
      <div class="slot-list" id="slotList"></div>
      ${
        canPick && slots.length
          ? `<div class="actions">
              <button type="button" id="proposeBtn" class="button" disabled>${proposeLabel}</button>
            </div>`
          : ""
      }
    </div>
  `;

  const slotList = document.getElementById("slotList");
  if (slotList) {
    for (const iso of slots) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "slot-btn";
      btn.innerHTML = formatKickoffPair(iso, homeTz, awayTz).replace(/ · /g, "<br>");
      btn.onclick = () => {
        selectedKickoff = iso;
        slotList.querySelectorAll(".slot-btn").forEach((b) => b.classList.remove("selected"));
        btn.classList.add("selected");
        const proposeBtn = document.getElementById("proposeBtn");
        if (proposeBtn) proposeBtn.disabled = false;
      };
      slotList.appendChild(btn);
    }
  }

  const proposeBtn = document.getElementById("proposeBtn");
  if (proposeBtn) {
    proposeBtn.onclick = async () => {
      if (!selectedKickoff) return;
      proposeBtn.disabled = true;
      setStatus("Sending proposal…");
      const res = await proposeKickoff(fixtureId, selectedKickoff);
      if (!res.ok) {
        setStatus(res.msg, true);
        proposeBtn.disabled = false;
        return;
      }
      setStatus("Proposal sent — check your inbox.");
      await reload();
    };
  }

  const acceptBtn = document.getElementById("acceptBtn");
  if (acceptBtn && pending) {
    acceptBtn.onclick = async () => {
      acceptBtn.disabled = true;
      setStatus("Accepting…");
      const res = await acceptProposal(pending.id);
      if (!res.ok) {
        setStatus(res.msg, !res.soft);
        acceptBtn.disabled = false;
        if (res.soft) await reload();
        return;
      }
      setStatus("Kick-off agreed.");
      await reload();
    };
  }
}

async function reload() {
  ctx = await loadScheduleContext(fixtureId);
  selectedKickoff = null;
  render();
}

document.addEventListener("DOMContentLoaded", async () => {
  fixtureId = parseFixtureId();
  if (!fixtureId) {
    setStatus("Missing fixture id.", true);
    return;
  }

  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();
  myClub.short = club?.ShortName || null;

  if (!myClub.short) {
    setStatus("No club linked to this account.", true);
    return;
  }

  try {
    await reload();
  } catch (err) {
    const msg = err.message || String(err);
    setStatus(
      msg.includes("match_schedule_fixture_context")
        ? "Scheduling not deployed — run supabase/sql/patches/match_scheduling_phase1.sql"
        : msg.includes("fixture_check_in")
          ? "Phase 2 not deployed — run supabase/sql/patches/match_scheduling_phase2.sql"
          : msg,
      true
    );
  }
});
