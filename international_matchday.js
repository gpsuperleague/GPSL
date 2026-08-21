/**
 * International matchday — arrange kickoff + national XI (pitch) + results.
 * Knockout: ET totals + penalty winner when level.
 */
import { supabase, initGlobal } from "./global.js";
import { loadMyNation, loadNationalSquad } from "./international.js";
import { loadCalendarStatus } from "./competition_calendar.js";
import { isFixtureMonthPlayable, GPSL_MONTH_LABELS } from "./competition.js";
import {
  formatKickoffPair,
  filterSelectableKickoffSlots,
  isSelectableKickoffSlot,
  formatOwnerNowLine,
  UK_TZ,
} from "./match_scheduling.js";
import {
  loadMatchSimStatus,
  matchSimBannerHtml,
  matchSimActionsHtml,
  wireMatchSimBannerToggle,
  wireMatchSimButtons,
  runMatchSimulation,
} from "./match_sim_ui.js";
import { initMatchdaySquadPanel } from "./matchday_squad.js?v=20260821-swap-remove";

/** Result entry: from agreed kickoff until +48h (soft guidance). */
const RESULT_WINDOW_HOURS_AFTER = 48;
/** National call-up size ≈ 26–28 → XI + deep bench */
const INTL_MAX_BENCH = 15;
const INTL_MAX_SQUAD = 28;

let myNation = null;
let fixtures = [];
let selectedId = null;
let pendingProposalId = null;
let pendingSubmissionId = null;
let callupRows = [];
let savedSquadRows = [];
let savedPitchLayout = null;
/** @type {ReturnType<typeof initMatchdaySquadPanel>|null} */
let squadPanelApi = null;
/** @type {{ enabled: boolean, isAdmin: boolean, isStaff?: boolean, error: string|null }} */
let matchSimStatus = { enabled: false, isAdmin: false, isStaff: false, error: null };
/** @type {any} */
let calendarStatus = null;
/** @type {any} */
let scheduleCtx = null;
/** @type {string|null} */
let selectedKickoffIso = null;

function $(id) {
  return document.getElementById(id);
}

function setStatus(msg, ok) {
  const el = $("pageStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = "status" + (ok === true ? " ok" : ok === false ? " err" : "");
}

function escapeHtml(t) {
  return String(t ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function phaseLabel(f) {
  if (f.phase === "qualifying") return `Qual · Group ${f.group_code || "?"} · MD ${f.match_no ?? "?"}`;
  if (f.phase === "finals_group") return `Finals · Group ${f.group_code || "?"} · MD ${f.match_no ?? "?"}`;
  if (f.phase === "knockout") {
    const st = String(f.knockout_stage || "").toLowerCase();
    const label =
      st === "third_place" || st === "third"
        ? "3rd place"
        : st
          ? st.toUpperCase()
          : "KO";
    return `KO · ${label} #${f.knockout_match_no ?? f.match_no ?? "?"}`;
  }
  return f.phase || "—";
}

function isKnockout(f) {
  return f?.phase === "knockout";
}

function readNum(id) {
  const v = Number($(id)?.value);
  return Number.isFinite(v) ? v : NaN;
}

function selectedPenWinner() {
  const el = document.querySelector('input[name="penWinner"]:checked');
  return el?.value || null;
}

function updateKoScoreUi() {
  const f = fixtures.find((x) => x.id === selectedId);
  const etRow = $("koEtRow");
  const penRow = $("koPenRow");
  const hint = $("scorePeriodHint");
  if (hint) hint.hidden = !isKnockout(f);

  if (!isKnockout(f)) {
    if (etRow) etRow.hidden = true;
    if (penRow) penRow.hidden = true;
    return;
  }

  const home90 = readNum("homeGoals");
  const away90 = readNum("awayGoals");
  const level90 =
    Number.isFinite(home90) && Number.isFinite(away90) && home90 === away90;

  if (!level90) {
    if (etRow) etRow.hidden = true;
    if (penRow) penRow.hidden = true;
    if ($("etHomeGoals")) $("etHomeGoals").value = "";
    if ($("etAwayGoals")) $("etAwayGoals").value = "";
    document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
      el.checked = false;
    });
    if ($("etPreview")) $("etPreview").textContent = "";
    return;
  }

  if (etRow) etRow.hidden = false;
  if ($("etHomeLabel")) {
    $("etHomeLabel").textContent = `${f.home_nation_name || f.home_nation} ET total`;
  }
  if ($("etAwayLabel")) {
    $("etAwayLabel").textContent = `${f.away_nation_name || f.away_nation} ET total`;
  }

  const etHome = readNum("etHomeGoals");
  const etAway = readNum("etAwayGoals");
  const etEntered = Number.isFinite(etHome) && Number.isFinite(etAway);

  if (!etEntered) {
    if (penRow) penRow.hidden = true;
    if ($("etPreview")) $("etPreview").textContent = "";
    document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
      el.checked = false;
    });
    return;
  }

  if (etHome < home90 || etAway < away90) {
    if ($("etPreview")) {
      $("etPreview").textContent =
        "ET totals cannot be lower than the 90-minute score.";
    }
    if (penRow) penRow.hidden = true;
    return;
  }

  if ($("etPreview")) {
    $("etPreview").textContent = `After extra time: ${etHome}–${etAway} (90 min was ${home90}–${away90})`;
  }

  if (etHome === etAway) {
    if (penRow) penRow.hidden = false;
    if ($("penWinnerHomeLabel")) {
      $("penWinnerHomeLabel").textContent = f.home_nation_name || f.home_nation;
    }
    if ($("penWinnerAwayLabel")) {
      $("penWinnerAwayLabel").textContent = f.away_nation_name || f.away_nation;
    }
  } else {
    if (penRow) penRow.hidden = true;
    document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
      el.checked = false;
    });
  }
}

