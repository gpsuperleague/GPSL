import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

const STAT_LABELS = {
  player_max_goals: "Player max goals",
  player_max_assists: "Player max assists",
  club_wins: "League/cup wins",
  club_goals_for: "Goals scored",
  club_clean_sheets: "Clean sheets",
  club_potm_awards: "POTM awards",
  transfer_sign_nation: "Sign by nationality",
};

function windowLabel(phase) {
  if (phase === "mid") return "Mid-season";
  if (phase === "start") return "Start of season";
  return phase || "—";
}

function splitByPhase(items) {
  const start = [];
  const mid = [];
  for (const item of items || []) {
    if (item.window_phase === "mid") mid.push(item);
    else start.push(item);
  }
  return { start, mid };
}

document.addEventListener("DOMContentLoaded", async () => {
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

  if (!club?.ShortName) {
    renderError("No club linked to your account.");
    return;
  }

  document.title = `Challenges — ${fullClubName(club.ShortName) || club.ShortName}`;

  await Promise.all([
    loadMyProgress(club.ShortName),
    loadAwards(club.ShortName),
  ]);
});

function renderError(msg) {
  for (const id of ["progressStart", "progressMid"]) {
    const el = document.getElementById(id);
    if (el) el.innerHTML = `<p class="phase-empty">${msg}</p>`;
  }
  const awards = document.getElementById("challengeAwardsList");
  if (awards) awards.innerHTML = "";
}

function progressLabel(c) {
  if (c.awarded) return { text: "Awarded", className: "challenge-status-awarded" };
  if (c.expired) return { text: "Window closed", className: "challenge-status-expired" };
  return {
    text: `${c.current_value ?? 0} / ${c.target_value}`,
    className: "",
  };
}

function renderChallengeCards(items) {
  return items
    .map((c) => {
      const phaseClass = c.window_phase === "mid" ? "mid" : "start";
      const st = progressLabel(c);
      return `
        <div class="challenge-card">
          <span class="window-tag ${phaseClass}">${windowLabel(c.window_phase)}</span>
          <h3>${c.title}</h3>
          <p class="challenge-progress ${st.className}">${st.text}</p>
          <p class="challenge-meta">
            ${STAT_LABELS[c.stat_type] || c.stat_type}${
              c.stat_param ? ` (${c.stat_param})` : ""
            }
            · Prize ${formatMoney(Number(c.prize_amount || 0))}
          </p>
        </div>
      `;
    })
    .join("");
}

function renderPhaseGrids(items, emptyMsg) {
  const { start, mid } = splitByPhase(items);
  const startEl = document.getElementById("progressStart");
  const midEl = document.getElementById("progressMid");
  if (startEl) {
    startEl.innerHTML = start.length
      ? renderChallengeCards(start)
      : `<p class="phase-empty">${emptyMsg}</p>`;
  }
  if (midEl) {
    midEl.innerHTML = mid.length
      ? renderChallengeCards(mid)
      : `<p class="phase-empty">${emptyMsg}</p>`;
  }
}

async function loadMyProgress(clubShortName) {
  const { data, error } = await supabase.rpc("competition_challenge_club_progress", {
    p_club_short_name: clubShortName,
  });

  if (error) {
    const msg = String(error.message || "");
    const text =
      msg.includes("competition_challenge") || msg.includes("function")
        ? 'Challenges not enabled yet — admin must run <code>competition_challenges.sql</code> and seed targets.'
        : `❌ ${msg}`;
    renderPhaseGrids([], text);
    return [];
  }

  const items = data?.challenges || [];
  if (!items.length) {
    renderPhaseGrids(
      [],
      'No challenges in this window. See <a href="challenges.html">Season challenges</a> for league targets.'
    );
    return [];
  }

  renderPhaseGrids(items, "No challenges in this window.");
  return items;
}

async function loadAwards(clubShortName) {
  const list = document.getElementById("challengeAwardsList");
  if (!list) return;

  const { data, error } = await supabase
    .from("competition_challenge_awards_public")
    .select("*")
    .eq("club_short_name", clubShortName)
    .order("awarded_at", { ascending: false });

  if (error) {
    list.innerHTML = `<li class="meta">Could not load awards.</li>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = '<li class="meta">No challenge prizes awarded yet.</li>';
    return;
  }

  const { start, mid } = splitByPhase(data);
  const renderGroup = (phase, rows) => {
    if (!rows.length) return "";
    return (
      `<li class="meta" style="background:transparent;border:none;padding:4px 0;color:#ccc;">
        <b>${windowLabel(phase)}</b>
      </li>` +
      rows
        .map(
          (a) =>
            `<li><span class="window-tag ${phase === "mid" ? "mid" : "start"}">${windowLabel(phase)}</span>
              <b>${a.challenge_title}</b> — ${formatMoney(a.amount)} (${a.stat_value}/${a.target_value}) · ${new Date(a.awarded_at).toLocaleDateString("en-GB")}</li>`
        )
        .join("")
    );
  };

  list.innerHTML = renderGroup("start", start) + renderGroup("mid", mid);
}
