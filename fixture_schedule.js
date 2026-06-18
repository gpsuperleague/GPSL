import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS } from "./competition.js";
import {
  loadScheduleContext,
  proposeKickoff,
  acceptProposal,
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

  if (sch.status === "agreed" && sch.agreed_kickoff_at) {
    const homeTz = ctx.home_timezone || UK_TZ;
    const awayTz = ctx.away_timezone || UK_TZ;
    root.innerHTML = `
      <div class="panel">
        <div class="fixture-head">${f.home_club_short_name} vs ${f.away_club_short_name}</div>
        <p class="status-agreed"><b>Kick-off agreed:</b> ${formatKickoffPair(sch.agreed_kickoff_at, homeTz, awayTz)}</p>
        <p class="meta">Result entry opens on Match Day when the GPSL month is live (or during holiday early play).</p>
        <div class="actions">
          <a href="matchday.html?fixture=${f.id}" class="button secondary" style="text-decoration:none;display:inline-block;">Match Day</a>
        </div>
      </div>
    `;
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
          <b>${pending.proposed_by_club_short_name}</b> proposed
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
      <div class="fixture-head">${f.home_club_short_name} vs ${f.away_club_short_name}</div>
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
        setStatus(res.msg, true);
        acceptBtn.disabled = false;
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
        : msg,
      true
    );
  }
});