function buildKoPayload() {
  const f = fixtures.find((x) => x.id === selectedId);
  const home90 = readNum("homeGoals");
  const away90 = readNum("awayGoals");
  if (!Number.isFinite(home90) || !Number.isFinite(away90) || home90 < 0 || away90 < 0) {
    return { error: "Enter a valid 90-minute score." };
  }

  const payload = {
    p_fixture_id: selectedId,
    p_home_goals: home90,
    p_away_goals: away90,
    p_home_goals_et: null,
    p_away_goals_et: null,
    p_home_pens: null,
    p_away_pens: null,
  };

  if (!isKnockout(f)) return { payload };

  if (home90 !== away90) return { payload };

  const etHome = readNum("etHomeGoals");
  const etAway = readNum("etAwayGoals");
  if (!Number.isFinite(etHome) || !Number.isFinite(etAway)) {
    return { error: "Level after 90 — enter total score after extra time." };
  }
  if (etHome < home90 || etAway < away90) {
    return { error: "ET totals cannot be lower than the 90-minute score." };
  }
  payload.p_home_goals_et = etHome;
  payload.p_away_goals_et = etAway;

  if (etHome === etAway) {
    const winner = selectedPenWinner();
    if (!winner) {
      return { error: "Still level after ET — select the penalty shootout winner." };
    }
    // Backend compares pen counts; 1–0 encodes the winner.
    payload.p_home_pens = winner === "home" ? 1 : 0;
    payload.p_away_pens = winner === "away" ? 1 : 0;
  }

  return { payload };
}

function renderCheckin(f) {
  const box = $("checkinBox");
  if (!box) return;
  if (f.played) {
    box.hidden = true;
    return;
  }
  box.hidden = false;

  if (!f.agreed_kickoff_at) {
    box.className = "checkin-box warn";
    box.innerHTML =
      "<b>Kickoff not agreed yet.</b> Propose/accept a time before matchday. You can still submit a result once both sides are ready.";
    return;
  }

  const kick = new Date(f.agreed_kickoff_at);
  const now = new Date();
  const close = new Date(kick.getTime() + RESULT_WINDOW_HOURS_AFTER * 3600 * 1000);
  const kickLabel = kick.toLocaleString();
  const closeLabel = close.toLocaleString();

  if (now < kick) {
    box.className = "checkin-box warn";
    box.innerHTML = `<b>Arranged:</b> ${escapeHtml(kickLabel)} · Result entry opens at kickoff (confirm after you play).`;
  } else if (now <= close) {
    box.className = "checkin-box open";
    box.innerHTML = `<b>Result window open</b> until ${escapeHtml(closeLabel)} (48h after kickoff). Submit → opponent confirms.`;
  } else {
    box.className = "checkin-box closed";
    box.innerHTML = `<b>Result window ended</b> (${escapeHtml(closeLabel)}). Contact admin if the score still needs posting.`;
  }
}

function renderNextIntl() {
  const el = $("nextIntlBanner");
  if (!el) return;
  const next = fixtures.find((f) => !f.played);
  if (!next) {
    el.hidden = true;
    return;
  }
  el.hidden = false;
  const when = next.agreed_kickoff_at
    ? new Date(next.agreed_kickoff_at).toLocaleString()
    : next.gpsl_month
      ? `${String(next.gpsl_month).charAt(0).toUpperCase()}${String(next.gpsl_month).slice(1)}${
          next.season_label ? ` · ${next.season_label}` : ""
        }`
      : "date TBC";
  el.innerHTML = `<b>Next up:</b> ${escapeHtml(next.home_nation_name || next.home_nation)} vs ${escapeHtml(
    next.away_nation_name || next.away_nation
  )} · ${escapeHtml(phaseLabel(next))} · ${escapeHtml(when)}
    <a href="?fixture=${next.id}" style="margin-left:8px;">Open</a>`;
}

