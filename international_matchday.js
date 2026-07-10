/**
 * International matchday — arrange kickoff + submit/confirm results for your nation.
 * Knockout: ET totals + penalty winner when level.
 */
import { supabase, initGlobal } from "./global.js";
import { loadMyNation, loadNationalSquad } from "./international.js";

/** Result entry: from agreed kickoff until +48h (soft guidance). */
const RESULT_WINDOW_HOURS_AFTER = 48;

let myNation = null;
let fixtures = [];
let selectedId = null;
let pendingProposalId = null;
let pendingSubmissionId = null;
let callupRows = [];
let savedSquadByPlayer = new Map();

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
  savedSquadByPlayer = new Map();
  if (!myNation?.code) return;
  const { data } = await supabase
    .from("international_matchday_squad_player")
    .select("player_id, slot_kind, pitch_slot, sort_order")
    .eq("nation_code", myNation.code);
  for (const row of data || []) {
    savedSquadByPlayer.set(String(row.player_id), row);
  }
}

function renderSquadPicker() {
  const root = $("squadPicker");
  const countEl = $("squadCount");
  if (!root) return;
  if (!callupRows.length) {
    root.innerHTML = `<p class="note" style="padding:10px;">No active call-ups — build your 23 on <a href="national_team.html">National team</a> / GPDB.</p>`;
    if (countEl) countEl.textContent = "";
    return;
  }

  const rows = callupRows
    .slice()
    .sort((a, b) =>
      String(a.player_name || a.player_id).localeCompare(String(b.player_name || b.player_id))
    );

  root.innerHTML = `
    <table>
      <thead>
        <tr><th>Player</th><th>Pos</th><th>Role</th></tr>
      </thead>
      <tbody>
        ${rows
          .map((p) => {
            const id = String(p.player_id);
            const saved = savedSquadByPlayer.get(id);
            const kind = saved?.slot_kind || "";
            return `<tr data-pid="${escapeHtml(id)}">
              <td>${escapeHtml(p.player_name || id)}</td>
              <td>${escapeHtml(p.player_position || "—")}</td>
              <td>
                <select class="squad-role">
                  <option value="" ${!kind ? "selected" : ""}>—</option>
                  <option value="pitch" ${kind === "pitch" ? "selected" : ""}>Pitch (XI)</option>
                  <option value="bench" ${kind === "bench" ? "selected" : ""}>Bench</option>
                  <option value="reserve" ${kind === "reserve" ? "selected" : ""}>Reserve</option>
                </select>
              </td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  const syncCount = () => {
    let pitch = 0;
    let bench = 0;
    root.querySelectorAll(".squad-role").forEach((sel) => {
      if (sel.value === "pitch") pitch += 1;
      if (sel.value === "bench") bench += 1;
    });
    if (countEl) {
      countEl.textContent = `XI ${pitch}/11 · Bench ${bench}/7`;
      countEl.style.color = pitch === 11 ? "#8d8" : "#d4b85a";
    }
  };
  root.querySelectorAll(".squad-role").forEach((sel) => {
    sel.addEventListener("change", syncCount);
  });
  syncCount();
}

