import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney, loadCurrentSeason } from "./competition.js";

primeAdminPageChrome();

const STAT_LABELS = {
  player_max_goals: "Player max goals",
  player_max_assists: "Player max assists",
  club_wins: "Club wins",
  club_goals_for: "Club goals",
  club_clean_sheets: "Clean sheets",
  club_potm_awards: "POTM awards",
  transfer_sign_nation: "Sign by nationality",
};

let currentSeasonId = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const season = await loadCurrentSeason(supabase);
  currentSeasonId = season?.id ?? null;

  document.getElementById("challengeWindow").onchange = syncWindowMonths;
  document.getElementById("challengeStatType").onchange = syncStatParamVisibility;
  document.getElementById("saveChallengeDefaultsBtn").onclick = saveChallengeDefaults;
  document.getElementById("seedChallengesBtn").onclick = seedChallenges;
  document.getElementById("recheckChallengesBtn").onclick = recheckChallenges;
  document.getElementById("saveChallengeBtn").onclick = saveChallenge;
  document.getElementById("clearChallengeFormBtn").onclick = clearChallengeForm;

  syncWindowMonths();
  syncStatParamVisibility();
  await loadChallengeDefaults();
  await loadChallengeList();
  await loadChallengeAwards();
});

function syncWindowMonths() {
  const window = document.getElementById("challengeWindow").value;
  const from = document.getElementById("challengeMonthFrom");
  const to = document.getElementById("challengeMonthTo");
  if (window === "start") {
    from.value = "june";
    to.value = "december";
  } else {
    from.value = "january";
    to.value = "may";
  }
}

function syncStatParamVisibility() {
  const stat = document.getElementById("challengeStatType").value;
  const wrap = document.getElementById("challengeStatParamWrap");
  if (!wrap) return;
  wrap.hidden = stat !== "transfer_sign_nation";
  if (stat === "transfer_sign_nation") {
    const target = document.getElementById("challengeTarget");
    if (target && !target.value) target.value = "1";
  }
}

async function loadChallengeDefaults() {
  const { data, error } = await supabase.from("global_settings").select("*").eq("id", 1).single();
  if (error) {
    setStatus("challengeDefaultsStatus", "❌ " + error.message, false);
    return;
  }
  document.getElementById("challengeDefaultPrize").value = data.challenge_default_prize ?? 1000000;
  document.getElementById("challengePeriodBonus").value = data.challenge_period_bonus ?? 5000000;
  const prizeEl = document.getElementById("challengePrize");
  if (prizeEl && !prizeEl.value) {
    prizeEl.value = String(data.challenge_default_prize ?? 1000000);
  }
}

async function saveChallengeDefaults() {
  setStatus("challengeDefaultsStatus", "Saving…");
  const { error } = await supabase.rpc("admin_update_challenge_settings", {
    p_settings: {
      challenge_default_prize: Number(document.getElementById("challengeDefaultPrize").value),
      challenge_period_bonus: Number(document.getElementById("challengePeriodBonus").value),
    },
  });
  if (error) {
    setStatus("challengeDefaultsStatus", "❌ " + error.message, false);
    return;
  }
  setStatus("challengeDefaultsStatus", "✅ Defaults saved.", true);
}

function clearChallengeForm() {
  document.getElementById("challengeEditId").value = "";
  document.getElementById("challengeTitle").value = "";
  document.getElementById("challengeTarget").value = "";
  document.getElementById("challengeStatParam").value = "";
  document.getElementById("challengeWindow").value = "start";
  syncWindowMonths();
  document.getElementById("challengeStatType").value = "club_wins";
  syncStatParamVisibility();
  document.getElementById("challengeIncludeLeague").checked = true;
  document.getElementById("challengeIncludeCup").checked = false;
  document.getElementById("challengeActive").checked = true;
  loadChallengeDefaults();
  setStatus("challengeFormStatus", "");
}

function fillChallengeForm(row) {
  document.getElementById("challengeEditId").value = String(row.id);
  document.getElementById("challengeTitle").value = row.title || "";
  document.getElementById("challengeWindow").value = row.window_phase || "start";
  document.getElementById("challengeMonthFrom").value = row.gpsl_month_from;
  document.getElementById("challengeMonthTo").value = row.gpsl_month_to;
  document.getElementById("challengeStatType").value = row.stat_type;
  document.getElementById("challengeStatParam").value = row.stat_param || "";
  document.getElementById("challengeTarget").value = String(row.target_value);
  document.getElementById("challengePrize").value = String(row.prize_amount);
  document.getElementById("challengeIncludeLeague").checked = row.include_league !== false;
  document.getElementById("challengeIncludeCup").checked = !!row.include_cup;
  document.getElementById("challengeActive").checked = row.is_active !== false;
  syncStatParamVisibility();
}