async function loadSavedSquad() {
  savedSquadRows = [];
  savedPitchLayout = null;
  if (!myNation?.code) return;
  const [{ data: players }, { data: header }] = await Promise.all([
    supabase
      .from("international_matchday_squad_player")
      .select("player_id, slot_kind, pitch_slot, sort_order")
      .eq("nation_code", myNation.code)
      .order("sort_order", { ascending: true }),
    supabase
      .from("international_matchday_squad")
      .select("pitch_layout")
      .eq("nation_code", myNation.code)
      .maybeSingle(),
  ]);
  savedSquadRows = players || [];
  savedPitchLayout = header?.pitch_layout || null;
}

function callupAsMatchdayPlayers() {
  return (callupRows || []).map((p) => ({
    Konami_ID: String(p.player_id),
    player_id: String(p.player_id),
    Name: p.player_name || String(p.player_id),
    player_name: p.player_name || String(p.player_id),
    Position: String(p.player_position || "").toUpperCase(),
    Preferred_Position: p.player_position || "",
    Rating: Number(p.rating || p.overall || 0) || 0,
  }));
}

function initOrRefreshSquadPanel() {
  const root = $("matchdaySquadRoot");
  if (!root) return;
  if (!callupRows.length) {
    root.innerHTML =
      '<p class="note" style="padding:10px;">No active call-ups — build your 26–28 on <a href="national_team.html">National team</a>.</p>';
    squadPanelApi = null;
    return;
  }
  const allPlayers = callupAsMatchdayPlayers();
  squadPanelApi = initMatchdaySquadPanel({
    root,
    allPlayers,
    savedRows: savedSquadRows,
    savedPitchLayout,
    savedFormations: [],
    maxBench: INTL_MAX_BENCH,
    maxSquad: INTL_MAX_SQUAD,
    onSave: async (slots, pitchLayout) => {
      const statusEl = $("squadPanelStatus");
      if (statusEl) statusEl.textContent = "Saving…";
      const { error } = await supabase.rpc("international_save_matchday_squad", {
        p_players: slots,
        p_pitch_layout: pitchLayout || {},
      });
      if (error) {
        if (statusEl) statusEl.textContent = "";
        throw new Error(error.message);
      }
      await loadSavedSquad();
      if (statusEl) {
        statusEl.textContent = `✅ Saved ${slots.length} players (nation default).`;
      }
      setStatus("✅ Default national squad saved", true);
    },
    onChange: () => {},
  });
}

function setMatchdayTab(tab) {
  document.querySelectorAll(".matchday-tabs button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === tab);
  });
  document.querySelectorAll(".tab-panel").forEach((panel) => {
    panel.classList.toggle("active", panel.dataset.panel === tab);
  });
  if (tab === "squad") initOrRefreshSquadPanel();
}

function isHomeFixture(f) {
  return f?.home_nation === myNation?.code;
}

/** Button label — always opens the fixture; wording reflects whose turn it is. */
function fixtureActionMeta(f) {
  const sch = String(f.schedule_status || "unscheduled").toLowerCase();
  const home = isHomeFixture(f);
  if (f.played) {
    return { label: "Open", cls: "", tab: "result" };
  }
  if (f._needsAccept) {
    return { label: "Accept", cls: "accept-btn", tab: "kickoff" };
  }
  if (sch === "agreed") {
    return { label: "Open", cls: "", tab: "result" };
  }
  if (sch === "negotiating" && f._pendingFromMe) {
    return { label: "Waiting", cls: "waiting-btn", tab: "kickoff" };
  }
  if (sch === "negotiating") {
    return { label: "Respond", cls: "accept-btn", tab: "kickoff" };
  }
  if (sch === "unscheduled") {
    return home
      ? { label: "Arrange", cls: "", tab: "kickoff" }
      : { label: "Waiting", cls: "waiting-btn", tab: "kickoff" };
  }
  return { label: "Open", cls: "", tab: "kickoff" };
}