function collectSquadPayload() {
  const root = $("squadPicker");
  const players = [];
  let ord = 0;
  root?.querySelectorAll("tbody tr").forEach((tr) => {
    const pid = tr.getAttribute("data-pid");
    const kind = tr.querySelector(".squad-role")?.value;
    if (!pid || !kind) return;
    players.push({
      player_id: pid,
      slot_kind: kind,
      pitch_slot: kind === "pitch" ? (ord === 0 ? "gk" : `p${ord}`) : null,
      sort_order: ord++,
    });
  });
  return players;
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
    banner.innerHTML = `${escapeHtml(myNation.flag_emoji || "")} <b>${escapeHtml(
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
  renderList();
  renderNextIntl();
  renderSquadPicker();

  const params = new URLSearchParams(location.search);
  const qid = Number(params.get("fixture") || 0);
  if (qid) selectFixture(qid);
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
            const sch = f.schedule_status || "unscheduled";
            return `<tr class="${f.id === selectedId ? "active" : ""}" data-id="${f.id}">
              <td>${escapeHtml(phaseLabel(f))}</td>
              <td>${escapeHtml(f.home_flag || "")} ${escapeHtml(f.home_nation)}
                vs ${escapeHtml(f.away_flag || "")} ${escapeHtml(f.away_nation)}</td>
              <td>${escapeHtml(score)}</td>
              <td>${escapeHtml(sch)}${
                f.agreed_kickoff_at
                  ? `<br><span class="note">${escapeHtml(
                      new Date(f.agreed_kickoff_at).toLocaleString()
                    )}</span>`
                  : ""
              }</td>
              <td><button type="button" class="button secondary pick-fix" data-id="${f.id}">Open</button></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  root.querySelectorAll(".pick-fix").forEach((btn) => {
    btn.addEventListener("click", () => selectFixture(Number(btn.dataset.id)));
  });
}

async function selectFixture(id) {
  selectedId = id;
  pendingProposalId = null;
  pendingSubmissionId = null;
  renderList();

  const f = fixtures.find((x) => x.id === id);
  const panel = $("detailPanel");
  if (!f || !panel) return;
  panel.hidden = false;

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
  $("proposeBtn").disabled = !!f.played;

  renderCheckin(f);
  updateKoScoreUi();

  const { data: props } = await supabase
    .from("international_fixture_schedule_proposal")
    .select("*")
    .eq("fixture_id", id)
    .eq("status", "pending")
    .order("created_at", { ascending: false })
    .limit(1);

  const prop = props?.[0];
  const acceptBtn = $("acceptBtn");
  if (prop && prop.proposed_by_nation !== myNation.code) {
    pendingProposalId = prop.id;
    acceptBtn.hidden = false;
    $("scheduleStatus").textContent = `Pending proposal from ${prop.proposed_by_nation}: ${new Date(
      prop.kickoff_at
    ).toLocaleString()}`;
  } else {
    acceptBtn.hidden = true;
    $("scheduleStatus").textContent = prop
      ? `Your proposal pending (${new Date(prop.kickoff_at).toLocaleString()})`
      : f.agreed_kickoff_at
        ? `Agreed: ${new Date(f.agreed_kickoff_at).toLocaleString()}`
        : "No kickoff agreed yet.";
  }

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

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadFixtures();

  ["homeGoals", "awayGoals", "etHomeGoals", "etAwayGoals"].forEach((id) => {
    $(id)?.addEventListener("input", updateKoScoreUi);
  });
  document.querySelectorAll('input[name="penWinner"]').forEach((el) => {
    el.addEventListener("change", updateKoScoreUi);
  });

  $("proposeBtn")?.addEventListener("click", async () => {
    if (!selectedId) return;
    const raw = $("kickoffInput")?.value;
    if (!raw) {
      setStatus("Pick a kickoff time.", false);
      return;
    }
    const iso = new Date(raw).toISOString();
    setStatus("Proposing…");
    const { error } = await supabase.rpc("international_propose_kickoff", {
      p_fixture_id: selectedId,
      p_kickoff_at: iso,
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("✅ Kickoff proposed", true);
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

  $("saveSquadBtn")?.addEventListener("click", async () => {
    const players = collectSquadPayload();
    const pitch = players.filter((p) => p.slot_kind === "pitch").length;
    if (pitch > 0 && pitch !== 11) {
      if (!confirm(`You have ${pitch} pitch players (expected 11). Save anyway?`)) return;
    }
    setStatus("Saving squad…");
    const { error } = await supabase.rpc("international_save_matchday_squad", {
      p_players: players,
      p_pitch_layout: {},
    });
    if (error) {
      setStatus(`❌ ${error.message}`, false);
      return;
    }
    setStatus("✅ Default squad saved", true);
    await loadSavedSquad();
    renderSquadPicker();
  });
});
