/**
 * International matchday — arrange kickoff + submit/confirm results for your nation.
 */
import { supabase, initGlobal } from "./global.js";
import { loadMyNation } from "./international.js";

let myNation = null;
let fixtures = [];
let selectedId = null;
let pendingProposalId = null;
let pendingSubmissionId = null;

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
  if (f.phase === "knockout") return `KO · ${(f.knockout_stage || "").toUpperCase()} #${f.knockout_match_no ?? f.match_no ?? "?"}`;
  return f.phase || "—";
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
    )} — run international_wc_competition_engine_part2.sql</p>`;
    return;
  }

  fixtures = data || [];
  renderList();

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

  $("homeGoals").value = f.home_goals ?? 0;
  $("awayGoals").value = f.away_goals ?? 0;
  $("submitBtn").disabled = !!f.played;
  $("proposeBtn").disabled = !!f.played;

  // Pending proposal for opponent to accept
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

  // Pending result submission
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
      p_fixture_id: selectedId,
      p_home_goals: Number($("homeGoals").value),
      p_away_goals: Number($("awayGoals").value),
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
    let players = [];
    const raw = $("squadJson")?.value?.trim();
    if (raw) {
      try {
        players = JSON.parse(raw);
      } catch {
        setStatus("Invalid squad JSON.", false);
        return;
      }
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
  });
});