async function loadFixtures() {
  myNation = await loadMyNation(supabase);
  const banner = $("nationBanner");
  const link = $("nationLink");

  if (!myNation?.code) {
    if (banner) banner.textContent = "You do not have a national team assigned.";
    $("fixtureList").innerHTML = `<p class="note">Claim a nation on Nation selection first.</p>`;
    return;
  }

  if (banner) {
    banner.innerHTML = `<b>${escapeHtml(
      myNation.name || myNation.code
    )}</b> (${escapeHtml(myNation.code)})`;
  }
  if (link) {
    link.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
  }

  const code = myNation.code;
  const { data, error } = await supabase
    .from("international_fixtures_public")
    .select("*")
    .or(`home_nation.eq.${code},away_nation.eq.${code}`)
    .order("cycle_no", { ascending: false })
    .order("match_no", { ascending: true });

  if (error) {
    $("fixtureList").innerHTML = `<p class="note">❌ ${escapeHtml(
      error.message
    )} — run international WC engine patches</p>`;
    return;
  }

  fixtures = data || [];
  callupRows = await loadNationalSquad(code, supabase);
  await loadSavedSquad();
  await enrichNegotiatingFixtures();
  renderList();
  renderActionNeeded();
  renderNextIntl();
  initOrRefreshSquadPanel();

  const params = new URLSearchParams(location.search);
  const qid = Number(params.get("fixture") || 0);
  if (qid) {
    selectFixture(qid);
  } else {
    const needsYou = fixtures.find((f) => f._needsAccept);
    if (needsYou) selectFixture(needsYou.id);
  }
}

/** Load pending proposal details for negotiating fixtures so Accept is discoverable. */
async function enrichNegotiatingFixtures() {
  const pending = fixtures.filter(
    (f) => !f.played && String(f.schedule_status || "").toLowerCase() === "negotiating"
  );
  await Promise.all(
    pending.map(async (f) => {
      try {
        const { data, error } = await supabase.rpc(
          "international_match_schedule_fixture_context",
          { p_fixture_id: f.id }
        );
        if (error || !data?.pending_proposal) return;
        const prop = data.pending_proposal;
        f._pendingProposal = prop;
        f._canRespond = !!data.can_respond;
        f._pendingFromMe = prop.proposed_by_nation === myNation?.code;
        f._myClub = data.my_club_short_name || null;
        f._needsAccept =
          !!data.can_respond &&
          !f._pendingFromMe &&
          isSelectableKickoffSlot(prop.kickoff_at, data.my_timezone || UK_TZ);
        f._pendingLabel = formatKickoffPair(
          prop.kickoff_at,
          data.home_timezone || UK_TZ,
          data.away_timezone || UK_TZ
        );
      } catch {
        /* ignore */
      }
    })
  );
}