async function loadChallengeList() {
  const list = document.getElementById("challengeList");
  if (!list) return;

  if (!currentSeasonId) {
    list.innerHTML = "<p class='note'>No current season.</p>";
    return;
  }

  const { data, error } = await supabase
    .from("competition_challenges_public")
    .select("*")
    .eq("season_id", currentSeasonId)
    .order("window_phase")
    .order("sort_order");

  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message} — run competition_challenges.sql</p>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<p class='note'>No challenges yet. Seed defaults or add one below.</p>";
    return;
  }

  list.innerHTML = data
    .map((row) => {
      const comps = [row.include_league && "league", row.include_cup && "cup"].filter(Boolean).join("+");
      const nation =
        row.stat_type === "transfer_sign_nation" && row.stat_param
          ? ` (${row.stat_param})`
          : "";
      return `
        <div class="challenge-admin-item">
          <div>
            <b>${row.title}</b>
            <span class="challenge-admin-meta">
              ${row.window_phase} · ${row.gpsl_month_from_label}–${row.gpsl_month_to_label}
              · ${STAT_LABELS[row.stat_type] || row.stat_type}${nation} ≥ ${row.target_value}
              · ${formatMoney(row.prize_amount)} · ${comps || "—"}
              ${row.is_active ? "" : " · <i>inactive</i>"}
            </span>
          </div>
          <div class="challenge-admin-actions">
            <button type="button" class="button challenge-edit-btn" data-id="${row.id}">Edit</button>
            <button type="button" class="button challenge-del-btn" data-id="${row.id}">Delete</button>
          </div>
        </div>
      `;
    })
    .join("");

  list.querySelectorAll(".challenge-edit-btn").forEach((btn) => {
    btn.onclick = () => {
      const row = data.find((r) => String(r.id) === btn.dataset.id);
      if (row) fillChallengeForm(row);
    };
  });

  list.querySelectorAll(".challenge-del-btn").forEach((btn) => {
    btn.onclick = async () => {
      if (!confirm("Delete this challenge?")) return;
      const { error: delErr } = await supabase.rpc("competition_admin_delete_challenge", {
        p_challenge_id: Number(btn.dataset.id),
      });
      if (delErr) {
        setStatus("challengeListStatus", "❌ " + delErr.message, false);
        return;
      }
      await loadChallengeList();
      setStatus("challengeListStatus", "Challenge deleted.", true);
    };
  });
}

async function loadChallengeAwards() {
  const list = document.getElementById("challengeAwardsList");
  if (!list || !currentSeasonId) return;

  const { data, error } = await supabase
    .from("competition_challenge_awards_public")
    .select("*")
    .eq("season_id", currentSeasonId)
    .order("awarded_at", { ascending: false });

  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message}</p>`;
    return;
  }

  if (!data?.length) {
    list.innerHTML = "<p class='note'>No awards yet.</p>";
    return;
  }

  list.innerHTML = data
    .map(
      (a) =>
        `<div class="challenge-admin-item">
          <span><b>${a.club_name || a.club_short_name}</b> — ${a.challenge_title}
          (${a.stat_value}/${a.target_value}) · ${formatMoney(a.amount)}</span>
        </div>`
    )
    .join("");
}

async function saveChallenge() {
  if (!currentSeasonId) {
    setStatus("challengeFormStatus", "No current season.", false);
    return;
  }

  const title = document.getElementById("challengeTitle").value.trim();
  if (!title) {
    setStatus("challengeFormStatus", "Title required.", false);
    return;
  }

  const payload = {
    season_id: currentSeasonId,
    id: document.getElementById("challengeEditId").value || null,
    title,
    window_phase: document.getElementById("challengeWindow").value,
    gpsl_month_from: document.getElementById("challengeMonthFrom").value,
    gpsl_month_to: document.getElementById("challengeMonthTo").value,
    stat_type: document.getElementById("challengeStatType").value,
    stat_param: (document.getElementById("challengeStatParam").value || "").trim().toUpperCase() || null,
    target_value: Number(document.getElementById("challengeTarget").value),
    prize_amount: Number(document.getElementById("challengePrize").value),
    include_league: document.getElementById("challengeIncludeLeague").checked,
    include_cup: document.getElementById("challengeIncludeCup").checked,
    is_active: document.getElementById("challengeActive").checked,
  };

  if (payload.stat_type === "transfer_sign_nation" && !payload.stat_param) {
    setStatus("challengeFormStatus", "Nation code required (e.g. NOR, ESP, TPE).", false);
    return;
  }

  setStatus("challengeFormStatus", "Saving…");
  const { data, error } = await supabase.rpc("competition_admin_save_challenge", {
    p_challenge: payload,
  });

  if (error) {
    setStatus("challengeFormStatus", "❌ " + error.message, false);
    return;
  }

  clearChallengeForm();
  await loadChallengeList();
  setStatus("challengeFormStatus", `✅ Saved challenge #${data}.`, true);
}

async function seedChallenges() {
  if (!currentSeasonId) {
    setStatus("challengeListStatus", "No current season.", false);
    return;
  }
  setStatus("challengeListStatus", "Seeding…");
  const { data, error } = await supabase.rpc("competition_admin_seed_challenge_defaults", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("challengeListStatus", "❌ " + error.message, false);
    return;
  }
  await loadChallengeList();
  setStatus("challengeListStatus", `✅ Seeded ${data ?? 0} challenges.`, true);
}

async function recheckChallenges() {
  setStatus("challengeListStatus", "Rechecking…");
  const { data, error } = await supabase.rpc("competition_admin_recheck_challenges", {
    p_season_id: currentSeasonId,
  });
  if (error) {
    setStatus("challengeListStatus", "❌ " + error.message, false);
    return;
  }
  await loadChallengeAwards();
  setStatus(
    "challengeListStatus",
    `✅ Awarded ${data?.challenges_awarded ?? 0} new challenge(s).`,
    true
  );
}