function renderActionNeeded() {
  const box = $("actionNeededBanner");
  if (!box) return;
  const rows = fixtures.filter((f) => f._needsAccept);
  if (!rows.length) {
    box.hidden = true;
    box.innerHTML = "";
    return;
  }
  box.hidden = false;
  box.innerHTML = `
    <b>Kick-off waiting for you</b> — open the fixture and click <b>Accept pending proposal</b>.
    <ul>
      ${rows
        .map(
          (f) => `<li>
            ${escapeHtml(f.home_nation_name || f.home_nation)} vs
            ${escapeHtml(f.away_nation_name || f.away_nation)}
            ${f._pendingLabel ? ` · ${escapeHtml(f._pendingLabel)}` : ""}
            <button type="button" data-id="${f.id}" class="open-accept">Review &amp; accept</button>
          </li>`
        )
        .join("")}
    </ul>`;
  box.querySelectorAll(".open-accept").forEach((btn) => {
    btn.addEventListener("click", () => {
      selectFixture(Number(btn.dataset.id));
      $("scheduleBlock")?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
  });
}

function renderList() {
  const root = $("fixtureList");
  if (!fixtures.length) {
    root.innerHTML = `<p class="note">No international fixtures for your nation yet.</p>`;
    return;
  }

  root.innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Phase</th>
          <th>Match</th>
          <th>Score</th>
          <th>Schedule</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${fixtures
          .map((f) => {
            const score = f.played
              ? `${f.home_goals}–${f.away_goals}`
              : "–";
            const sch = String(f.schedule_status || "unscheduled").toLowerCase();
            const home = isHomeFixture(f);
            const action = fixtureActionMeta(f);
            let schHtml = escapeHtml(sch);
            if (f._needsAccept) {
              schHtml = `<span class="sch-action">Your turn — accept or counter</span>${
                f._pendingLabel
                  ? `<br><span class="note">${escapeHtml(f._pendingLabel)}</span>`
                  : ""
              }`;
            } else if (sch === "negotiating" && f._pendingFromMe) {
              schHtml = `<span class="sch-waiting">Waiting for opponent</span>${
                f._pendingLabel
                  ? `<br><span class="note">${escapeHtml(f._pendingLabel)}</span>`
                  : ""
              }`;
            } else if (sch === "negotiating" && !f._myClub) {
              schHtml = `<span style="color:#f88;">Link club to respond</span>${
                f._pendingLabel
                  ? `<br><span class="note">${escapeHtml(f._pendingLabel)}</span>`
                  : ""
              }`;
            } else if (sch === "negotiating" && f._pendingLabel) {
              schHtml = `<span class="sch-action">Respond to proposal</span><br><span class="note">${escapeHtml(
                f._pendingLabel
              )}</span>`;
            } else if (sch === "unscheduled") {
              schHtml = home
                ? `<span class="sch-action">Unscheduled — you propose</span>`
                : `<span class="sch-waiting">Waiting for home to propose</span>`;
            } else if (f.agreed_kickoff_at) {
              schHtml = `<span class="sch-muted">Agreed</span><br><span class="note">${escapeHtml(
                new Date(f.agreed_kickoff_at).toLocaleString()
              )}</span>`;
            }
            const rowCls = [
              f.id === selectedId ? "active" : "",
              f._needsAccept ? "needs-you" : "",
              action.label === "Waiting" ? "waiting-row" : "",
            ]
              .filter(Boolean)
              .join(" ");
            return `<tr class="${rowCls}" data-id="${f.id}">
              <td>${escapeHtml(phaseLabel(f))}</td>
              <td>${escapeHtml(f.home_nation_name || f.home_nation)}
                vs ${escapeHtml(f.away_nation_name || f.away_nation)}</td>
              <td>${escapeHtml(score)}</td>
              <td>${schHtml}</td>
              <td><button type="button" class="button secondary pick-fix ${escapeHtml(
                action.cls
              )}" data-id="${f.id}" data-tab="${escapeHtml(action.tab)}">${escapeHtml(
              action.label
            )}</button></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  root.querySelectorAll(".pick-fix").forEach((btn) => {
    btn.addEventListener("click", () => {
      selectFixture(Number(btn.dataset.id), btn.dataset.tab || "kickoff");
    });
  });
}

async function selectFixture(id, preferTab) {
  selectedId = id;
  pendingProposalId = null;
  pendingSubmissionId = null;
  renderList();

  const f = fixtures.find((x) => x.id === id);
  const panel = $("detailPanel");
  if (!f || !panel) return;
  panel.hidden = false;
  const action = fixtureActionMeta(f);
  const tab = preferTab || action.tab || "kickoff";
  setMatchdayTab(tab);
  requestAnimationFrame(() => {
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  $("detailTitle").textContent = `${f.home_nation_name || f.home_nation} vs ${
    f.away_nation_name || f.away_nation
  }`;
  $("detailMeta").textContent = `${phaseLabel(f)} · ${
    f.played ? "Played" : "Not played"
  } · schedule: ${f.schedule_status || "unscheduled"}`;

  if ($("homeGoalsLabel")) {
    $("homeGoalsLabel").textContent = `${f.home_nation_name || f.home_nation} (90)`;
  }
  if ($("awayGoalsLabel")) {
    $("awayGoalsLabel").textContent = `${f.away_nation_name || f.away_nation} (90)`;
  }

  $("homeGoals").value = f.home_goals ?? 0;
  $("awayGoals").value = f.away_goals ?? 0;
  if ($("etHomeGoals")) $("etHomeGoals").value = "";
  if ($("etAwayGoals")) $("etAwayGoals").value = "";
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.checked = false;
  });
  $("submitBtn").disabled = !!f.played;

  renderCheckin(f);
  updateKoScoreUi();
  renderIntlSimActions(f);
  await renderSchedulePanel(f);

  const { data: subs } = await supabase
    .from("international_result_submissions")
    .select("*")
    .eq("fixture_id", id)
    .eq("status", "pending")
    .limit(1);

  const sub = subs?.[0];
  const confirmBtn = $("confirmBtn");
  const rejectBtn = $("rejectBtn");
  if (sub && sub.submitted_by_nation !== myNation.code) {
    pendingSubmissionId = sub.id;
    confirmBtn.hidden = false;
    rejectBtn.hidden = false;
    $("homeGoals").value = sub.home_goals;
    $("awayGoals").value = sub.away_goals;
    if (sub.home_goals_et != null && $("etHomeGoals")) {
      $("etHomeGoals").value = sub.home_goals_et;
      $("etAwayGoals").value = sub.away_goals_et;
    }
    if (sub.home_pens != null && sub.away_pens != null) {
      const homeWins = Number(sub.home_pens) > Number(sub.away_pens);
      const el = $(homeWins ? "penWinnerHome" : "penWinnerAway");
      if (el) el.checked = true;
    }
    updateKoScoreUi();
    setStatus(
      `Pending result from ${sub.submitted_by_nation}: ${sub.home_goals}–${sub.away_goals}`,
      null
    );
  } else {
    confirmBtn.hidden = true;
    rejectBtn.hidden = true;
    if (sub) {
      setStatus(`Waiting for opponent to confirm your ${sub.home_goals}–${sub.away_goals}`, null);
    } else {
      setStatus("", null);
    }
  }
}

async function renderSchedulePanel(f) {
  selectedKickoffIso = null;
  pendingProposalId = null;
  scheduleCtx = null;
  const meta = $("scheduleMeta");
  const list = $("kickoffSlotList");
  const pendingPanel = $("pendingSchedulePanel");
  const historyEl = $("proposalHistory");
  const proposeBtn = $("proposeBtn");
  const acceptBtn = $("acceptBtn");
  const withdrawBtn = $("withdrawBtn");
  const statusEl = $("scheduleStatus");

  if (list) list.innerHTML = "";
  if (pendingPanel) {
    pendingPanel.hidden = true;
    pendingPanel.innerHTML = "";
  }
  if (historyEl) {
    historyEl.hidden = true;
    historyEl.innerHTML = "";
  }
  if (proposeBtn) {
    proposeBtn.disabled = true;
    proposeBtn.hidden = false;
    proposeBtn.textContent = "Propose kick-off";
  }
  if (acceptBtn) acceptBtn.hidden = true;
  if (withdrawBtn) withdrawBtn.hidden = true;
  if (statusEl) statusEl.textContent = "";

  if (!f || f.played) {
    if (meta) meta.textContent = "Fixture already played.";
    return;
  }

  if (meta) meta.textContent = "Loading schedule slots…";

  const { data, error } = await supabase.rpc(
    "international_match_schedule_fixture_context",
    { p_fixture_id: f.id }
  );

  if (error) {
    if (meta) {
      meta.textContent = `❌ ${error.message} — run patches/international_kickoff_club_parity_20260819.sql`;
    }
    return;
  }

  scheduleCtx = data;
  const sch = data.schedule || {};
  const pending = data.pending_proposal;
  const homeTz = data.home_timezone || UK_TZ;
  const awayTz = data.away_timezone || UK_TZ;
  const ownerTz = data.my_timezone || UK_TZ;
  const monthKey = data.proposal_window?.gpsl_month || f.gpsl_month;
  const monthLabel = GPSL_MONTH_LABELS[monthKey] || monthKey || "—";
  const recent = Array.isArray(data.recent_proposals) ? data.recent_proposals : [];
  const oppLabel =
    data.my_role === "away"
      ? data.fixture?.home_nation_name || data.fixture?.home_nation || "Home"
      : data.fixture?.away_nation_name || data.fixture?.away_nation || "Away";

  if (meta) {
    meta.textContent =
      `${monthLabel} · Your role: ${data.my_role || "—"} · ${formatOwnerNowLine(ownerTz)}` +
      (data.away_vacant || data.home_vacant
        ? " · Vacant nation(s) in this fixture — kick-off auto-agrees if you propose vs vacant."
        : "");
  }

  if (historyEl && recent.length) {
    historyEl.hidden = false;
    historyEl.innerHTML =
      `<b>Proposal history</b><ul style="margin:6px 0 0;padding-left:18px;">` +
      recent
        .map((p) => {
          const who =
            p.proposed_by_nation === myNation?.code
              ? "You"
              : escapeHtml(p.proposed_by_nation || "?");
          const when = escapeHtml(
            formatKickoffPair(p.kickoff_at, homeTz, awayTz)
          );
          const st = escapeHtml(p.status || "");
          return `<li>${who}: ${when} <span style="opacity:.75;">(${st})</span></li>`;
        })
        .join("") +
      `</ul>`;
  }

  if (sch.status === "agreed" && sch.agreed_kickoff_at) {
    if (statusEl) {
      statusEl.textContent = `Agreed: ${formatKickoffPair(
        sch.agreed_kickoff_at,
        homeTz,
        awayTz
      )}`;
    }
    if (proposeBtn) proposeBtn.disabled = true;
    return;
  }

  if (pending) {
    pendingProposalId = pending.id;
    const fromOpp = pending.proposed_by_nation !== myNation?.code;
    const stillValid = isSelectableKickoffSlot(pending.kickoff_at, ownerTz);
    if (pendingPanel) {
      pendingPanel.hidden = false;
      pendingPanel.innerHTML = `
        <p style="color:#fc6;margin:0 0 8px;font-size:14px;">
          <b>${escapeHtml(
            pending.proposed_by_nation === myNation?.code
              ? "You"
              : pending.proposed_by_nation
          )}</b> proposed
          <b>${escapeHtml(formatKickoffPair(pending.kickoff_at, homeTz, awayTz))}</b>
        </p>
        ${
          fromOpp && data.can_respond && stillValid
            ? `<p class="note" style="margin:0 0 8px;color:#9cdc9c;">Click <b>Accept pending proposal</b>, or pick one of your slots below to <b>Counter-propose</b> (same as league/cup).</p>`
            : ""
        }
        ${
          !fromOpp
            ? `<p class="note" style="margin:0 0 8px;color:#fc6;">
                <b>You</b> hold the pending offer — waiting for <b>${escapeHtml(oppLabel)}</b> to Accept or Counter.
                You can <b>Withdraw my proposal</b> to reset.
              </p>`
            : ""
        }
        ${
          !stillValid
            ? `<p class="note" style="color:#f88;margin:0;">This time has passed — counter-propose a future slot from your availability.</p>`
            : ""
        }
      `;
    }
    if (acceptBtn) {
      acceptBtn.hidden = !(fromOpp && data.can_respond && stillValid);
      if (!acceptBtn.hidden) {
        acceptBtn.textContent = "Accept pending proposal";
        acceptBtn.focus();
      }
    }
    if (withdrawBtn) {
      withdrawBtn.hidden = !(data.can_withdraw || (!fromOpp && pending));
    }
    if (statusEl && fromOpp && !data.can_respond) {
      statusEl.textContent =
        "Cannot respond yet — check you have a nation club linked.";
    } else if (statusEl && !fromOpp) {
      statusEl.textContent =
        "Your proposal is pending — opponent must Accept or Counter (or you can withdraw).";
    }
  }

  const slotPanel = $("slotPickerPanel");
  if (slotPanel) slotPanel.hidden = false;

  // Club parity: show slots when you can open (home) or respond (accept/counter turn).
  // Extra guard: away + unscheduled never shows a picker (even if staff flags leak).
  const waitingOnHome =
    !pending &&
    String(sch.status || "").toLowerCase() === "unscheduled" &&
    data.my_role === "away";
  const canPick =
    !waitingOnHome &&
    !!(data.can_propose_first || data.can_respond || data.can_propose);

  if (proposeBtn) {
    proposeBtn.hidden = !canPick;
    proposeBtn.textContent = data.can_propose_first
      ? "Propose kick-off"
      : data.can_respond
        ? "Counter-propose"
        : "Propose kick-off";
  }

  if (!canPick) {
    if (waitingOnHome && statusEl) {
      statusEl.textContent = `Waiting for ${oppLabel} (home) to propose a kick-off — then you can Accept or Counter (same as league/cup).`;
    } else if (!pending && data.my_role === "away" && statusEl) {
      statusEl.textContent =
        "Home nation must propose first — then you can Accept or Counter (same as league/cup).";
    }
    if (!data.my_club_short_name && statusEl) {
      statusEl.textContent =
        "No owner club on your nation — cannot arrange kick-off from availability.";
    }
    if (list) list.innerHTML = "";
    if (slotPanel) slotPanel.hidden = true;
    if (proposeBtn) proposeBtn.hidden = true;
    return;
  }

  if (slotPanel) slotPanel.hidden = false;

  const rawSlots = Array.isArray(data.my_window_slots) ? data.my_window_slots : [];
  const slots = rawSlots
    .map((s) => (typeof s === "string" ? s : s?.kickoff_at || String(s)))
    .filter(Boolean);
  const selectable = filterSelectableKickoffSlots(slots, ownerTz);

  if (!list) return;
  if (!selectable.length) {
    list.innerHTML =
      '<p class="note" style="color:#888;">No available slots in this GPSL month. Set weekly availability on Owner Details (and wait until the month unlocks).</p>';
    return;
  }
  for (const iso of selectable) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "slot-btn";
    btn.innerHTML = formatKickoffPair(iso, homeTz, awayTz).replace(/ · /g, "<br>");
    btn.onclick = () => {
      selectedKickoffIso = iso;
      list.querySelectorAll(".slot-btn").forEach((b) => b.classList.remove("selected"));
      btn.classList.add("selected");
      if (proposeBtn) proposeBtn.disabled = false;
    };
    list.appendChild(btn);
  }
}

function renderIntlSimActions(f) {
  const row = $("intlSimRow");
  if (!row) return;
  if (!f || f.played || !matchSimStatus.enabled) {
    row.innerHTML = "";
    return;
  }
  const canSim = isFixtureMonthPlayable(f, myNation?.club_short_name || {}, calendarStatus, null);
  row.innerHTML = matchSimActionsHtml(f.id, {
    disabled: !canSim,
    title: canSim
      ? "Uses the same match simulation engine as league & cup (while sim is ON)"
      : "Available when this fixture’s GPSL month is active",
  });
  wireMatchSimButtons(row, async (id, btn, mode) => {
    if (btn?.disabled) return;
    const fix = fixtures.find((x) => String(x.id) === String(id));
    if (!isFixtureMonthPlayable(fix, myNation?.club_short_name || {}, calendarStatus, null)) {
      setStatus("Simulation unlocks when this fixture’s GPSL month is active.", false);
      return;
    }
    const play = mode === "play";
    if (
      !confirm(
        play
          ? `Simulate this international?\n\nPlays a ~20s graphic, then finalises (no opponent confirm).`
          : `Instant result for this international?\n\nFinalises immediately (no opponent confirm).`
      )
    ) {
      return;
    }
    setStatus(play ? "Simulating…" : "Generating result…");
    try {
      const data = await runMatchSimulation(id, btn, mode, {
        rpc: "international_simulate_fixture_result",
        homeName: fix?.home_nation_name || fix?.home_nation,
        awayName: fix?.away_nation_name || fix?.away_nation,
      });
      const score =
        data?.home_goals != null ? `${data.home_goals}–${data.away_goals}` : "";
      setStatus(`✅ Simulated ${score}`, true);
      await loadFixtures();
      await selectFixture(Number(id));
    } catch (err) {
      setStatus(`❌ ${err?.message || "Simulation failed"}`, false);
    }
  });
}

function renderSimBanner() {
  const host = $("matchSimBannerHost");
  if (!host) return;
  host.innerHTML = matchSimBannerHtml(matchSimStatus);
  wireMatchSimBannerToggle(async () => {
    matchSimStatus = await loadMatchSimStatus();
    renderSimBanner();
    if (selectedId) {
      const f = fixtures.find((x) => x.id === selectedId);
      if (f) renderIntlSimActions(f);
    }
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  matchSimStatus = await loadMatchSimStatus();
  calendarStatus = await loadCalendarStatus(supabase);
  renderSimBanner();
  await loadFixtures();

  ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"].forEach((id) => {
    $(id)?.addEventListener("input", updateKoScoreUi);
  });
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.addEventListener("change", updateKoScoreUi);
  });

  $("proposeBtn")?.addEventListener("click", async () => {
    if (!selectedId || !selectedKickoffIso) {
      setStatus("Pick a kick-off slot first.", false);
      return;
    }
    const isCounter = $("proposeBtn")?.textContent === "Counter-propose";
    if (
      isCounter &&
      !confirm(
        "Counter-propose replaces their pending kick-off (same as league/cup). They will need to Accept or Counter your new time. Continue?"
      )
    ) {
      return;
    }
    setStatus("Proposing…");
    const { error } = await supabase.rpc("international_propose_kickoff", {
      p_fixture_id: selectedId,
      p_kickoff_at: selectedKickoffIso,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus(isCounter ? "✅ Counter-proposed" : "✅ Kickoff proposed", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  $("withdrawBtn")?.addEventListener("click", async () => {
    if (!selectedId) return;
    if (
      !confirm(
        "Withdraw your pending kick-off? The fixture goes back to unscheduled so home can propose again."
      )
    ) {
      return;
    }
    setStatus("Withdrawing…");
    const { error } = await supabase.rpc("international_withdraw_kickoff_proposal", {
      p_fixture_id: selectedId,
    });
    if (error) {
      setStatus(
        `❌ ${error.message} — run patches/international_kickoff_withdraw_20260818.sql`,
        false
      );
      return;
    }
    setStatus("✅ Proposal withdrawn — home can propose again", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  $("acceptBtn")?.addEventListener("click", async () => {
    if (!pendingProposalId) return;
    setStatus("Accepting…");
    const { error } = await supabase.rpc("international_accept_kickoff", {
      p_proposal_id: pendingProposalId,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("✅ Kickoff agreed", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  $("submitBtn")?.addEventListener("click", async () => {
    if (!selectedId) return;
    const built = buildKoPayload();
    if (built.error) {
      setStatus(built.error, false);
      return;
    }
    let stats = [];
    const raw = $("statsJson")?.value?.trim();
    if (raw) {
      try {
        stats = JSON.parse(raw);
      } catch {
        setStatus("Invalid stats JSON.", false);
        return;
      }
    }
    setStatus("Submitting…");
    const { error } = await supabase.rpc("international_submit_result", {
      ...built.payload,
      p_player_stats: stats,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("✅ Result submitted — waiting for opponent", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  $("confirmBtn")?.addEventListener("click", async () => {
    if (!pendingSubmissionId) return;
    let stats = [];
    const raw = $("statsJson")?.value?.trim();
    if (raw) {
      try {
        stats = JSON.parse(raw);
      } catch {
        setStatus("Invalid confirmer stats JSON.", false);
        return;
      }
    }
    setStatus("Confirming…");
    const { error } = await supabase.rpc("international_confirm_result", {
      p_submission_id: pendingSubmissionId,
      p_confirmer_player_stats: stats,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("✅ Result confirmed", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  $("rejectBtn")?.addEventListener("click", async () => {
    if (!pendingSubmissionId) return;
    if (!confirm("Reject this result submission?")) return;
    const { error } = await supabase.rpc("international_reject_result", {
      p_submission_id: pendingSubmissionId,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("Rejected.", true);
    await loadFixtures();
    await selectFixture(selectedId);
  });

  document.querySelectorAll(".matchday-tabs button").forEach((btn) => {
    btn.addEventListener("click", () => setMatchdayTab(btn.dataset.tab));
  });
});
